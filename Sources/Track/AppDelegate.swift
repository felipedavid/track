import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var database: Database!
    private var tracker: TimeTracker!
    private var focusTimer: FocusTimer!
    private var lockMonitor: LockMonitor!
    private var statusBarController: StatusBarController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let database = Database()
        let tracker = TimeTracker(database: database)
        let focusTimer = FocusTimer(tracker: tracker)

        self.database = database
        self.tracker = tracker
        self.focusTimer = focusTimer
        self.lockMonitor = LockMonitor(tracker: tracker, focusTimer: focusTimer)
        self.statusBarController = StatusBarController(tracker: tracker, focusTimer: focusTimer)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if tracker.isTracking {
            tracker.stop(reason: "app-quit")
        }
    }
}
