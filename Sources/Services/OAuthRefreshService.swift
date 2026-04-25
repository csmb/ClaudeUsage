import Foundation

/// Refreshes the Claude Code OAuth token by calling Anthropic's token endpoint
/// directly, so the app only needs to read Claude Code's keychain item once.
///
/// The endpoint and public client ID were extracted from the Claude Code CLI
/// binary (strings /path/to/claude → https://platform.claude.com/v1/oauth/token
/// and UUID 9d1c250a-…).

enum OAuthRefreshError: LocalizedError {
    case network(Error)
    case http(Int)
    case refreshTokenRejected   // 401/403 from token endpoint — must re-seed from Claude Code keychain
    case decoding(Error)

    var errorDescription: String? {
        switch self {
        case .network(let e):        return "Network error during token refresh: \(e.localizedDescription)"
        case .http(let code):        return "Token refresh returned HTTP \(code)"
        case .refreshTokenRejected:  return "Refresh token rejected — re-reading Claude Code credentials"
        case .decoding(let e):       return "Could not parse token refresh response: \(e.localizedDescription)"
        }
    }
}

struct OAuthRefreshService {

    static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    struct TokenResponse: Codable {
        let accessToken:  String
        let refreshToken: String?
        let expiresIn:    TimeInterval?

        enum CodingKeys: String, CodingKey {
            case accessToken  = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn    = "expires_in"
        }
    }

    static func makeRequest(refreshToken: String) -> URLRequest {
        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let body: [String: String] = [
            "grant_type":    "refresh_token",
            "refresh_token": refreshToken,
            "client_id":     clientID
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return req
    }

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieAcceptPolicy    = .never
        cfg.httpShouldSetCookies      = false
        cfg.requestCachePolicy        = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = 15
        return URLSession(configuration: cfg)
    }()

    func refresh(refreshToken: String) async throws -> TokenResponse {
        let request = Self.makeRequest(refreshToken: refreshToken)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw OAuthRefreshError.network(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw OAuthRefreshError.http(0)
        }
        switch http.statusCode {
        case 200...299: break
        case 401, 403:  throw OAuthRefreshError.refreshTokenRejected
        default:        throw OAuthRefreshError.http(http.statusCode)
        }

        do {
            return try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw OAuthRefreshError.decoding(error)
        }
    }
}
