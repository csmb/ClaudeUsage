import AppKit
import SwiftUI
import Combine

/// Owns the NSStatusItem and the NSPopover.
/// Observes AppState to update the menu bar icon title and color.
final class StatusItemController: NSObject, NSPopoverDelegate {

    // MARK: - Properties

    private let statusItem: NSStatusItem
    private let popover    = NSPopover()
    private var appState:  AppState
    private var cancellables: Set<AnyCancellable> = []
    private var eventMonitor: Any?

    /// Windows the screenshot harness needs to locate. Nil until shown.
    var statusWindow: NSWindow? { statusItem.button?.window }
    private(set) var popoverWindow: NSWindow?

    // MARK: - Init

    init(appState: AppState) {
        self.appState = appState
        self.statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength
        )
        super.init()
        configureStatusItem()
        configurePopover(appState: appState)
        observeAppState()
    }

    // MARK: - Status Item

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.title  = "..."
        button.action = #selector(togglePopover)
        button.target = self
    }

    private func updateStatusButton() {
        guard let button = statusItem.button else { return }
        button.attributedTitle = appState.menuBarAttributedTitle
    }

    // MARK: - Popover

    private func configurePopover(appState: AppState) {
        // Screenshot runs keep the popover pinned open and skip the animation,
        // so the capture lands on a settled frame.
        popover.behavior = DemoMode.isActive ? .applicationDefined : .transient
        popover.animates = !DemoMode.isActive
        // Forced per-popover rather than via NSApp.appearance, which SwiftUI
        // overrides back to the system appearance.
        if let name = DemoMode.current?.appearance {
            popover.appearance = NSAppearance(named: name)
        }
        popover.delegate = self
        let hc = NSHostingController(
            rootView: PopoverView()
                .environmentObject(appState)
                .environmentObject(appState.settings)
        )
        hc.sizingOptions = .preferredContentSize
        popover.contentViewController = hc
    }

    @objc private func togglePopover() {
        if popover.isShown {
            closePopover()
        } else {
            openPopover()
        }
    }

    private func openPopover() {
        guard let button = statusItem.button else { return }
        popover.show(
            relativeTo: button.bounds,
            of: button,
            preferredEdge: .minY
        )
        // Close popover when user clicks outside
        eventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.closePopover()
        }
    }

    /// Opens the popover without the click-outside monitor, for `--demo` runs.
    func showPopoverForDemo() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popoverWindow = popover.contentViewController?.view.window
    }

    private func closePopover() {
        popover.performClose(nil)
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    // MARK: - Observe AppState

    private func observeAppState() {
        appState.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateStatusButton()
            }
            .store(in: &cancellables)

        // Initial paint
        updateStatusButton()
    }

    // MARK: - NSPopoverDelegate

    func popoverWillClose(_ notification: Notification) {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }
}
