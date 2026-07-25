import AppKit
import ServiceManagement

/// Owns the menu bar item: live "● 1h 23m" style indicator plus the dropdown menu for
/// starting/stopping tracking and managing the focus timer.
final class StatusBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let tracker: TimeTracker
    private let focusTimer: FocusTimer
    private var refreshTimer: Timer?

    private let toggleTrackingItem = NSMenuItem()
    private let stopFocusTimerItem = NSMenuItem()
    private let todayItem = NSMenuItem()
    private let launchAtLoginItem = NSMenuItem()
    private let onToggleTracking: () -> Void
    private let onShowReport: () -> Void

    init(tracker: TimeTracker, focusTimer: FocusTimer, onToggleTracking: @escaping () -> Void, onShowReport: @escaping () -> Void) {
        self.tracker = tracker
        self.focusTimer = focusTimer
        self.onToggleTracking = onToggleTracking
        self.onShowReport = onShowReport
        super.init()

        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        buildMenu()

        tracker.onChange = { [weak self] in self?.refresh() }
        focusTimer.onChange = { [weak self] in self?.refresh() }

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    private func buildMenu() {
        let menu = NSMenu()
        menu.delegate = self

        toggleTrackingItem.target = self
        toggleTrackingItem.action = #selector(toggleTracking)
        menu.addItem(toggleTrackingItem)

        let focusMenu = NSMenu()
        let presets: [(String, Double)] = [("25 min", 25), ("1 hour", 60), ("2 hours", 120), ("3 hours", 180)]
        for (title, minutes) in presets {
            let item = NSMenuItem(title: title, action: #selector(startFocusPreset(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = minutes * 60
            focusMenu.addItem(item)
        }
        focusMenu.addItem(.separator())
        let customItem = NSMenuItem(title: "Custom…", action: #selector(startFocusCustom), keyEquivalent: "")
        customItem.target = self
        focusMenu.addItem(customItem)

        let focusMenuItem = NSMenuItem(title: "Start Focus Timer", action: nil, keyEquivalent: "")
        focusMenuItem.submenu = focusMenu
        menu.addItem(focusMenuItem)

        stopFocusTimerItem.title = "Stop Focus Timer"
        stopFocusTimerItem.target = self
        stopFocusTimerItem.action = #selector(stopFocusTimer)
        menu.addItem(stopFocusTimerItem)

        menu.addItem(.separator())

        todayItem.isEnabled = false
        menu.addItem(todayItem)

        menu.addItem(.separator())
        let reportItem = NSMenuItem(title: "Dashboard…", action: #selector(showReport), keyEquivalent: "")
        reportItem.target = self
        menu.addItem(reportItem)

        menu.addItem(.separator())
        launchAtLoginItem.title = "Launch at Login"
        launchAtLoginItem.target = self
        launchAtLoginItem.action = #selector(toggleLaunchAtLogin)
        menu.addItem(launchAtLoginItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        refresh()
    }

    @objc private func toggleTracking() {
        onToggleTracking()
    }

    @objc private func startFocusPreset(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? TimeInterval else { return }
        focusTimer.start(duration: seconds)
    }

    @objc private func startFocusCustom() {
        let alert = NSAlert()
        alert.messageText = "Custom Focus Timer"
        alert.informativeText = "Minutes to track before the beep:"
        alert.addButton(withTitle: "Start")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        input.stringValue = "180"
        alert.accessoryView = input
        alert.window.initialFirstResponder = input

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        guard let minutes = Double(input.stringValue), minutes > 0 else { return }
        focusTimer.start(duration: minutes * 60)
    }

    @objc private func stopFocusTimer() {
        focusTimer.cancel()
    }

    @objc private func showReport() {
        onShowReport()
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            print("Track: failed to toggle launch-at-login — \(error)")
        }
        refresh()
    }

    private func refresh() {
        stopFocusTimerItem.isHidden = !focusTimer.isActive
        let toggleTitle = tracker.isTracking ? "Stop Tracking" : "Start Tracking"
        // Shown as a hint only — the real shortcut is the global Carbon hot key in
        // GlobalHotKey.swift. A real keyEquivalent here would double-fire when the
        // combo is pressed while this menu happens to be open.
        toggleTrackingItem.title = "\(toggleTitle)  ⌃⌥⌘T"

        let todaySeconds = tracker.elapsedTodaySeconds()
        todayItem.title = "Today: \(formatDuration(todaySeconds))"

        launchAtLoginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off

        statusItem.button?.title = statusText(todaySeconds: todaySeconds)
    }

    private func statusText(todaySeconds: Int) -> String {
        let time = formatDuration(todaySeconds)
        if focusTimer.targetReached {
            return "⏰ \(time)"
        } else if tracker.isTracking {
            return "● \(time)"
        } else if todaySeconds > 0 {
            return "○ \(time)"
        } else {
            return "○"
        }
    }

    private func formatDuration(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        return String(format: "%dh %02dm", h, m)
    }
}
