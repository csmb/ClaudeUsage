import SwiftUI

/// Entry point.
///
/// We use `@NSApplicationDelegateAdaptor` so that AppDelegate can own the
/// NSStatusItem (which requires AppKit) while the app still benefits from
/// SwiftUI's Settings scene for the preferences window.
///
/// LSUIElement=YES in Info.plist hides the Dock icon.
@main
struct ClaudeUsageApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Settings window — opened via the gear button in the popover
        Settings {
            SettingsView()
                .environmentObject(appDelegate.appState.settings)
        }
    }
}
