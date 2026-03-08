import Foundation
import SwiftUI

/// All user-configurable settings, backed by UserDefaults / @AppStorage.
/// Each property has a sensible default so the app works on first launch.
final class AppSettings: ObservableObject {

    // MARK: - General

    /// Override poll interval (seconds). 0 = adaptive (default).
    @AppStorage("pollIntervalOverride") var pollIntervalOverride: Double = 0

    /// Show percentage in menu bar (true) or just the icon symbol (false).
    @AppStorage("showPercentInMenuBar") var showPercentInMenuBar: Bool = true

    /// Launch at login.
    @AppStorage("launchAtLogin") var launchAtLogin: Bool = false {
        didSet { applyLaunchAtLogin() }
    }

    // MARK: - Notifications

    @AppStorage("notificationsEnabled") var notificationsEnabled: Bool = true
    @AppStorage("notify75") var notify75: Bool = true
    @AppStorage("notify90") var notify90: Bool = true
    @AppStorage("notify95") var notify95: Bool = true

    // MARK: - Appearance

    enum DisplayMode: String, CaseIterable, Identifiable {
        case percentAndIcon = "Percent + Icon"
        case percentOnly    = "Percent Only"
        case iconOnly       = "Icon Only"

        var id: String { rawValue }
    }

    @AppStorage("displayMode") var displayModeRaw: String = DisplayMode.percentAndIcon.rawValue

    var displayMode: DisplayMode {
        get { DisplayMode(rawValue: displayModeRaw) ?? .percentAndIcon }
        set { displayModeRaw = newValue.rawValue }
    }

    // MARK: - Launch at Login

    private func applyLaunchAtLogin() {
        // SMAppService is the modern API (macOS 13+).
        // We wrap it in availability so the project compiles on older SDKs too.
        if #available(macOS 13.0, *) {
            import_SMAppService(enable: launchAtLogin)
        }
    }
}

// MARK: - SMAppService wrapper (avoids top-level import)

@available(macOS 13.0, *)
private func import_SMAppService(enable: Bool) {
    // Importing ServiceManagement at the call-site avoids a linker
    // issue when compiling on older SDKs.  Replace this with a direct
    // `import ServiceManagement` at the top of the file once your
    // deployment target is macOS 13+.
    //
    // For now this is a no-op placeholder; wire up SMAppService.mainApp
    // when you add ServiceManagement.framework to the target.
    //
    //   let service = SMAppService.mainApp
    //   try? enable ? service.register() : service.unregister()
}
