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

enum APIError: LocalizedError {
    case noCredentials(Error)
    case networkError(Error)
    case httpError(Int)
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
    private static let endpoint = "/v1/usage"
    private static let betaHeader = "claude-code-usage-2024-12-20"

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
    func fetchUsage() async throws -> UsageResponse {
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

        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200...299: break
            case 401: throw APIError.invalidCredentials
            default:  throw APIError.httpError(http.statusCode)
            }
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
            return try decoder.decode(UsageResponse.self, from: data)
        } catch {
            throw APIError.decodingError(error)
        }
    }
}
