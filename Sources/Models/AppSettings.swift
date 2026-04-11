import Foundation
import Combine

/// All user-configurable settings, backed by UserDefaults.
/// Uses @Published + manual UserDefaults sync instead of @AppStorage,
/// which only works correctly inside SwiftUI View types.
final class AppSettings: ObservableObject {

    private let defaults = UserDefaults.standard

    // MARK: - General

    @Published var pollIntervalOverride: Double {
        didSet { defaults.set(pollIntervalOverride, forKey: "pollIntervalOverride") }
    }

    // MARK: - Notifications

    @Published var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: "notificationsEnabled") }
    }

    @Published var notify75: Bool {
        didSet { defaults.set(notify75, forKey: "notify75") }
    }

    @Published var notify90: Bool {
        didSet { defaults.set(notify90, forKey: "notify90") }
    }

    @Published var notify95: Bool {
        didSet { defaults.set(notify95, forKey: "notify95") }
    }

    // MARK: - Init (reads persisted values, falls back to defaults)

    init() {
        pollIntervalOverride  = defaults.double(forKey: "pollIntervalOverride")
        notificationsEnabled  = defaults.object(forKey: "notificationsEnabled") as? Bool ?? true
        notify75              = defaults.object(forKey: "notify75") as? Bool ?? true
        notify90              = defaults.object(forKey: "notify90") as? Bool ?? true
        notify95              = defaults.object(forKey: "notify95") as? Bool ?? true
    }

}
