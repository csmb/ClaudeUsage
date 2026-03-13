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
        popover.behavior = .transient
        popover.animates = true
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
