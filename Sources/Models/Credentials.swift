import Foundation

struct OAuthCredentials {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?

    /// Returns true if the token is present and not expired (with 5-minute buffer).
    var isValid: Bool {
        guard !accessToken.isEmpty else { return false }
        if let exp = expiresAt {
            return exp.timeIntervalSinceNow > 300
        }
        return true
    }

    var bearerHeader: String {
        "Bearer \(accessToken)"
    }
}

// MARK: - Actual JSON shape stored in Keychain by Claude Code
//
// Claude Code wraps the OAuth token in a "claudeAiOauth" key:
//
//   { "claudeAiOauth": {
//       "accessToken":    "<token>",
//       "refreshToken":   "<token>",
//       "expiresAt":      <unix ms timestamp>,
//       "subscriptionType": "pro"
//   }}

struct ClaudeKeychainWrapper: Codable {
    let claudeAiOauth: ClaudeOAuthPayload
}

struct ClaudeOAuthPayload: Codable {
    let accessToken:      String
    let refreshToken:     String
    let expiresAt:        TimeInterval   // milliseconds since epoch
    let subscriptionType: String?

    func toCredentials() -> OAuthCredentials {
        // expiresAt is in milliseconds — divide by 1000 for Date
        let expiry = Date(timeIntervalSince1970: expiresAt / 1000)
        return OAuthCredentials(
            accessToken:  accessToken,
            refreshToken: refreshToken,
            expiresAt:    expiry
        )
    }
}
