import Testing
import Foundation
@testable import Claude_Usage

// MARK: - UtilizationLevel

struct UtilizationLevelTests {

    @Test @MainActor func levels_atBoundaries() {
        #expect(UtilizationLevel(fraction: 0.00)  == .low)
        #expect(UtilizationLevel(fraction: 0.499) == .low)
        #expect(UtilizationLevel(fraction: 0.50)  == .medium)
        #expect(UtilizationLevel(fraction: 0.749) == .medium)
        #expect(UtilizationLevel(fraction: 0.75)  == .high)
        #expect(UtilizationLevel(fraction: 0.899) == .high)
        #expect(UtilizationLevel(fraction: 0.90)  == .critical)
        #expect(UtilizationLevel(fraction: 1.00)  == .critical)
    }

    @Test @MainActor func pollIntervals() {
        #expect(UtilizationLevel.low.pollInterval      == 300)
        #expect(UtilizationLevel.medium.pollInterval   == 300)
        #expect(UtilizationLevel.high.pollInterval     == 180)
        #expect(UtilizationLevel.critical.pollInterval == 120)
    }
}

// MARK: - UsageWindow

struct UsageWindowTests {

    @Test func fractionFromUtilization() {
        let w = UsageWindow(utilization: 75.0, resetsAt: nil)
        #expect(w.fraction == 0.75)
        #expect(w.percent  == 75)
    }

    @Test func fractionClampsAt1() {
        let w = UsageWindow(utilization: 150.0, resetsAt: nil)
        #expect(w.fraction == 1.0)
    }

    @Test func percentRoundsCorrectly() {
        #expect(UsageWindow(utilization: 74.4, resetsAt: nil).percent == 74)
        #expect(UsageWindow(utilization: 74.5, resetsAt: nil).percent == 75)
    }
}

// MARK: - AppState.cacheAgeText

struct CacheAgeTextTests {

    @Test @MainActor func returnsNilWhenNotFromCache() {
        let state = AppState()
        state.isFromCache = false
        state.fetchedAt   = Date()
        #expect(state.cacheAgeText == nil)
    }

    @Test @MainActor func returnsNilWhenNoFetchedAt() {
        let state = AppState()
        state.isFromCache = true
        state.fetchedAt   = nil
        #expect(state.cacheAgeText == nil)
    }

    @Test @MainActor func justNow_underOneMinute() {
        let state = AppState()
        state.isFromCache = true
        state.fetchedAt   = Date().addingTimeInterval(-30)
        #expect(state.cacheAgeText == "just now")
    }

    @Test @MainActor func oneMinAgo() {
        let state = AppState()
        state.isFromCache = true
        state.fetchedAt   = Date().addingTimeInterval(-61)
        #expect(state.cacheAgeText == "1 min ago")
    }

    @Test @MainActor func multipleMinutesAgo() {
        let state = AppState()
        state.isFromCache = true
        state.fetchedAt   = Date().addingTimeInterval(-5 * 60)
        #expect(state.cacheAgeText == "5 mins ago")
    }

    @Test @MainActor func hoursAgo() {
        let state = AppState()
        state.isFromCache = true
        state.fetchedAt   = Date().addingTimeInterval(-2 * 3600)
        #expect(state.cacheAgeText == "2h ago")
    }
}

// MARK: - Credentials decoding

struct CredentialsDecodeTests {
    @Test @MainActor func decode_preservesRefreshToken() throws {
        let json = """
        {"claudeAiOauth":{"accessToken":"acc","refreshToken":"ref","expiresAt":1700000000000,"subscriptionType":"pro"}}
        """.data(using: .utf8)!
        let wrapper = try JSONDecoder().decode(ClaudeKeychainWrapper.self, from: json)
        let creds = wrapper.claudeAiOauth.toCredentials()
        #expect(creds.accessToken  == "acc")
        #expect(creds.refreshToken == "ref")
    }
}

// MARK: - Reading Claude Code's item through security(1)

/// What `security find-generic-password -w` prints, captured from the real
/// tool: the value plus a newline, or — when any byte isn't printable ASCII —
/// the whole value as lowercase hex (SecurityTool's keychain_find.c).
struct SecurityOutputDecodeTests {

    @Test @MainActor func printableValue_isReturnedWithoutTrailingNewline() throws {
        let printed = Data(#"{"a":"x"}"#.utf8) + [0x0a]
        #expect(try KeychainService.decodeSecurityOutput(printed) == Data(#"{"a":"x"}"#.utf8))
    }

    @Test @MainActor func nonPrintableValue_isHexDecoded() throws {
        let printed = Data("7b2261223a22c3a9227d\n".utf8)
        #expect(try KeychainService.decodeSecurityOutput(printed) == Data(#"{"a":"é"}"#.utf8))
    }

    @Test @MainActor func emptyOutput_throws() {
        #expect(throws: KeychainError.self) {
            try KeychainService.decodeSecurityOutput(Data("\n".utf8))
        }
    }

    @Test @MainActor func unrecognisedOutput_throws() {
        #expect(throws: KeychainError.self) {
            try KeychainService.decodeSecurityOutput(Data("not a keychain value\n".utf8))
        }
    }
}

/// Round-trips through the real /usr/bin/security against a throwaway
/// keychain, so the login keychain is never touched.
struct SecurityToolReadTests {

    @Test @MainActor func readsStoredValue() throws {
        let keychain = try ThrowawayKeychain()
        defer { keychain.remove() }
        try keychain.addGenericPassword(service: "svc", account: "acct", value: #"{"a":"é"}"#)

        let data = try KeychainService.readItem(service: "svc", account: "acct", keychain: keychain.path)

        #expect(data == Data(#"{"a":"é"}"#.utf8))
    }

    @Test @MainActor func missingItem_throwsItemNotFound() throws {
        let keychain = try ThrowawayKeychain()
        defer { keychain.remove() }

        let error = #expect(throws: KeychainError.self) {
            try KeychainService.readItem(service: "svc", account: "acct", keychain: keychain.path)
        }
        guard case .itemNotFound? = error else {
            Issue.record("expected .itemNotFound, got \(String(describing: error))")
            return
        }
    }

    /// Reads run on the main actor. Waiting must not spin the main run loop,
    /// or timers, UI events and XCTest itself run inside a half-finished
    /// refresh — which deadlocked the test host.
    @Test @MainActor func read_doesNotRunOtherMainRunLoopWork() throws {
        let keychain = try ThrowawayKeychain()
        defer { keychain.remove() }
        try keychain.addGenericPassword(service: "svc", account: "acct", value: "{}")

        // Main-thread only: the block and the test both run there.
        final class Probe: @unchecked Sendable { var reading = true, ranDuringRead = false }
        let probe = Probe()
        RunLoop.main.perform { if probe.reading { probe.ranDuringRead = true } }
        _ = try KeychainService.readItem(service: "svc", account: "acct", keychain: keychain.path)
        probe.reading = false

        #expect(!probe.ranDuringRead)
    }
}

// MARK: - LogFile

struct LogFileTests {

    @Test @MainActor func append_writesTimestampedLinesInOrder() {
        let url = temporaryLogURL(); defer { try? FileManager.default.removeItem(at: url) }
        let log = LogFile(url: url)

        log.append("first", at: Date(timeIntervalSince1970: 0))
        log.append("second", at: Date(timeIntervalSince1970: 61))

        #expect(log.lines() == ["1970-01-01T00:00:00Z first", "1970-01-01T00:01:01Z second"])
    }

    @Test @MainActor func missingFile_hasNoLines() {
        #expect(LogFile(url: temporaryLogURL()).lines().isEmpty)
    }

    @Test @MainActor func pastTheSizeCap_keepsOnlyTheNewestLines() {
        let url = temporaryLogURL(); defer { try? FileManager.default.removeItem(at: url) }
        // Each line is 27 bytes, so the 4th append crosses 100 bytes and trims to 2.
        let log = LogFile(url: url, maxBytes: 100, keepLines: 2)

        for n in 1...4 { log.append("line\(n)", at: Date(timeIntervalSince1970: 0)) }

        #expect(log.lines() == ["1970-01-01T00:00:00Z line3", "1970-01-01T00:00:00Z line4"])
    }

    private func temporaryLogURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ClaudeUsageTests-\(UUID().uuidString).log")
    }
}

// MARK: - LifecycleLog

struct LifecycleLogTests {

    @Test @MainActor func cleanExit_isNotReported() {
        let lines = ["T launch pid=100 path=/Applications/Claude Usage.app",
                     "T exit pid=100 quit from the app"]
        #expect(LifecycleLog.runWithoutExit(in: lines, isRunning: { _ in false }) == nil)
    }

    @Test @MainActor func lastLaunchWithoutExit_isReported() {
        let lines = ["T launch pid=100 path=/Applications/Claude Usage.app",
                     "T exit pid=100 quit from the app",
                     "T launch pid=200 path=/Applications/Claude Usage.app"]
        #expect(LifecycleLog.runWithoutExit(in: lines, isRunning: { _ in false }) == 200)
    }

    @Test @MainActor func stillRunningInstance_isNotReported() {
        let lines = ["T launch pid=200 path=/Applications/Claude Usage.app"]
        #expect(LifecycleLog.runWithoutExit(in: lines, isRunning: { $0 == 200 }) == nil)
    }

    @Test @MainActor func emptyLog_reportsNothing() {
        #expect(LifecycleLog.runWithoutExit(in: [], isRunning: { _ in false }) == nil)
    }

    @Test @MainActor func noAppleEvent_isAQuitFromTheApp() {
        #expect(LifecycleLog.quitReason(for: nil, senderPID: nil, appName: { _ in nil }) == "quit from the app")
    }

    @Test @MainActor func quitEventFromAnotherProcess_namesTheSender() {
        let reason = LifecycleLog.quitReason(for: quitEvent(), senderPID: 812,
                                             appName: { $0 == 812 ? "Activity Monitor" : nil })

        #expect(reason == "quit requested by Activity Monitor (pid 812)")
    }

    @Test @MainActor func quitEventFromLoginWindow_givesTheReason() {
        let cases: [(code: OSType, reason: String)] = [
            (kAELogOut, "logout"), (kAEReallyLogOut, "logout"),
            (kAERestart, "restart"), (kAEShowRestartDialog, "restart"),
            (kAEShutDown, "shutdown"), (kAEShowShutdownDialog, "shutdown"),
        ]
        for (code, reason) in cases {
            let event = quitEvent()
            event.setAttribute(NSAppleEventDescriptor(enumCode: code), forKeyword: AEKeyword(kAEQuitReason))
            // loginwindow is the sender here, but the reason wins.
            #expect(LifecycleLog.quitReason(for: event, senderPID: 400, appName: { _ in "loginwindow" }) == reason)
        }
    }

    private func quitEvent() -> NSAppleEventDescriptor {
        NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEQuitApplication),
                               targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
                               transactionID: AETransactionID(kAnyTransactionID))
    }
}

/// A keychain file that exists for one test. `security create-keychain` makes
/// a legacy keychain without partition lists, which is all these tests need:
/// they check how we drive security(1), not how macOS guards the item.
private struct ThrowawayKeychain {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("ClaudeUsageTests-\(UUID().uuidString).keychain-db").path

    init() throws {
        try Self.security("create-keychain", "-p", "test", path)
    }

    /// Stores `value` hex-encoded with `-X`, as Claude Code does. Passing it with
    /// `-w` would not be byte-exact: Process hands arguments over in file-system
    /// representation, which decomposes "é" into "e" + a combining accent.
    func addGenericPassword(service: String, account: String, value: String) throws {
        let hex = value.utf8.map { String(format: "%02x", $0) }.joined()
        try Self.security("add-generic-password", "-s", service, "-a", account, "-X", hex, path)
    }

    func remove() {
        try? Self.security("delete-keychain", path)
    }

    private struct SecurityFailed: Error { let arguments: [String]; let status: Int32 }

    private static func security(_ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)   // not waitUntilExit(): see above
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        exited.wait()
        guard process.terminationStatus == 0 else {
            throw SecurityFailed(arguments: arguments, status: process.terminationStatus)
        }
    }
}
