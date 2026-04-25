import Foundation

/// Manages the adaptive polling timer.
///
/// - Default interval: 5 minutes (adjusted by AppState based on utilization)
/// - The timer fires on the main run loop to avoid threading surprises.

final class PollingManager {

    var onTick: (() -> Void)?

    private var timer:           Timer?
    private var currentInterval: TimeInterval = 300

    // MARK: - Start / Stop

    func start() {
        scheduleTimer(interval: currentInterval)
        // Fire immediately so the UI is populated without waiting
        onTick?()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Adaptive Interval

    func updateInterval(_ interval: TimeInterval) {
        let clamped = max(30, min(300, interval))
        guard clamped != currentInterval else { return }
        currentInterval = clamped
        scheduleTimer(interval: currentInterval)
    }

    // MARK: - Private

    private func scheduleTimer(interval: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(
            withTimeInterval: interval,
            repeats: true
        ) { [weak self] _ in
            self?.onTick?()
        }
        // Allow the timer to fire even when the user is scrolling in the popover
        RunLoop.main.add(timer!, forMode: .common)
    }
}
