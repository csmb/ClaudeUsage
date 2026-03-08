import Foundation
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
        isLoading = true
        defer { isLoading = false }

        do {
            let response = try await api.fetchUsage()
            usageResponse = response
            fetchedAt     = Date()
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

        } catch {
            self.error = error.localizedDescription
            // Keep showing cached data if available
        }
    }

    // MARK: - Computed Helpers

    var utilizationLevel: UtilizationLevel {
        guard let r = usageResponse else { return .low }
        let f5h = r.usage.fiveHour.fraction
        let f7d = r.usage.sevenDay.fraction
        return UtilizationLevel(fraction: max(f5h, f7d))
    }

    var menuBarTitle: String {
        guard let r = usageResponse else { return "..." }
        let pct = max(r.usage.fiveHour.percent, r.usage.sevenDay.percent)
        switch settings.displayMode {
        case .percentAndIcon: return "\(pct)%"
        case .percentOnly:    return "\(pct)%"
        case .iconOnly:       return ""
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
        let pct = max(response.usage.fiveHour.percent, response.usage.sevenDay.percent)
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
