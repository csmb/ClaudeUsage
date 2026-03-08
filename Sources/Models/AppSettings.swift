import Foundation
import ServiceManagement
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

    @Published var showPercentInMenuBar: Bool {
        didSet { defaults.set(showPercentInMenuBar, forKey: "showPercentInMenuBar") }
    }

    @Published var launchAtLogin: Bool {
        didSet {
            defaults.set(launchAtLogin, forKey: "launchAtLogin")
            applyLaunchAtLogin()
        }
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

    // MARK: - Appearance

    enum DisplayMode: String, CaseIterable, Identifiable {
        case percentAndIcon = "Percent + Icon"
        case percentOnly    = "Percent Only"
        case iconOnly       = "Icon Only"

        var id: String { rawValue }
    }

    @Published var displayModeRaw: String {
        didSet { defaults.set(displayModeRaw, forKey: "displayMode") }
    }

    var displayMode: DisplayMode {
        get { DisplayMode(rawValue: displayModeRaw) ?? .percentAndIcon }
        set { displayModeRaw = newValue.rawValue }
    }

    // MARK: - Init (reads persisted values, falls back to defaults)

    init() {
        pollIntervalOverride  = defaults.double(forKey: "pollIntervalOverride")
        showPercentInMenuBar  = defaults.object(forKey: "showPercentInMenuBar") as? Bool ?? true
        launchAtLogin         = defaults.bool(forKey: "launchAtLogin")
        notificationsEnabled  = defaults.object(forKey: "notificationsEnabled") as? Bool ?? true
        notify75              = defaults.object(forKey: "notify75") as? Bool ?? true
        notify90              = defaults.object(forKey: "notify90") as? Bool ?? true
        notify95              = defaults.object(forKey: "notify95") as? Bool ?? true
        displayModeRaw        = defaults.string(forKey: "displayMode") ?? DisplayMode.percentAndIcon.rawValue
    }

    // MARK: - Launch at Login

    private func applyLaunchAtLogin() {
        if #available(macOS 13.0, *) {
            smAppServiceSetEnabled(launchAtLogin)
        }
    }
}

@available(macOS 13.0, *)
private func smAppServiceSetEnabled(_ enable: Bool) {
    let service = SMAppService.mainApp
    do {
        if enable {
            try service.register()
        } else {
            try service.unregister()
        }
    } catch {
        print("Launch at login error: \(error.localizedDescription)")
    }
}
