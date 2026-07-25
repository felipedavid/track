import CSQLite
import Foundation

/// `sqlite3_bind_text`/`sqlite3_bind_blob` need a destructor telling SQLite whether to copy
/// the bytes. SQLITE_TRANSIENT (copy now) is defined as a C macro casting -1 to a function
/// pointer, which doesn't import into Swift automatically.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Wraps the sessions table: one row per start/stop of time tracking, persisted forever.
final class Database {
    private var db: OpaquePointer?
    let path: String

    /// `overridePath` exists only so development/testing can point at a scratch database
    /// instead of the real one — the app itself always uses the default.
    init(overridePath: String? = nil) {
        if let overridePath {
            path = overridePath
        } else {
            let fm = FileManager.default
            let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let dir = appSupport.appendingPathComponent("Track", isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            path = dir.appendingPathComponent("track.db").path
        }

        guard sqlite3_open(path, &db) == SQLITE_OK else {
            fatalError("Track: unable to open database at \(path)")
        }
        exec("""
            CREATE TABLE IF NOT EXISTS sessions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                start_time INTEGER NOT NULL,
                end_time INTEGER,
                stop_reason TEXT
            );
        """)
        recoverDanglingSession()
    }

    deinit {
        sqlite3_close(db)
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        var errMsg: UnsafeMutablePointer<Int8>?
        let result = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if result != SQLITE_OK {
            let message = errMsg.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(errMsg)
            print("Track: SQLite error — \(message)")
            return false
        }
        return true
    }

    /// If the app was killed/crashed while a session was open, close it at its own start
    /// time (zero duration) rather than letting a stale open row silently inflate totals
    /// once time tracking resumes.
    private func recoverDanglingSession() {
        guard let session = openSession() else { return }
        endSession(id: session.id, endTimestamp: session.start, reason: "crash-recovery")
    }

    /// Starts a new open session and returns its row id.
    func startSession(at time: Date = Date()) -> Int64 {
        let sql = "INSERT INTO sessions (start_time) VALUES (?);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(time.timeIntervalSince1970))
        sqlite3_step(stmt)
        return sqlite3_last_insert_rowid(db)
    }

    func endSession(id: Int64, at time: Date = Date(), reason: String) {
        endSession(id: id, endTimestamp: Int64(time.timeIntervalSince1970), reason: reason)
    }

    private func endSession(id: Int64, endTimestamp: Int64, reason: String) {
        let sql = "UPDATE sessions SET end_time = ?, stop_reason = ? WHERE id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, endTimestamp)
        sqlite3_bind_text(stmt, 2, reason, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 3, id)
        sqlite3_step(stmt)
    }

    /// The currently open (unterminated) session, if any.
    func openSession() -> (id: Int64, start: Int64)? {
        let sql = "SELECT id, start_time FROM sessions WHERE end_time IS NULL ORDER BY id DESC LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return (sqlite3_column_int64(stmt, 0), sqlite3_column_int64(stmt, 1))
    }

    /// Total completed seconds tracked today, not including any currently open session.
    func completedSecondsToday() -> Int {
        let startOfDay = Calendar.current.startOfDay(for: Date())
        let sql = """
            SELECT COALESCE(SUM(end_time - start_time), 0)
            FROM sessions
            WHERE end_time IS NOT NULL AND start_time >= ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(startOfDay.timeIntervalSince1970))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    struct SessionRow {
        let id: Int64
        let start: Int64
        let end: Int64?
        let reason: String?
    }

    /// Every session ever recorded, oldest first — the raw material for the productivity report.
    func allSessions() -> [SessionRow] {
        let sql = "SELECT id, start_time, end_time, stop_reason FROM sessions ORDER BY start_time ASC;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var rows: [SessionRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let start = sqlite3_column_int64(stmt, 1)
            let end: Int64? = sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 2)
            let reason: String?
            if sqlite3_column_type(stmt, 3) == SQLITE_NULL {
                reason = nil
            } else {
                reason = String(cString: sqlite3_column_text(stmt, 3))
            }
            rows.append(SessionRow(id: id, start: start, end: end, reason: reason))
        }
        return rows
    }
}
