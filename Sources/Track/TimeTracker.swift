import AppKit
import Foundation

/// Tracks whether work time is currently being logged. Elapsed time is always computed
/// live from `Date()` rather than accumulated in a counter, so it stays correct regardless
/// of how often the UI happens to redraw.
final class TimeTracker {
    private let database: Database
    private(set) var isTracking = false
    private(set) var currentStart: Date?
    private var currentSessionId: Int64?

    /// Fired on start/stop so observers (status bar, focus timer) can react.
    var onChange: (() -> Void)?

    init(database: Database) {
        self.database = database
    }

    func start() {
        guard !isTracking else { return }
        let now = Date()
        currentSessionId = database.startSession(at: now)
        currentStart = now
        isTracking = true
        NSSound(named: "Pop")?.play()
        onChange?()
    }

    func stop(reason: String) {
        guard isTracking, let id = currentSessionId else { return }
        database.endSession(id: id, reason: reason)
        isTracking = false
        currentSessionId = nil
        currentStart = nil
        NSSound(named: "Bottle")?.play()
        onChange?()
    }

    /// Seconds tracked today, including live elapsed time of the current open session.
    func elapsedTodaySeconds() -> Int {
        var total = database.completedSecondsToday()
        if let start = currentStart {
            total += Int(Date().timeIntervalSince(start))
        }
        return total
    }

    /// Seconds elapsed in the current running session only.
    func currentSessionSeconds() -> Int {
        guard let start = currentStart else { return 0 }
        return Int(Date().timeIntervalSince(start))
    }
}
