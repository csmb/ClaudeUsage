import Foundation

/// Reads the Claude Code OAuth token from the macOS Keychain.
///
/// WHY THIS RUNS /usr/bin/security
/// ───────────────────────────────
/// The token lives in Claude Code's own item ("Claude Code-credentials"),
/// which the CLI rewrites through `/usr/bin/security` on every token refresh
/// (roughly every 8 hours). Each data write re-encrypts the item, and macOS
/// resets its partition list to the writer alone (`apple-tool:`, i.e.
/// security(1)). That silently revokes any "Always Allow" granted to this
/// app, so reading through the Security framework (`SecItemCopyMatching`)
/// re-prompted after every CLI refresh — and after every rebuild, since a
/// self-signed app's partition ID is its cdhash. See tasks/lessons.md.
///
/// security(1) is the one reader whose access every CLI write preserves, so
/// we read the item exactly the way the CLI does. This grants nothing new:
/// the item's ACL already lets any process running as the user read it this
/// way. Hardening: absolute executable path (sealed system volume, no PATH
/// lookup), arguments passed as an array (no shell), the secret returned on
/// stdout (never on a command line), a timeout, and the output never logged.

enum KeychainError: LocalizedError {
    case itemNotFound
    case unexpectedData
    case decodingFailed(Error)
    case securityToolFailed(Int32)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .itemNotFound:
            return "Claude Code credentials not found in Keychain. Make sure you are logged in to Claude Code."
        case .unexpectedData:
            return "Keychain returned data in an unexpected format."
        case .decodingFailed(let err):
            return "Could not decode Keychain credentials: \(err.localizedDescription)"
        case .securityToolFailed(let status):
            return "Could not read Claude Code's keychain item (security exited with status \(status))."
        case .timedOut:
            return "Timed out reading Claude Code's keychain item."
        }
    }
}

struct KeychainService {

    /// The service name Claude Code uses when it writes the token.
    static let claudeCodeService = "Claude Code-credentials"

    /// In-memory credential cache — avoids running security(1) on every poll
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
    /// We deliberately do NOT cache tokens in our own keychain item or refresh
    /// them ourselves. The Claude Code CLI owns the OAuth refresh-token lineage
    /// and rotates it (single-use), so any refresh token we cached would be
    /// invalidated out from under us. Reading the CLI's item directly always
    /// yields the current, live token.
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
    /// keychain. Called on a 401, to pick up a token the CLI has since rotated.
    static func invalidateMemoryCache() {
        memoryCache = nil
    }

    // MARK: - Claude Code keychain access

    /// Reads Claude Code's item, matched on the same service + account the CLI writes.
    private static func readRawData(service: String) throws -> Data {
        try readItem(service: service, account: NSUserName())
    }

    /// Longest we wait for security(1). A read normally takes ~20 ms; the
    /// Claude Code CLI gives up on the same call after 2 s.
    private static let securityTimeout: TimeInterval = 5

    /// Reads a generic password by running
    /// `/usr/bin/security find-generic-password -s <service> -a <account> -w`.
    /// `keychain` limits the search to one keychain file; nil searches the
    /// user's keychain list.
    static func readItem(service: String, account: String, keychain: String? = nil) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-a", account, "-w"]
            + (keychain.map { [$0] } ?? [])
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError  = FileHandle.nullDevice
        // Wait on the termination handler, not waitUntilExit(): that spins the
        // run loop, so timers, UI events or XCTest would run inside a
        // half-finished refresh on the main actor.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        try process.run()

        // Kill a hung read so a stuck security(1) can't wedge the app.
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + securityTimeout, execute: watchdog)

        // Drain to EOF before waiting, so a large value can't fill the pipe
        // and stall the child.
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        exited.wait()
        watchdog.cancel()

        guard process.terminationReason == .exit else { throw KeychainError.timedOut }
        switch process.terminationStatus {
        case 0:  return try decodeSecurityOutput(output)
        case 44: throw KeychainError.itemNotFound   // errSecItemNotFound, as an exit status
        default: throw KeychainError.securityToolFailed(process.terminationStatus)
        }
    }

    /// Turns what `security -w` printed back into the item's bytes. It prints
    /// the value plus a newline, or — when any byte isn't printable ASCII —
    /// the whole value as lowercase hex (SecurityTool's keychain_find.c).
    /// Claude Code's item always holds a JSON object, so output starting with
    /// "{" was printed verbatim and anything else must be the hex form.
    static func decodeSecurityOutput(_ output: Data) throws -> Data {
        guard let text = String(data: output, encoding: .utf8)?.trimmingCharacters(in: .newlines),
              !text.isEmpty else {
            throw KeychainError.unexpectedData
        }
        if text.hasPrefix("{") { return Data(text.utf8) }

        let digits = Array(text.utf8)
        guard digits.count.isMultiple(of: 2) else { throw KeychainError.unexpectedData }
        var bytes = Data(capacity: digits.count / 2)
        for i in stride(from: 0, to: digits.count, by: 2) {
            guard let high = hexValue(digits[i]), let low = hexValue(digits[i + 1]) else {
                throw KeychainError.unexpectedData
            }
            bytes.append(high << 4 | low)
        }
        return bytes
    }

    private static func hexValue(_ digit: UInt8) -> UInt8? {
        switch digit {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return digit - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return digit - UInt8(ascii: "a") + 10
        default: return nil
        }
    }
}
