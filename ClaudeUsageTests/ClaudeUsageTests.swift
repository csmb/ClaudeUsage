import Testing
import Foundation
@testable import ClaudeUsage

// MARK: - UtilizationLevel

struct UtilizationLevelTests {

    @Test func levels_atBoundaries() {
        #expect(UtilizationLevel(fraction: 0.00)  == .low)
        #expect(UtilizationLevel(fraction: 0.499) == .low)
        #expect(UtilizationLevel(fraction: 0.50)  == .medium)
        #expect(UtilizationLevel(fraction: 0.749) == .medium)
        #expect(UtilizationLevel(fraction: 0.75)  == .high)
        #expect(UtilizationLevel(fraction: 0.899) == .high)
        #expect(UtilizationLevel(fraction: 0.90)  == .critical)
        #expect(UtilizationLevel(fraction: 1.00)  == .critical)
    }

    @Test func pollIntervals() {
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
    @Test func decode_preservesRefreshToken() throws {
        let json = """
        {"claudeAiOauth":{"accessToken":"acc","refreshToken":"ref","expiresAt":1700000000000,"subscriptionType":"pro"}}
        """.data(using: .utf8)!
        let wrapper = try JSONDecoder().decode(ClaudeKeychainWrapper.self, from: json)
        let creds = wrapper.claudeAiOauth.toCredentials()
        #expect(creds.accessToken  == "acc")
        #expect(creds.refreshToken == "ref")
    }
}
