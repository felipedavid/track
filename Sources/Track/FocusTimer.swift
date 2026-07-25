import AppKit
import Foundation

/// A countdown that beeps once it elapses, without stopping time tracking — the user
/// keeps working (and logging hours) until they notice the beep and stop manually.
final class FocusTimer {
    private let tracker: TimeTracker
    private var timer: Timer?
    private(set) var targetDate: Date?
    private(set) var targetReached = false

    /// Fired whenever the timer starts, is cancelled, or reaches its target.
    var onChange: (() -> Void)?

    init(tracker: TimeTracker) {
        self.tracker = tracker
    }

    var isActive: Bool { timer != nil || targetReached }

    func start(duration: TimeInterval) {
        invalidateTimer()
        if !tracker.isTracking {
            tracker.start()
        }
        targetDate = Date().addingTimeInterval(duration)
        targetReached = false
        timer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            self?.fire()
        }
        onChange?()
    }

    func cancel() {
        guard isActive else { return }
        invalidateTimer()
        targetDate = nil
        targetReached = false
        onChange?()
    }

    /// Seconds remaining until target; negative once the target has passed.
    func remainingSeconds() -> Int? {
        guard let target = targetDate else { return nil }
        return Int(target.timeIntervalSince(Date()))
    }

    private func invalidateTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func fire() {
        timer = nil
        targetReached = true
        beep()
        onChange?()
    }

    private func beep() {
        for i in 0..<3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.6) {
                NSSound.beep()
            }
        }
    }
}
