import Foundation
import Security

/// Reads the Claude Code OAuth token from the macOS Keychain.
///
/// SECURITY NOTE
/// ─────────────
/// This implementation uses the native Security framework API
/// (`SecItemCopyMatching`).  macOS displays a standard consent dialog when
/// the app accesses the Keychain item:
///
///   "Claude Usage wants to access key 'Claude Code-credentials'
///    in your keychain."  [Deny] [Allow] [Always Allow]
///
/// Choosing "Always Allow" grants this (code-signed) app persistent access to
/// that item, so the dialog should appear only once.
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

    /// In-memory credential cache — avoids reading the keychain on every poll
    /// cycle. Claude Code (and its background daemon) keep the keychain item's
    /// token fresh, so re-reading that item is how we pick up rotated tokens.
    private static var memoryCache: OAuthCredentials?

    // MARK: - Public API

    /// Load and decode the Claude Code OAuth credentials.
    ///
    /// Resolution order:
    /// 1. In-memory cache (present & unexpired)
    /// 2. Claude Code's keychain item — the source of truth
    ///
    /// Reading the keychain item prompts for consent the first time; choosing
    /// "Always Allow" makes subsequent reads silent.
    ///
    /// We deliberately do NOT cache tokens in our own keychain item or refresh
    /// them ourselves. The Claude Code CLI owns the OAuth refresh-token lineage
    /// and rotates it (single-use), so any refresh token we cached would be
    /// invalidated out from under us — the failed refresh would then force a
    /// re-prompting read of the CLI's item. Reading the CLI's item directly
    /// always yields the current, live token, so the consent dialog stays a
    /// one-time event.
    static func loadCredentials() throws -> OAuthCredentials {
        if let cached = memoryCache, cached.isValid {
            return cached
        }

        let data = try readRawData(service: claudeCodeService)
        do {
            let wrapper = try JSONDecoder().decode(ClaudeKeychainWrapper.self, from: data)
            let credentials = wrapper.claudeAiOauth.toCredentials()
            memoryCache = credentials
            return credentials
        } catch {
            throw KeychainError.decodingFailed(error)
        }
    }

    /// Drop the in-memory copy so the next `loadCredentials()` re-reads the
    /// keychain. Called on a 401 (to pick up a token the CLI has since rotated)
    /// and whenever the CLI's config directory changes.
    static func invalidateMemoryCache() {
        memoryCache = nil
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
/// Modern Claude Code keeps session metadata under ~/.claude/ (and falls back
/// to ~/.config/claude/ on older installs, or $CLAUDE_CONFIG_DIR if set).
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
        let home = FileManager.default.homeDirectoryForCurrentUser
        let modern = home.appendingPathComponent(".claude")
        if FileManager.default.fileExists(atPath: modern.path) {
            return modern
        }
        return home.appendingPathComponent(".config/claude")
    }
}
