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

// MARK: - JSON shape stored in Keychain by Claude Code

/// Claude Code stores a JSON blob under the service "Claude Code-credentials".
/// This mirrors the shape we decode from that blob.
struct ClaudeCodeKeychainPayload: Codable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: String?   // ISO-8601 string or nil

    enum CodingKeys: String, CodingKey {
        case accessToken  = "access_token"
        case refreshToken = "refresh_token"
        case expiresAt    = "expires_at"
    }

    func toCredentials() -> OAuthCredentials {
        var expiryDate: Date? = nil
        if let str = expiresAt {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            expiryDate = iso.date(from: str) ?? ISO8601DateFormatter().date(from: str)
        }
        return OAuthCredentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiryDate
        )
    }
}
