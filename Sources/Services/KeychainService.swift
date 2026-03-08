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

    // MARK: - Public API

    /// Load and decode the Claude Code OAuth credentials from the Keychain.
    /// Throws `KeychainError` if the item is absent or malformed.
    static func loadCredentials() throws -> OAuthCredentials {
        let data = try readRawData(service: claudeCodeService)
        let payload: ClaudeCodeKeychainPayload
        do {
            payload = try JSONDecoder().decode(ClaudeCodeKeychainPayload.self, from: data)
        } catch {
            throw KeychainError.decodingFailed(error)
        }
        return payload.toCredentials()
    }

    // MARK: - Private helpers

    /// Reads the raw Data stored for `service` using the Security framework.
    /// This is the ONLY entry point for Keychain access in this project.
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
