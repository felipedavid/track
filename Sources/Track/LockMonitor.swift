import AppKit
import Foundation

/// Stops time tracking automatically when the user steps away from the computer:
/// screen lock or system sleep. A running focus timer is cancelled too, since its
/// target is no longer meaningful once tracking has been interrupted.
final class LockMonitor {
    private let tracker: TimeTracker
    private let focusTimer: FocusTimer

    init(tracker: TimeTracker, focusTimer: FocusTimer) {
        self.tracker = tracker
        self.focusTimer = focusTimer

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleScreenLock),
            name: Notification.Name("com.apple.screenIsLocked"),
            object: nil
        )

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func handleScreenLock() {
        stopIfTracking(reason: "screen-lock")
    }

    @objc private func handleSleep() {
        stopIfTracking(reason: "sleep")
    }

    private func stopIfTracking(reason: String) {
        guard tracker.isTracking else { return }
        focusTimer.cancel()
        tracker.stop(reason: reason)
    }
}
