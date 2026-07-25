import AppKit
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var database: Database!
    private var tracker: TimeTracker!
    private var focusTimer: FocusTimer!
    private var lockMonitor: LockMonitor!
    private var dashboardWindowController: DashboardWindowController!
    private var statusBarController: StatusBarController!
    private var globalHotKey: GlobalHotKey!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        var dbOverride: String?
        if let flagIndex = CommandLine.arguments.firstIndex(of: "--db"), flagIndex + 1 < CommandLine.arguments.count {
            dbOverride = CommandLine.arguments[flagIndex + 1]
        }
        let database = Database(overridePath: dbOverride)
        let tracker = TimeTracker(database: database)
        let focusTimer = FocusTimer(tracker: tracker)

        // Shared by the menu item and the global hot key so "stop cancels an active
        // focus timer" only has to be expressed once.
        func toggleTracking() {
            if tracker.isTracking {
                focusTimer.cancel()
                tracker.stop(reason: "manual")
            } else {
                tracker.start()
            }
        }

        let dashboardWindowController = DashboardWindowController(database: database)

        self.database = database
        self.tracker = tracker
        self.focusTimer = focusTimer
        self.lockMonitor = LockMonitor(tracker: tracker, focusTimer: focusTimer)
        self.dashboardWindowController = dashboardWindowController
        self.statusBarController = StatusBarController(
            tracker: tracker,
            focusTimer: focusTimer,
            onToggleTracking: toggleTracking,
            onShowReport: { dashboardWindowController.show() }
        )
        // Control+Option+Command+T: unlikely to collide with any app or system shortcut,
        // since it's captured globally regardless of which app is frontmost.
        self.globalHotKey = GlobalHotKey(
            keyCode: UInt32(kVK_ANSI_T),
            modifiers: UInt32(controlKey | optionKey | cmdKey),
            handler: toggleTracking
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        if tracker.isTracking {
            tracker.stop(reason: "app-quit")
        }
    }
}
