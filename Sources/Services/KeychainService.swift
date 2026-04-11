import Foundation
import Security

/// Reads the Claude Code OAuth token from the macOS Keychain.
///
/// SECURITY NOTE
/// ─────────────
/// This implementation uses the native Security framework API
/// (`SecItemCopyMatching`).  macOS will display a standard consent
/// dialog the first time the app tries to access the Keychain item:
///
///   "ClaudeUsage wants to access Claude Code credentials stored
///    in your keychain."  [Deny] [Allow] [Always Allow]
///
/// There is NO use of Process(), NSTask, shell-out, or the
/// `/usr/bin/security` command-line tool anywhere in this file or
/// this project.  Those approaches silently bypass the consent dialog,
/// which is the exact security flaw this app was written to avoid.

enum KeychainError: LocalizedError {
    case itemNotFound
    case unexpectedData
    case decodingFailed(Error)
    case keychainStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .itemNotFound:
            return "Claude Code credentials not found in Keychain. Make sure you are logged in to Claude Code."
        case .unexpectedData:
            return "Keychain returned data in an unexpected format."
        case .decodingFailed(let err):
            return "Could not decode Keychain credentials: \(err.localizedDescription)"
        case .keychainStatus(let status):
            return "Keychain error (OSStatus \(status)): \(SecCopyErrorMessageString(status, nil) as String? ?? "unknown")"
        }
    }
}

struct KeychainService {

    /// The service name Claude Code uses when it writes the token.
    static let claudeCodeService = "Claude Code-credentials"

    /// Our own keychain item where we cache a copy of the credentials.
    /// Because this app created the item, macOS never shows an ACL prompt for it.
    private static let cachedService = "csmb.ClaudeUsage.cached-credentials"
    private static let cachedAccount = "oauth-token"

    /// In-memory credential cache — avoids hitting the keychain on every poll cycle.
    private static var memoryCache: OAuthCredentials?

    // MARK: - Public API

    /// Load and decode the Claude Code OAuth credentials, checking caches first.
    ///
    /// Resolution order:
    /// 1. In-memory cache (valid & unexpired)
    /// 2. App's own keychain cache (valid & unexpired)
    /// 3. Claude Code's keychain item (may trigger system password dialog)
    ///
    /// After a successful read from Claude Code's keychain, the credentials
    /// are saved to the app's own keychain so future launches skip the dialog.
    static func loadCredentials() throws -> OAuthCredentials {
        // 1. In-memory cache
        if let cached = memoryCache, cached.isValid {
            return cached
        }

        // 2. App's own keychain cache
        if let cached = loadFromOwnKeychain() {
            memoryCache = cached
            return cached
        }

        // 3. Claude Code's keychain (may prompt)
        let data = try readRawData(service: claudeCodeService)
        do {
            let wrapper = try JSONDecoder().decode(ClaudeKeychainWrapper.self, from: data)
            let credentials = wrapper.claudeAiOauth.toCredentials()

            // Cache so future launches don't prompt
            saveToOwnKeychain(data: data)
            memoryCache = credentials

            return credentials
        } catch {
            throw KeychainError.decodingFailed(error)
        }
    }

    /// Clear all credential caches so the next `loadCredentials()` call
    /// re-reads from Claude Code's keychain. Call this after a 401.
    static func invalidateCredentials() {
        memoryCache = nil
        deleteFromOwnKeychain()
    }

    // MARK: - Own keychain cache helpers

    /// Read credentials from the app's own keychain item (never prompts).
    private static func loadFromOwnKeychain() -> OAuthCredentials? {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: cachedService as CFString,
            kSecAttrAccount: cachedAccount as CFString,
            kSecReturnData:  true,
            kSecMatchLimit:  kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let wrapper = try? JSONDecoder().decode(ClaudeKeychainWrapper.self, from: data)
        else { return nil }

        let credentials = wrapper.claudeAiOauth.toCredentials()
        return credentials.isValid ? credentials : nil
    }

    /// Save raw credential JSON to the app's own keychain item.
    private static func saveToOwnKeychain(data: Data) {
        let searchQuery: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: cachedService as CFString,
            kSecAttrAccount: cachedAccount as CFString,
        ]
        let attrs: [CFString: Any] = [kSecValueData: data]

        let status = SecItemUpdate(searchQuery as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = searchQuery
            addQuery[kSecValueData] = data
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    /// Remove the app's cached credentials from the keychain.
    private static func deleteFromOwnKeychain() {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: cachedService as CFString,
            kSecAttrAccount: cachedAccount as CFString,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Claude Code keychain access

    /// Reads the raw Data stored for `service` using the Security framework.
    /// This is the ONLY entry point for Claude Code's Keychain item in this project.
    private static func readRawData(service: String) throws -> Data {
        // Build the query dictionary.
        // kSecAttrService narrows the lookup to the exact service name.
        // kSecReturnData asks for the raw value (not just attributes).
        // kSecMatchLimitOne ensures we get at most one result.
        let query: [CFString: Any] = [
            kSecClass:            kSecClassGenericPassword,
            kSecAttrService:      service as CFString,
            kSecReturnData:       true,
            kSecMatchLimit:       kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw KeychainError.unexpectedData
            }
            return data

        case errSecItemNotFound:
            throw KeychainError.itemNotFound

        default:
            throw KeychainError.keychainStatus(status)
        }
    }
}

// MARK: - File-System Watcher (credential refresh on change)

/// Watches the Claude Code credential directory for changes and fires a
/// callback when the Keychain item is likely to have been refreshed.
///
/// Claude Code stores session metadata under
///   ~/.config/claude/  (or $CLAUDE_CONFIG_DIR)
/// Watching that directory lets us pick up token refreshes promptly
/// without aggressive polling.
final class CredentialWatcher {

    private var source: DispatchSourceFileSystemObject?
    private let callback: () -> Void
    private let queue = DispatchQueue(label: "com.claudeusage.credentialwatcher")

    init(callback: @escaping () -> Void) {
        self.callback = callback
    }

    func start() {
        let dir = claudeConfigDir()
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: queue
        )
        src.setEventHandler { [weak self] in
            DispatchQueue.main.async { self?.callback() }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        self.source = src
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    private func claudeConfigDir() -> URL {
        if let env = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"],
           !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/claude")
    }
}
