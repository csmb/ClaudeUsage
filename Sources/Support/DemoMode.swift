import AppKit

/// Screenshot harness. Entirely opt-in via launch arguments — a normal launch
/// never enters any of these paths, never fabricates data, and never skips the
/// real keychain/API flow.
///
///     Claude Usage --demo mixed --appearance dark --shots ~/shots [--settings]
///
enum DemoMode {

    enum Scenario: String, CaseIterable {
        case healthy, mixed, heavy
    }

    struct Config {
        let scenario:        Scenario
        let appearance:      NSAppearance.Name?
        let outputDirectory: URL?
        let includeSettings: Bool
        /// Leaves the real desktop visible. Only useful for diagnosing how the
        /// menu bar tints itself, which follows the wallpaper rather than the
        /// windows underneath it.
        let skipBackdrop:    Bool

        /// macOS tints the menu bar from the desktop wallpaper rather than from
        /// the system appearance, so on a dark wallpaper the menu bar keeps its
        /// white glyphs even in Light mode. Shots that include the menu bar
        /// therefore need a dark surround or those glyphs end up on a pale
        /// strip. Override with `--backdrop light` on a light wallpaper.
        let menuBarIsDark:   Bool

        var isDark: Bool { appearance == .darkAqua }

        /// Filename stem, e.g. `mixed-dark`.
        var slug: String {
            let mode = appearance.map { $0 == .darkAqua ? "dark" : "light" } ?? "system"
            return "\(scenario.rawValue)-\(mode)"
        }
    }

    static let current: Config? = parse(ProcessInfo.processInfo.arguments)

    static var isActive: Bool { current != nil }

    static func parse(_ arguments: [String]) -> Config? {
        guard arguments.contains("--demo") else { return nil }

        func value(after flag: String) -> String? {
            guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
            let next = arguments[i + 1]
            return next.hasPrefix("--") ? nil : next
        }

        let appearance: NSAppearance.Name?
        switch value(after: "--appearance") {
        case "dark":  appearance = .darkAqua
        case "light": appearance = .aqua
        default:      appearance = nil
        }

        return Config(
            scenario:        Scenario(rawValue: value(after: "--demo") ?? "") ?? .mixed,
            appearance:      appearance,
            outputDirectory: value(after: "--shots").map {
                URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
            },
            includeSettings: arguments.contains("--settings"),
            skipBackdrop:    arguments.contains("--no-backdrop"),
            menuBarIsDark:   value(after: "--backdrop") != "light"
        )
    }
}

// MARK: - Backdrop

/// A neutral full-screen gradient that sits above ordinary windows but below
/// the menu bar and the popover. It keeps the desktop (and whatever else is
/// open) out of the shots, and gives the translucent menu bar something
/// consistent to tint from.
final class DemoBackdrop {

    private var windows: [NSWindow] = []

    var windowNumbers: [Int] { windows.map(\.windowNumber) }

    /// Switches tone. The popover and Settings windows are translucent, so
    /// whatever is behind them when they open is baked into the shot —
    /// window-only captures want a surround matching the app's appearance,
    /// menu bar captures want one matching the menu bar.
    ///
    /// Rebuilds rather than repaints: marking the existing content view dirty
    /// leaves the composited window buffer stale, and the translucent windows
    /// keep sampling the old tone.
    func setDark(_ dark: Bool) {
        hide()
        show(dark: dark)
    }

    func hide() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }

    func show(dark: Bool) {
        for screen in NSScreen.screens {
            let window = NSWindow(
                contentRect: screen.frame,
                styleMask:   .borderless,
                backing:     .buffered,
                defer:       false,
                screen:      screen
            )
            window.isOpaque           = true
            window.hasShadow          = false
            window.ignoresMouseEvents = true
            window.backgroundColor    = .clear
            // Above normal windows, below the menu bar (24) and the popover.
            window.level              = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue - 4)
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            window.contentView        = BackdropView(dark: dark)
            window.setFrame(screen.frame, display: true)
            window.orderFrontRegardless()
            windows.append(window)
        }
    }
}

private final class BackdropView: NSView {

    private let dark: Bool

    init(dark: Bool) {
        self.dark = dark
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        // Warm neutrals — close enough to Claude's palette to feel related,
        // quiet enough that the popover stays the subject.
        let top:    NSColor
        let bottom: NSColor
        if dark {
            top    = NSColor(srgbRed: 0.129, green: 0.122, blue: 0.114, alpha: 1)  // #211F1D
            bottom = NSColor(srgbRed: 0.075, green: 0.071, blue: 0.067, alpha: 1)  // #131211
        } else {
            top    = NSColor(srgbRed: 0.969, green: 0.961, blue: 0.945, alpha: 1)  // #F7F5F1
            bottom = NSColor(srgbRed: 0.902, green: 0.890, blue: 0.867, alpha: 1)  // #E6E3DD
        }
        NSGradient(starting: top, ending: bottom)?.draw(in: bounds, angle: -90)
    }
}

// MARK: - Session

/// Drives a single screenshot run: paint the backdrop, open the popover (and
/// optionally Settings), capture, quit.
@MainActor
final class DemoSession {

    private let config:     DemoMode.Config
    private let controller: StatusItemController
    private let backdrop = DemoBackdrop()
    private var settingsWindow: NSWindow?

    init(config: DemoMode.Config, controller: StatusItemController) {
        self.config     = config
        self.controller = controller
    }

    func start() {
        // Starts on the menu bar tone, for the close-up that comes first.
        if !config.skipBackdrop { backdrop.show(dark: config.menuBarIsDark) }
        NSApp.activate(ignoringOtherApps: true)

        if !DemoCapture.ensurePermission() {
            FileHandle.standardError.write(Data("""
            [demo] Screen Recording permission is not granted yet.
            [demo] Enable "Claude Usage" in System Settings > Privacy & Security > Screen Recording,
            [demo] then run this again. Opening that pane now.

            """.utf8))
            if let pane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(pane)
            }
            // Distinct status so the driving script can tell "needs permission"
            // apart from a real failure.
            exit(3)
        }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))

            // Close-up first: once the popover is open its arrow pokes into the
            // bottom of the menu bar and shows up in the crop.
            await captureMenuBarCloseUp()

            // Opening the popover also opens Settings, via PopoverView.onAppear.
            await repaintBackdrop(dark: config.isDark)
            controller.showPopoverForDemo()
            try? await Task.sleep(for: .milliseconds(800))
            if config.includeSettings { adoptSettingsWindow() }

            // Let the charts and the Settings window settle before capturing.
            try? await Task.sleep(for: .milliseconds(800))
            await captureWindows()

            await repaintBackdrop(dark: config.menuBarIsDark)
            await captureMenuBarWithPopover()

            NSApp.terminate(nil)
        }
    }

    /// Repaints and waits: the translucent windows re-sample what's behind them
    /// asynchronously, so capturing immediately catches the old tone.
    private func repaintBackdrop(dark: Bool) async {
        guard !config.skipBackdrop else { return }
        backdrop.setDark(dark)
        try? await Task.sleep(for: .milliseconds(400))
    }

    // MARK: - Settings window

    private func adoptSettingsWindow() {
        let known = Set(backdrop.windowNumbers
            + [controller.statusWindow?.windowNumber, controller.popoverWindow?.windowNumber].compactMap { $0 })
        settingsWindow = NSApp.windows.first {
            $0.isVisible && !known.contains($0.windowNumber) && $0.frame.width >= 200
        }
        guard let settings = settingsWindow else {
            let seen = NSApp.windows.map { "\($0.windowNumber):\($0.title):\(Int($0.frame.width))x\(Int($0.frame.height)):visible=\($0.isVisible)" }
            FileHandle.standardError.write(Data("[demo] no Settings window found. Windows: \(seen)\n".utf8))
            return
        }
        // Lift it above the backdrop so it keeps rendering.
        settings.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue - 3)
        if let name = config.appearance { settings.appearance = NSAppearance(named: name) }
        settings.center()
    }

    // MARK: - Capture

    private func path(_ suffix: String) -> URL? {
        config.outputDirectory?.appendingPathComponent("\(config.slug)-\(suffix).png")
    }

    /// No horizontal padding: the neighbouring status items sit only a few
    /// points away and any padding clips their edges into frame.
    private func captureMenuBarCloseUp() async {
        guard let url = path("menubar"),
              let status = controller.statusWindow,
              let screen = NSScreen.screens.first else { return }
        let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
        await DemoCapture.capture(
            screenRect: NSRect(
                x:      status.frame.minX,
                y:      screen.frame.maxY - menuBarHeight,
                width:  status.frame.width,
                height: menuBarHeight
            ),
            to: url
        )
    }

    private func captureWindows() async {
        // The popover is cropped out of the screen rather than captured as a
        // window: a window-only capture leaves out the behind-window blur, so
        // its translucent shell falls back to a dark tint that looks wrong
        // against light content. The Settings window is opaque and captures
        // cleanly on its own, which also keeps its corners transparent.
        if let popover = controller.popoverWindow, let url = path("popover") {
            let pad: CGFloat = 18
            await DemoCapture.capture(
                screenRect: NSRect(
                    x:      popover.frame.minX - pad,
                    y:      popover.frame.minY - pad,
                    width:  popover.frame.width + pad * 2,
                    height: popover.frame.height + pad     // no padding on top: the menu bar sits there
                ),
                to: url
            )
        }
        if let settings = settingsWindow, let url = path("settings") {
            await DemoCapture.capture(windowNumber: settings.windowNumber, to: url)
        }
    }

    private func captureMenuBarWithPopover() async {
        guard let url = path("menubar-popover"),
              let popover = controller.popoverWindow,
              let status = controller.statusWindow,
              let screen = NSScreen.screens.first else { return }
        // Run the right edge all the way to the edge of the screen. A crop that
        // stops mid-clock reads as a mistake; the whole right cluster reads as
        // a real macOS screenshot.
        let pad: CGFloat = 28
        let minX = min(popover.frame.minX, status.frame.minX) - pad
        await DemoCapture.capture(
            screenRect: NSRect(
                x:      minX,
                y:      popover.frame.minY - pad,
                width:  screen.frame.maxX - minX,
                height: screen.frame.maxY - popover.frame.minY + pad
            ),
            to: url
        )
    }
}
