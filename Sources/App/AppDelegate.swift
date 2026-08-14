import AppKit

/// Handles app lifecycle events that SwiftUI's @main doesn't cover:
/// - Sleep / wake (pause/resume polling)
final class AppDelegate: NSObject, NSApplicationDelegate {

    var appState              = AppState()   // eager init — must exist before SwiftUI reads body
    var statusItemController:  StatusItemController!
    var credentialWatcher:     CredentialWatcher!
    var demoSession:           DemoSession?

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {

        // Screenshot run: synthetic data, no polling, no credential watcher.
        if let config = DemoMode.current {
            if let name = config.appearance { NSApp.appearance = NSAppearance(named: name) }
            statusItemController = StatusItemController(appState: appState)
            demoSession = DemoSession(config: config, controller: statusItemController)
            demoSession?.start()
            return
        }

        // Wire up the menu bar icon + popover
        statusItemController = StatusItemController(appState: appState)

        // Watch Claude Code's config directory for credential changes
        credentialWatcher = CredentialWatcher {
            Task { await self.appState.refresh() }
        }
        credentialWatcher.start()

        // Start the polling loop (fires immediately, then on schedule)
        appState.polling.start()

        // Listen for sleep/wake
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    // MARK: - Sleep / Wake

    @objc private func systemWillSleep(_ notification: Notification) {
        appState.polling.stop()
    }

    @objc private func systemDidWake(_ notification: Notification) {
        // Brief delay lets the network come back up
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            self.appState.polling.start()
        }
    }

    // MARK: - Termination

    func applicationWillTerminate(_ notification: Notification) {
        appState.polling.stop()
        credentialWatcher?.stop()   // nil during --demo runs
    }
}
