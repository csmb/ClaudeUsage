import Foundation

/// Manages the adaptive polling timer.
///
/// - Default interval: 5 minutes (adjusted by AppState based on utilization)
/// - Circuit breaker: after 5 consecutive failures the interval is clamped
///   to 5 minutes so the app doesn't hammer the API when credentials are bad.
/// - The timer fires on the main run loop to avoid threading surprises.

final class PollingManager {

    // MARK: - State

    var onTick: (() -> Void)?

    private var timer:            Timer?
    private var currentInterval:  TimeInterval = 300
    private var failureCount:     Int          = 0
    private let maxFailures:      Int          = 5

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
        reschedule()
    }

    func recordSuccess() {
        failureCount = 0
    }

    func recordFailure() {
        failureCount += 1
        if failureCount >= maxFailures {
            // Circuit breaker: back off to 5 minutes
            currentInterval = 300
            reschedule()
        }
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

    private func reschedule() {
        scheduleTimer(interval: currentInterval)
    }
}
