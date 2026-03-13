import Foundation
import Combine
import AppKit
import UserNotifications

/// Single source of truth for the app.
/// Published properties drive both the menu bar icon and the popover.
@MainActor
final class AppState: ObservableObject {

    // MARK: - Published State

    @Published var usageResponse: UsageResponse?      = nil
    @Published var fetchedAt:     Date?               = nil
    @Published var isLoading:     Bool                = false
    @Published var error:         String?             = nil
    @Published var isFromCache:   Bool                = false
    @Published var lastFetchedAt: Date?              = nil

    private let refreshCooldown: TimeInterval = 30

    var canRefresh: Bool {
        guard let last = lastFetchedAt else { return true }
        return Date().timeIntervalSince(last) >= refreshCooldown
    }

    var cooldownRemaining: Int {
        guard let last = lastFetchedAt else { return 0 }
        return max(0, Int(refreshCooldown - Date().timeIntervalSince(last)))
    }

    // MARK: - Dependencies

    let settings       = AppSettings()
    let api            = APIService()
    let cache          = CacheService()
    let polling:       PollingManager

    // MARK: - Notification state

    private var notifiedThresholds: Set<Int> = []

    // MARK: - Init

    init() {
        self.polling = PollingManager()
        polling.onTick = { [weak self] in
            Task { await self?.refresh() }
        }

        // Warm up from cache immediately so the popover isn't blank on launch
        if let cached = cache.load() {
            self.usageResponse = cached.response
            self.fetchedAt     = cached.fetchedAt
            self.isFromCache   = true
        }
    }

    // MARK: - Refresh

    func refresh() async {
        guard !isLoading, canRefresh else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let response = try await api.fetchUsage()
            usageResponse = response
            fetchedAt     = Date()
            lastFetchedAt = Date()
            isFromCache   = false
            error         = nil
            cache.save(response)

            let level = utilizationLevel
            polling.updateInterval(
                settings.pollIntervalOverride > 0
                    ? settings.pollIntervalOverride
                    : level.pollInterval
            )

            checkNotifications(for: response)

        } catch APIError.rateLimited(let retryAfter) {
            let backoff = max(60, retryAfter)   // always wait at least 60s
            self.error = "Rate limited — next refresh in \(Int(backoff))s"
            polling.updateInterval(backoff)
        } catch {
            self.error = error.localizedDescription
            // Keep showing cached data if available
        }
    }

    // MARK: - Computed Helpers

    var utilizationLevel: UtilizationLevel {
        guard let r = usageResponse else { return .low }
        let f5h = r.fiveHour?.fraction ?? 0
        let f7d = r.sevenDay?.fraction ?? 0
        return UtilizationLevel(fraction: max(f5h, f7d))
    }

    /// Attributed string for the menu bar button, with each window color-coded independently.
    var menuBarAttributedTitle: NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)

        guard let r = usageResponse, settings.displayMode != .iconOnly else {
            let dots = NSMutableAttributedString(string: "…", attributes: [
                .font: font, .foregroundColor: NSColor.secondaryLabelColor
            ])
            return dots
        }

        func seg(_ pct: Int, _ fraction: Double) -> NSAttributedString {
            let color = nsColor(for: UtilizationLevel(fraction: fraction))
            return NSAttributedString(string: "\(pct)%", attributes: [
                .font: font, .foregroundColor: color
            ])
        }

        let sep = NSAttributedString(string: " · ", attributes: [
            .font: font, .foregroundColor: NSColor.secondaryLabelColor
        ])

        let result = NSMutableAttributedString()
        result.append(seg(r.fiveHour?.percent ?? 0, r.fiveHour?.fraction ?? 0))
        result.append(sep)
        result.append(seg(r.sevenDay?.percent ?? 0, r.sevenDay?.fraction ?? 0))
        return result
    }

    private func nsColor(for level: UtilizationLevel) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            switch level {
            case .low:
                return isDark
                    ? NSColor(red: 0.133, green: 0.773, blue: 0.369, alpha: 1) // #22C55E
                    : NSColor(red: 0.086, green: 0.396, blue: 0.204, alpha: 1) // #166534
            case .medium:
                return isDark
                    ? NSColor(red: 0.984, green: 0.749, blue: 0.141, alpha: 1) // #FBBF24
                    : NSColor(red: 0.573, green: 0.251, blue: 0.055, alpha: 1) // #92400E
            case .high:
                return isDark
                    ? NSColor(red: 0.984, green: 0.573, blue: 0.235, alpha: 1) // #FB923C
                    : NSColor(red: 0.604, green: 0.204, blue: 0.071, alpha: 1) // #9A3412
            case .critical:
                return isDark
                    ? NSColor(red: 0.973, green: 0.443, blue: 0.443, alpha: 1) // #F87171
                    : NSColor(red: 0.600, green: 0.106, blue: 0.106, alpha: 1) // #991B1B
            }
        }
    }

    var cacheAgeText: String? {
        guard isFromCache, let at = fetchedAt else { return nil }
        let mins = Int(Date().timeIntervalSince(at) / 60)
        if mins < 1   { return "just now" }
        if mins == 1  { return "1 min ago" }
        if mins < 60  { return "\(mins) mins ago" }
        let hrs = mins / 60
        return "\(hrs)h ago"
    }

    // MARK: - Notifications

    private func checkNotifications(for response: UsageResponse) {
        guard settings.notificationsEnabled else { return }
        let pct = max(response.fiveHour?.percent ?? 0, response.sevenDay?.percent ?? 0)
        let thresholds: [(Int, Bool)] = [
            (75, settings.notify75),
            (90, settings.notify90),
            (95, settings.notify95)
        ]
        for (threshold, enabled) in thresholds where enabled {
            if pct >= threshold && !notifiedThresholds.contains(threshold) {
                notifiedThresholds.insert(threshold)
                sendNotification(
                    title: "Claude Usage at \(threshold)%",
                    body:  "You have used \(pct)% of your Claude Code quota."
                )
            } else if pct < threshold {
                notifiedThresholds.remove(threshold)
            }
        }
    }

    private func sendNotification(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content   = UNMutableNotificationContent()
            content.title = title
            content.body  = body
            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content:    content,
                trigger:    nil   // deliver immediately
            )
            center.add(request)
        }
    }
}
