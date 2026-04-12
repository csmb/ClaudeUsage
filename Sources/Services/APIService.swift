import Foundation

/// Makes HTTPS requests to the Claude Code usage API.
///
/// SECURITY NOTE
/// ─────────────
/// - Single hardcoded base URL: https://api.anthropic.com
/// - Single endpoint: /v1/usage
/// - No redirects followed (redirectionPolicy = .none)
/// - Cookies disabled
/// - No background sessions (no silent network activity)
/// - URLSession is created fresh for each APIService instance
///   so there is no shared/ambient session with stale config.

/// Rate limit info extracted from response headers.
struct RateLimitInfo {
    let limit:     Int?      // max requests allowed in window
    let remaining: Int?      // requests remaining in window
    let resetAt:   Date?     // when the window resets

    init(headers: [String: String]) {
        limit     = headers["x-ratelimit-limit"].flatMap(Int.init)
        remaining = headers["x-ratelimit-remaining"].flatMap(Int.init)
        if let resetStr = headers["x-ratelimit-reset"] {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            resetAt = iso.date(from: resetStr)
        } else {
            resetAt = nil
        }
    }

    var description: String {
        var parts: [String] = []
        if let l = limit     { parts.append("limit=\(l)") }
        if let r = remaining { parts.append("remaining=\(r)") }
        if let d = resetAt   { parts.append("reset=\(d)") }
        return parts.isEmpty ? "none" : parts.joined(separator: ", ")
    }
}

/// Result from a successful usage fetch, including rate limit metadata.
struct UsageFetchResult {
    let response:  UsageResponse
    let rateLimit: RateLimitInfo
}

enum APIError: LocalizedError {
    case noCredentials(Error)
    case networkError(Error)
    case httpError(Int)
    case rateLimited(retryAfter: TimeInterval)
    case decodingError(Error)
    case invalidCredentials

    var errorDescription: String? {
        switch self {
        case .noCredentials(let err):
            return "Could not read credentials: \(err.localizedDescription)"
        case .networkError(let err):
            return "Network error: \(err.localizedDescription)"
        case .httpError(let code):
            return "API returned HTTP \(code)"
        case .rateLimited(let retry):
            let secs = Int(retry.rounded())
            return "Rate limited — retrying in \(secs)s"
        case .decodingError(let err):
            return "Could not parse API response: \(err.localizedDescription)"
        case .invalidCredentials:
            return "OAuth token is expired or invalid. Please log in to Claude Code again."
        }
    }
}

final class APIService {

    // MARK: - Constants

    private static let baseURL  = URL(string: "https://api.anthropic.com")!
    private static let endpoint = "/api/oauth/usage"
    private static let betaHeader = "oauth-2025-04-20"

    // MARK: - URLSession

    /// Dedicated session — no cookies, no caching, no cellular surprises.
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy    = .never
        config.httpShouldSetCookies      = false
        config.requestCachePolicy        = .reloadIgnoringLocalCacheData
        config.allowsCellularAccess      = true   // explicit, not default
        config.waitsForConnectivity      = false  // fail fast rather than stall
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()

    // MARK: - Public API

    /// Fetch current usage from api.anthropic.com/v1/usage.
    func fetchUsage() async throws -> UsageFetchResult {
        let credentials: OAuthCredentials
        do {
            credentials = try KeychainService.loadCredentials()
        } catch {
            throw APIError.noCredentials(error)
        }

        guard credentials.isValid else {
            throw APIError.invalidCredentials
        }

        var request = URLRequest(
            url: Self.baseURL.appendingPathComponent(Self.endpoint)
        )
        request.httpMethod = "GET"
        request.setValue(credentials.bearerHeader,    forHTTPHeaderField: "Authorization")
        request.setValue(Self.betaHeader,             forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json",          forHTTPHeaderField: "Accept")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.networkError(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw APIError.httpError(0)
        }

        // Collect all headers (lowercased keys) for rate limit inspection
        let headerPairs: [(String, String)] = http.allHeaderFields.compactMap { key, value in
            guard let k = key as? String, let v = value as? String else { return nil }
            return (k.lowercased(), v)
        }
        let headers = Dictionary(headerPairs, uniquingKeysWith: { _, last in last })

        let rateLimit = RateLimitInfo(headers: headers)

        // Log rate limit headers on every response
        let rlHeaders = headers.filter { $0.key.contains("ratelimit") || $0.key.contains("rate-limit") || $0.key == "retry-after" }
        if !rlHeaders.isEmpty {
            print("[APIService] Rate limit headers: \(rlHeaders)")
        } else {
            print("[APIService] No rate limit headers in response")
        }
        Self.logRateLimitToFile(statusCode: http.statusCode, headers: headers)

        switch http.statusCode {
        case 200...299: break
        case 401:
            KeychainService.invalidateCredentials()
            throw APIError.invalidCredentials
        case 429:
            print("[APIService] 429 — all headers: \(headers)")
            let retry = headers["retry-after"]
                .flatMap(TimeInterval.init)
                .flatMap { $0 > 0 ? $0 : nil } ?? 60
            throw APIError.rateLimited(retryAfter: retry)
        default:  throw APIError.httpError(http.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let str = try decoder.singleValueContainer().decode(String.self)
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = iso.date(from: str) { return d }
            iso.formatOptions = [.withInternetDateTime]
            if let d = iso.date(from: str) { return d }
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Cannot parse date: \(str)"
            )
        }

        do {
            let usage = try decoder.decode(UsageResponse.self, from: data)
            return UsageFetchResult(response: usage, rateLimit: rateLimit)
        } catch {
            throw APIError.decodingError(error)
        }
    }

    // MARK: - Rate Limit File Log

    private static let logFile: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "ClaudeUsage")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ratelimit_log.txt")
    }()

    private static let logMaxBytes: Int = 64 * 1024      // trim when file exceeds 64 KB
    private static let logKeepLines: Int = 500           // keep last 500 lines after trim

    private static func logRateLimitToFile(statusCode: Int, headers: [String: String]) {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let ts = iso.string(from: Date())

        let rl = headers.filter { $0.key.contains("ratelimit") || $0.key.contains("rate-limit") || $0.key == "retry-after" }
        let extra = rl.isEmpty ? "" : " " + rl.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        let line = "\(ts) status=\(statusCode)\(extra)\n"

        if let handle = try? FileHandle(forWritingTo: logFile) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8) ?? Data())
            handle.closeFile()
        } else {
            try? line.data(using: .utf8)?.write(to: logFile)
        }

        // Rotate if file has grown too large
        if let attrs = try? FileManager.default.attributesOfItem(atPath: logFile.path),
           let size = attrs[.size] as? Int,
           size > logMaxBytes {
            trimLogFile()
        }
    }

    private static func trimLogFile() {
        guard let contents = try? String(contentsOf: logFile, encoding: .utf8) else { return }
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > logKeepLines else { return }
        let kept = lines.suffix(logKeepLines).joined(separator: "\n")
        try? kept.data(using: .utf8)?.write(to: logFile)
    }
}
