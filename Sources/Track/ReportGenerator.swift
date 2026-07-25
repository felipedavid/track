import Foundation

/// Computes every productivity metric derivable from `sessions` and renders it into a
/// self-contained HTML string: streaks, a GitHub-style calendar heatmap, weekly totals
/// against a 30h/40h goal, a day×hour "punch card" of when you actually work, a 7-day
/// momentum trend, session-length distribution, and how sessions ended. Pure computation
/// — no disk I/O, no windowing. `DashboardWindowController` calls `buildHTML()` once to
/// load the page, then `buildRefreshJSON()` on every subsequent refresh so what's on
/// screen is always live.
final class ReportGenerator {
    private let database: Database
    private let calendar: Calendar

    private static let goalLow = 20.0
    private static let goalGood = 30.0
    private static let goalAmazing = 40.0
    private static let goalCarmack = 60.0
    private static let dailyGoal = 6.0

    private static let bucketLabels = ["<15m", "15-30m", "30-60m", "1-2h", "2-4h", "4h+"]
    private static let reasonLabels: [String: String] = [
        "manual": "Manual stop",
        "screen-lock": "Screen locked",
        "sleep": "System slept",
        "app-quit": "App quit",
        "crash-recovery": "Crash recovery",
    ]

    init(database: Database) {
        self.database = database
        var cal = Calendar.current
        cal.timeZone = TimeZone.current
        self.calendar = cal
    }

    /// Full page for the first load (or whenever there's no live page to update in place).
    func buildHTML() -> (html: String, hasData: Bool) {
        let rows = database.allSessions()
        guard !rows.isEmpty else { return (Self.emptyStateHTML, false) }
        let json = buildDataJSON(from: rows)
        return (Self.htmlTemplate.replacingOccurrences(of: "__DATA_JSON__", with: json), true)
    }

    /// Fresh data only, for refreshing an already-loaded dashboard via JS injection
    /// instead of a full reload — a reload resets scroll position, which is jarring on
    /// a page you might be mid-read on. `nil` means there's nothing to show yet.
    func buildRefreshJSON() -> String? {
        let rows = database.allSessions()
        guard !rows.isEmpty else { return nil }
        return buildDataJSON(from: rows)
    }

    // MARK: - Date helpers

    private func startOfHour(_ date: Date) -> Date {
        let comps = calendar.dateComponents([.year, .month, .day, .hour], from: date)
        return calendar.date(from: comps)!
    }

    /// 0 = Monday ... 6 = Sunday, unlike Calendar's native 1=Sunday...7=Saturday.
    private func mondayIndex(_ date: Date) -> Int {
        let wd = calendar.component(.weekday, from: date)
        return (wd + 5) % 7
    }

    private func minutesSinceMidnight(_ date: Date) -> Double {
        let comps = calendar.dateComponents([.hour, .minute, .second], from: date)
        return Double(comps.hour ?? 0) * 60 + Double(comps.minute ?? 0) + Double(comps.second ?? 0) / 60
    }

    /// Splits [start, end) into (dayStart, hour, seconds) chunks at each hour boundary,
    /// so a session spanning midnight or crossing hours attributes time correctly.
    private func splitRange(_ start: Date, _ end: Date) -> [(day: Date, hour: Int, seconds: Double)] {
        var out: [(Date, Int, Double)] = []
        var cur = start
        while cur < end {
            let hour = calendar.component(.hour, from: cur)
            let nextHour = calendar.date(byAdding: .hour, value: 1, to: startOfHour(cur))!
            let boundary = min(end, nextHour)
            out.append((calendar.startOfDay(for: cur), hour, boundary.timeIntervalSince(cur)))
            cur = boundary
        }
        return out
    }

    private func bucket(for seconds: Double) -> Int {
        let m = seconds / 60
        if m < 15 { return 0 }
        if m < 30 { return 1 }
        if m < 60 { return 2 }
        if m < 120 { return 3 }
        if m < 240 { return 4 }
        return 5
    }

    private func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        let n = s.count
        let mid = n / 2
        return n % 2 == 1 ? s[mid] : (s[mid - 1] + s[mid]) / 2
    }

    private func fmtClock(_ minutesSinceMidnight: Double?) -> String? {
        guard let m = minutesSinceMidnight else { return nil }
        var total = Int(m.rounded())
        total = ((total % 1440) + 1440) % 1440
        let h = total / 60, mm = total % 60
        let period = h < 12 ? "AM" : "PM"
        var h12 = h % 12
        if h12 == 0 { h12 = 12 }
        return String(format: "%d:%02d %@", h12, mm, period)
    }

    private func dateString(_ date: Date) -> String {
        Self.dateFormatter.string(from: date)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let generatedAtFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm a"
        return f
    }()

    private static let monthLabelFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM yyyy"
        return f
    }()

    // MARK: - Stats computation

    private func buildDataJSON(from rows: [Database.SessionRow]) -> String {
        let now = Date()

        var dailySeconds: [Date: Double] = [:]
        // punch[weekday 0=Mon...6=Sun][hour 0...23]
        var punch = Array(repeating: Array(repeating: 0.0, count: 24), count: 7)
        var sessionDurations: [Double] = []
        var stopReasonStats: [String: (count: Int, seconds: Double)] = [:]
        var dayBoundsStart: [Date: Double] = [:]
        var dayBoundsEnd: [Date: Double] = [:]
        var sessionCountByDay: [Date: Int] = [:]
        // Deep work = sessions >= 1h, a proxy for focused vs. fragmented time. Bucketed
        // by the week the session started in (unsplit — this is about session shape,
        // not calendar attribution, so no need for splitRange's hour/day slicing).
        var weeklyDeep: [Date: (total: Double, deep: Double)] = [:]
        var isTrackingNow = false
        var firstDay: Date?
        var lastDay: Date?

        let deepWorkThreshold: Double = 3600

        // Recent-pattern badges (Night Owl, Early Bird, ...) look only at the last 14
        // days, since a habit from six months ago shouldn't still be flashing a badge.
        let today = calendar.startOfDay(for: now)
        let last14Start = calendar.date(byAdding: .day, value: -13, to: today)!
        var last14TotalSeconds: Double = 0
        var last14NightSeconds: Double = 0
        var last14EarlySeconds: Double = 0
        var last14WeekendSeconds: Double = 0
        var last14SessionDurations: [Double] = []
        var last14DaysTracked = Set<Date>()

        func extend(_ range: inout [Date: Double], _ day: Date, _ value: Double, reducer: (Double, Double) -> Double) {
            range[day] = range[day].map { reducer($0, value) } ?? value
        }

        for row in rows {
            let start = Date(timeIntervalSince1970: TimeInterval(row.start))
            let end: Date
            if let e = row.end {
                end = Date(timeIntervalSince1970: TimeInterval(e))
            } else {
                isTrackingNow = true
                end = now
            }

            let d0 = calendar.startOfDay(for: start)
            firstDay = firstDay.map { min($0, d0) } ?? d0
            lastDay = lastDay.map { max($0, d0) } ?? d0
            sessionCountByDay[d0, default: 0] += 1

            guard end > start else {
                if dailySeconds[d0] == nil { dailySeconds[d0] = 0 }
                continue
            }

            if row.end != nil {
                let dur = end.timeIntervalSince(start)
                sessionDurations.append(dur)
                let key = row.reason ?? "manual"
                let existing = stopReasonStats[key] ?? (0, 0)
                stopReasonStats[key] = (existing.count + 1, existing.seconds + dur)

                let weekStart = calendar.date(byAdding: .day, value: -mondayIndex(d0), to: d0)!
                var weekStat = weeklyDeep[weekStart] ?? (0, 0)
                weekStat.total += dur
                if dur >= deepWorkThreshold { weekStat.deep += dur }
                weeklyDeep[weekStart] = weekStat

                if d0 >= last14Start { last14SessionDurations.append(dur) }
            }

            let smin = minutesSinceMidnight(start)
            let emin = minutesSinceMidnight(end)
            extend(&dayBoundsStart, d0, smin, reducer: min)
            extend(&dayBoundsEnd, d0, emin, reducer: max)

            for chunk in splitRange(start, end) {
                dailySeconds[chunk.day, default: 0] += chunk.seconds
                punch[mondayIndex(chunk.day)][chunk.hour] += chunk.seconds
                lastDay = lastDay.map { max($0, chunk.day) } ?? chunk.day

                if chunk.day >= last14Start {
                    last14TotalSeconds += chunk.seconds
                    if chunk.hour >= 21 || chunk.hour < 5 { last14NightSeconds += chunk.seconds }
                    if chunk.hour >= 5 && chunk.hour < 9 { last14EarlySeconds += chunk.seconds }
                    if mondayIndex(chunk.day) >= 5 { last14WeekendSeconds += chunk.seconds }
                    last14DaysTracked.insert(chunk.day)
                }
            }
        }

        let first = firstDay ?? calendar.startOfDay(for: now)
        let last = lastDay ?? first

        var allDays: [Date] = []
        var d = first
        while d <= last {
            allDays.append(d)
            d = calendar.date(byAdding: .day, value: 1, to: d)!
        }

        // Calendar heatmap window: a rolling ~year ending today, aligned to the most
        // recent Sunday so the grid renders exactly like GitHub's contribution graph —
        // fixed to "today", not clipped to the data's own date range.
        let approxStart = calendar.date(byAdding: .day, value: -364, to: today)!
        let startWeekday = calendar.component(.weekday, from: approxStart) // 1=Sun...7=Sat
        let calendarStart = calendar.date(byAdding: .day, value: -(startWeekday - 1), to: approxStart)!
        var calendarDays: [Date] = []
        var cd = calendarStart
        while cd <= today {
            calendarDays.append(cd)
            cd = calendar.date(byAdding: .day, value: 1, to: cd)!
        }
        let dailySeries: [[String: Any]] = calendarDays.map {
            ["date": dateString($0), "seconds": dailySeconds[$0] ?? 0]
        }

        var weekly: [Date: Double] = [:]
        for day in allDays {
            let wkStart = calendar.date(byAdding: .day, value: -mondayIndex(day), to: day)!
            weekly[wkStart, default: 0] += dailySeconds[day] ?? 0
        }
        let weeklySeries: [[String: Any]] = weekly.keys.sorted().map {
            ["week_start": dateString($0), "seconds": weekly[$0] ?? 0]
        }

        var monthly: [Date: Double] = [:]
        for day in allDays {
            let monthComps = calendar.dateComponents([.year, .month], from: day)
            let monthStart = calendar.date(from: monthComps)!
            monthly[monthStart, default: 0] += dailySeconds[day] ?? 0
        }
        let monthlySeries: [[String: Any]] = monthly.keys.sorted().map {
            ["month": dateString($0), "label": Self.monthLabelFormatter.string(from: $0), "seconds": monthly[$0] ?? 0]
        }

        let punchSeries: [[Double]] = punch

        var histCounts = [Int](repeating: 0, count: 6)
        for dur in sessionDurations { histCounts[bucket(for: dur)] += 1 }
        let histogram: [[String: Any]] = (0..<6).map { ["label": Self.bucketLabels[$0], "count": histCounts[$0]] }

        let stopReasons: [[String: Any]] = stopReasonStats
            .sorted { $0.value.seconds > $1.value.seconds }
            .map { key, val in
                ["reason": Self.reasonLabels[key] ?? key, "count": val.count, "seconds": val.seconds]
            }

        let workedDays = allDays.filter { (dailySeconds[$0] ?? 0) > 0 }.sorted()
        let workedSet = Set(workedDays)
        var longestStreak = 0, run = 0
        var prev: Date?
        for day in workedDays {
            if let p = prev, calendar.date(byAdding: .day, value: 1, to: p) == day {
                run += 1
            } else {
                run = 1
            }
            longestStreak = max(longestStreak, run)
            prev = day
        }

        var currentStreak = 0
        var cursor = workedSet.contains(today) ? today : calendar.date(byAdding: .day, value: -1, to: today)!
        while workedSet.contains(cursor) {
            currentStreak += 1
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor)!
        }

        let typicalStart = fmtClock(median(Array(dayBoundsStart.values)))
        let typicalStop = fmtClock(median(Array(dayBoundsEnd.values)))

        // .max is guaranteed non-nil here: dailySeconds/weekly/sessionCountByDay are each
        // populated from every row, and buildHTML() already checked rows is non-empty.
        let bestDay = dailySeconds.max { $0.value < $1.value } ?? (key: today, value: 0)
        let bestWeek = weekly.max { $0.value < $1.value } ?? (key: today, value: 0)
        let mostSessionsDay = sessionCountByDay.max { $0.value < $1.value } ?? (key: today, value: 0)
        let personalRecords: [String: Any] = [
            "best_day": ["date": dateString(bestDay.key), "seconds": bestDay.value],
            "best_week": ["week_start": dateString(bestWeek.key), "seconds": bestWeek.value],
            "most_sessions_day": ["date": dateString(mostSessionsDay.key), "count": mostSessionsDay.value],
        ]

        let allTimeDeepSeconds = sessionDurations.filter { $0 >= deepWorkThreshold }.reduce(0, +)
        let allTimeSessionSeconds = sessionDurations.reduce(0, +)
        let deepWorkWeekly: [[String: Any]] = weeklyDeep.keys.sorted().map { wk in
            let stat = weeklyDeep[wk]!
            let ratio = stat.total > 0 ? (stat.deep / stat.total) * 100 : 0
            return ["week_start": dateString(wk), "ratio": ratio, "total_seconds": stat.total]
        }
        let deepWork: [String: Any] = [
            "all_time_ratio": allTimeSessionSeconds > 0 ? (allTimeDeepSeconds / allTimeSessionSeconds) * 100 : 0,
            "weekly": deepWorkWeekly,
        ]

        // Raw last-14-day aggregates for the "recent patterns" badges (Night Owl, Early
        // Bird, ...) — badge thresholds live in JS alongside the other band logic; this
        // is just the numbers.
        let recent: [String: Any] = [
            "total_seconds": last14TotalSeconds,
            "night_ratio": last14TotalSeconds > 0 ? last14NightSeconds / last14TotalSeconds : 0,
            "early_ratio": last14TotalSeconds > 0 ? last14EarlySeconds / last14TotalSeconds : 0,
            "weekend_ratio": last14TotalSeconds > 0 ? last14WeekendSeconds / last14TotalSeconds : 0,
            "avg_session_seconds": last14SessionDurations.isEmpty ? 0 : last14SessionDurations.reduce(0, +) / Double(last14SessionDurations.count),
            "session_count": last14SessionDurations.count,
            "days_tracked": last14DaysTracked.count,
        ]

        let weekStartToday = calendar.date(byAdding: .day, value: -mondayIndex(today), to: today)!
        let monthComps = calendar.dateComponents([.year, .month], from: today)
        let monthStartToday = calendar.date(from: monthComps)!

        let daysAtGoal = workedDays.filter { (dailySeconds[$0] ?? 0) >= Self.dailyGoal * 3600 }.count

        let todaySeconds = dailySeconds[today] ?? 0
        let weekSeconds = allDays.filter { $0 >= weekStartToday }.reduce(0.0) { $0 + (dailySeconds[$1] ?? 0) }
        let monthSeconds = allDays.filter { $0 >= monthStartToday }.reduce(0.0) { $0 + (dailySeconds[$1] ?? 0) }
        let allTimeSeconds = dailySeconds.values.reduce(0, +)

        let summary: [String: Any] = [
            "today_seconds": todaySeconds,
            "week_seconds": weekSeconds,
            "month_seconds": monthSeconds,
            "all_time_seconds": allTimeSeconds,
            "current_streak": currentStreak,
            "longest_streak": longestStreak,
            "total_sessions": sessionDurations.count,
            "avg_session_seconds": sessionDurations.isEmpty ? 0 : sessionDurations.reduce(0, +) / Double(sessionDurations.count),
            "longest_session_seconds": sessionDurations.max() ?? 0,
            "avg_daily_seconds": workedDays.isEmpty ? 0 : allTimeSeconds / Double(workedDays.count),
            "days_tracked": workedDays.count,
            "days_at_goal": daysAtGoal,
            "first_day": dateString(first),
            "last_day": dateString(last),
            "typical_start": typicalStart as Any,
            "typical_stop": typicalStop as Any,
            "is_tracking_now": isTrackingNow,
        ]

        let data: [String: Any] = [
            "generated_at": Self.generatedAtFormatter.string(from: now),
            "goals": ["low": Self.goalLow, "good": Self.goalGood, "amazing": Self.goalAmazing, "carmack": Self.goalCarmack, "daily": Self.dailyGoal],
            "summary": summary,
            "daily": dailySeries,
            "weekly": weeklySeries,
            "monthly": monthlySeries,
            "punch": punchSeries,
            "histogram": histogram,
            "stop_reasons": stopReasons,
            "records": personalRecords,
            "deep_work": deepWork,
            "recent": recent,
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: data, options: []),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return "{}"
        }
        return jsonString
    }

    // MARK: - Empty state

    private static let emptyStateHTML = #"""
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Track — Dashboard</title>
<style>
  :root { --bg:#08090b; --text:#f3f1ec; --muted:#8b8b93; --brand:#ff7a45; }
  html, body { margin:0; height:100%; }
  body {
    background:
      radial-gradient(ellipse 900px 500px at 15% -10%, color-mix(in srgb, var(--brand) 14%, transparent), transparent 60%),
      var(--bg);
    color: var(--text);
    font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", Arial, sans-serif;
    display:flex; align-items:center; justify-content:center; text-align:center;
  }
  h1 { font-size: 20px; margin: 0 0 8px; }
  p { color: var(--muted); font-size: 14px; margin: 0; }
</style>
</head>
<body>
  <div>
    <h1>No sessions yet</h1>
    <p>Start tracking from the menu bar, then reopen the dashboard.</p>
  </div>
</body>
</html>
"""#

    // MARK: - HTML template

    private static let htmlTemplate = #"""
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Track — Dashboard</title>
<style>
  :root {
    --bg: #08090b;
    --card: #131317;
    --text: #f3f1ec;
    --muted: #8b8b93;
    --border: rgba(255,255,255,0.08);
    --shadow: 0 1px 0 0 rgba(255,255,255,0.045) inset, 0 14px 28px -14px rgba(0,0,0,0.55);
    --brand: #ff7a45;
    --brand2: #ffb648;
    --accent: #ff7a45;
    --accent2: #8b5cf6;
    --low: #ff453a;
    --below: #ff9f0a;
    --good: #32d67c;
    --amazing1: #ffd60a;
    --amazing2: #bf5af2;
    --carmack1: #ff375f;
    --carmack2: #ff9500;
    --track: rgba(255,255,255,0.06);
    --mono: ui-monospace, "SF Mono", Menlo, monospace;
  }
  * { box-sizing: border-box; overflow-anchor: none; }
  html, body { margin: 0; padding: 0; }
  body {
    background:
      radial-gradient(ellipse 900px 520px at 12% -8%, color-mix(in srgb, var(--brand) 13%, transparent), transparent 60%),
      radial-gradient(ellipse 700px 480px at 100% 6%, color-mix(in srgb, var(--accent2) 10%, transparent), transparent 55%),
      var(--bg);
    background-attachment: fixed;
    color: var(--text);
    font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", Arial, sans-serif;
    -webkit-font-smoothing: antialiased;
    padding: 28px 20px 64px;
  }
  .wrap { max-width: 1080px; margin: 0 auto; }
  .num { font-variant-numeric: tabular-nums; font-feature-settings: "tnum"; }

  header { display: flex; align-items: baseline; justify-content: space-between; flex-wrap: wrap; gap: 8px; margin-bottom: 8px; }
  header h1 { font-size: 15px; font-weight: 700; margin: 0; letter-spacing: 0.02em; color: var(--muted); font-family: var(--mono); text-transform: uppercase; }
  header h1 span { color: var(--brand); }
  header .meta { color: var(--muted); font-size: 12.5px; display: flex; align-items: center; gap: 6px; }
  .live-dot { width: 7px; height: 7px; border-radius: 50%; background: var(--good); display: inline-block; animation: pulse 1.6s ease-in-out infinite; }
  @keyframes pulse { 0%,100% { opacity: 1; transform: scale(1); } 50% { opacity: 0.45; transform: scale(0.8); } }

  .card {
    background: linear-gradient(180deg, rgba(255,255,255,0.035), rgba(255,255,255,0) 45%), var(--card);
    border: 1px solid var(--border);
    border-radius: 14px;
    box-shadow: var(--shadow);
    padding: 20px 22px;
  }
  .card + .card, .grid + .card, .card + .grid, .grid + .grid { margin-top: 16px; }
  .card h2 { font-size: 12.5px; font-weight: 600; margin: 0 0 14px; color: var(--muted); text-transform: uppercase; letter-spacing: 0.06em; }
  .card h2::before { content: "›"; color: var(--brand); font-family: var(--mono); margin-right: 7px; font-weight: 700; }

  .hero { position: relative; display: flex; flex-wrap: wrap; gap: 24px; align-items: center; justify-content: space-between; background: none; border: none; box-shadow: none; padding: 30px 6px 26px; overflow: visible; }
  .hero::before {
    content: ""; position: absolute; z-index: -1; pointer-events: none;
    inset: -30px -10px auto -10px; height: 260px;
    background: radial-gradient(ellipse 460px 200px at 18% 35%, color-mix(in srgb, var(--brand) 20%, transparent), transparent 72%);
    filter: blur(6px);
  }
  .hero-left { min-width: 220px; }
  .hero-label { color: var(--brand); font-size: 12px; font-weight: 700; text-transform: uppercase; letter-spacing: 0.14em; margin-bottom: 10px; }
  .hero-value { font-family: var(--mono); font-size: 68px; font-weight: 600; letter-spacing: -0.02em; line-height: 1; }
  .badge { display: inline-flex; align-items: center; gap: 6px; padding: 5px 12px; border-radius: 999px; font-size: 12.5px; font-weight: 700; margin-top: 12px; border: 1px solid transparent; }
  .badge.low { background: color-mix(in srgb, var(--low) 14%, transparent); color: var(--low); border-color: color-mix(in srgb, var(--low) 30%, transparent); }
  .badge.below { background: color-mix(in srgb, var(--below) 14%, transparent); color: var(--below); border-color: color-mix(in srgb, var(--below) 30%, transparent); }
  .badge.good { background: color-mix(in srgb, var(--good) 14%, transparent); color: var(--good); border-color: color-mix(in srgb, var(--good) 30%, transparent); }
  .badge.amazing { background: linear-gradient(90deg, color-mix(in srgb, var(--amazing1) 18%, transparent), color-mix(in srgb, var(--amazing2) 18%, transparent)); color: var(--amazing1); border-color: color-mix(in srgb, var(--amazing2) 35%, transparent); }
  .badge.carmack { background: linear-gradient(90deg, color-mix(in srgb, var(--carmack1) 20%, transparent), color-mix(in srgb, var(--carmack2) 20%, transparent)); color: var(--carmack1); border-color: color-mix(in srgb, var(--carmack1) 40%, transparent); animation: glow 1.8s ease-in-out infinite; }
  .badge.pattern { background: color-mix(in srgb, var(--accent2) 16%, transparent); color: var(--accent2); border-color: color-mix(in srgb, var(--accent2) 32%, transparent); font-size: 12.5px; padding: 6px 13px; cursor: default; }
  @keyframes glow { 0%,100% { box-shadow: 0 0 0 rgba(255,55,95,0); } 50% { box-shadow: 0 0 14px color-mix(in srgb, var(--carmack1) 45%, transparent); } }
  .hero-sub { color: var(--muted); font-size: 12.5px; margin-top: 10px; }

  .hero-right { flex: 1; min-width: 260px; }
  .goalbar { position: relative; height: 10px; border-radius: 999px; background: var(--track); overflow: visible; margin-top: 26px; }
  .goalbar-fill { position: absolute; inset: 0; width: 0%; border-radius: 999px; transition: width 900ms cubic-bezier(.16,1,.3,1); }
  .goalbar-fill.low { background: var(--low); box-shadow: 0 0 12px 0 color-mix(in srgb, var(--low) 55%, transparent); }
  .goalbar-fill.below { background: var(--below); box-shadow: 0 0 12px 0 color-mix(in srgb, var(--below) 55%, transparent); }
  .goalbar-fill.good { background: var(--good); box-shadow: 0 0 12px 0 color-mix(in srgb, var(--good) 55%, transparent); }
  .goalbar-fill.amazing { background: linear-gradient(90deg, var(--amazing1), var(--amazing2)); box-shadow: 0 0 12px 0 color-mix(in srgb, var(--amazing2) 55%, transparent); }
  .goalbar-fill.carmack { background: linear-gradient(90deg, var(--carmack1), var(--carmack2)); box-shadow: 0 0 12px 0 color-mix(in srgb, var(--carmack1) 55%, transparent); }
  .goalbar-tick { position: absolute; top: -20px; transform: translateX(-50%); font-size: 10.5px; color: var(--muted); white-space: nowrap; font-family: var(--mono); }
  .goalbar-tick::after { content: ""; position: absolute; top: 20px; left: 50%; width: 1px; height: 10px; background: var(--border); }

  .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 12px; }
  .stat {
    background: linear-gradient(180deg, rgba(255,255,255,0.035), rgba(255,255,255,0) 45%), var(--card);
    border: 1px solid var(--border); border-radius: 13px; box-shadow: var(--shadow); padding: 16px 18px;
    opacity: 0; transform: translateY(6px); animation: rise 480ms cubic-bezier(.16,1,.3,1) forwards;
    transition: border-color 200ms ease;
  }
  .stat:hover { border-color: color-mix(in srgb, var(--brand) 35%, var(--border)); }
  .stat .label { font-size: 11.5px; color: var(--muted); font-weight: 600; text-transform: uppercase; letter-spacing: 0.04em; margin-bottom: 6px; }
  .stat .value { font-family: var(--mono); font-size: 21px; font-weight: 600; letter-spacing: -0.01em; }
  .stat .sub { font-size: 11.5px; color: var(--muted); margin-top: 4px; }
  @keyframes rise { to { opacity: 1; transform: translateY(0); } }

  .card-head { display: flex; align-items: center; justify-content: space-between; flex-wrap: wrap; gap: 8px; margin-bottom: 14px; }
  .card-head h2 { margin: 0; }

  .two-col { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; }
  @media (max-width: 720px) { .two-col { grid-template-columns: 1fr; } }

  svg text { fill: var(--muted); font-size: 10.5px; font-family: var(--mono); }
  .bar { transition: transform 700ms cubic-bezier(.16,1,.3,1), opacity 300ms; cursor: pointer; }
  .bar:hover { opacity: 0.82; }
  .axis-line { stroke: var(--border); stroke-width: 1; }
  .goal-line { stroke: var(--border); stroke-width: 1; stroke-dasharray: 3,3; }

  .tooltip {
    position: fixed; pointer-events: none; z-index: 50;
    background: #f3f1ec; color: #0c0d0f;
    font-family: var(--mono);
    font-size: 12px; font-weight: 600; padding: 6px 10px; border-radius: 8px;
    opacity: 0; transform: translate(-50%, -6px) scale(0.96);
    transition: opacity 120ms ease, transform 120ms ease;
    white-space: nowrap;
    box-shadow: 0 8px 20px rgba(0,0,0,0.4);
  }
  .tooltip.show { opacity: 1; transform: translate(-50%, -10px) scale(1); }
  .tooltip .tt-sub { opacity: 0.65; font-weight: 500; }

  .heat-cell { rx: 2.5; transition: filter 120ms ease; cursor: pointer; }
  .heat-cell:hover { filter: brightness(1.4); }

  .legend { display: flex; gap: 14px; flex-wrap: wrap; font-size: 11.5px; color: var(--muted); margin-top: 10px; }
  .legend .dot { width: 8px; height: 8px; border-radius: 2px; display: inline-block; margin-right: 5px; vertical-align: middle; }

  .rbar-row { display: flex; align-items: center; gap: 10px; margin-bottom: 10px; }
  .rbar-label { width: 118px; font-size: 12px; color: var(--muted); flex-shrink: 0; }
  .rbar-track { flex: 1; height: 10px; background: var(--track); border-radius: 999px; overflow: hidden; }
  .rbar-fill { height: 100%; width: 0%; border-radius: 999px; transition: width 800ms cubic-bezier(.16,1,.3,1); }
  .rbar-val { width: 92px; text-align: right; font-size: 12px; color: var(--muted); flex-shrink: 0; font-family: var(--mono); }

  footer { text-align: center; color: var(--muted); font-size: 11.5px; margin-top: 32px; font-family: var(--mono); }
</style>
</head>
<body>
<div class="wrap">
  <header>
    <h1><span>›</span> track / dashboard</h1>
    <div class="meta" id="meta"></div>
  </header>

  <div class="card hero" id="hero"></div>

  <div style="height:16px"></div>
  <div class="grid" id="stats"></div>

  <div class="card" style="margin-top:16px">
    <h2>Personal records</h2>
    <div class="grid" id="records"></div>
  </div>

  <div class="card" style="margin-top:16px">
    <h2>Daily activity — past year</h2>
    <div id="calendar"></div>
    <div class="legend" id="calendar-legend"></div>
  </div>

  <div class="card" style="margin-top:16px">
    <h2>Weekly total vs. goal</h2>
    <div id="weekly"></div>
    <div class="legend">
      <span><span class="dot" style="background:var(--low)"></span>Low (&lt;20h)</span>
      <span><span class="dot" style="background:var(--below)"></span>Below goal (20–30h)</span>
      <span><span class="dot" style="background:var(--good)"></span>Good (30–40h)</span>
      <span><span class="dot" style="background:linear-gradient(90deg,var(--amazing1),var(--amazing2))"></span>Amazing (40–60h)</span>
      <span><span class="dot" style="background:linear-gradient(90deg,var(--carmack1),var(--carmack2))"></span>John Carmack Level (60h+)</span>
    </div>
    <div class="card-head" style="margin-top:18px; margin-bottom:8px;">
      <h2 style="margin:0">Goal adherence</h2>
      <div id="adherence-stat" style="font-size:12.5px; color:var(--muted);"></div>
    </div>
    <div id="adherence"></div>
  </div>

  <div class="card" style="margin-top:16px">
    <h2>Monthly totals</h2>
    <div id="monthly"></div>
  </div>

  <div class="card" style="margin-top:16px">
    <div class="card-head">
      <h2>Momentum — last 90 days</h2>
      <div id="trend-badge"></div>
    </div>
    <div id="trend"></div>
  </div>

  <div class="card" style="margin-top:16px">
    <div class="card-head">
      <h2>Deep work</h2>
      <div id="deepwork-stat"></div>
    </div>
    <div class="hero-sub" style="margin:-6px 0 12px;">Share of tracked time in sessions of 1h or longer, per week — a proxy for focused vs. fragmented work.</div>
    <div id="deepwork"></div>
  </div>

  <div class="card" style="margin-top:16px">
    <h2>Last 2 weeks</h2>
    <div id="badges"></div>
  </div>

  <div class="card" style="margin-top:16px">
    <h2>When you work</h2>
    <div id="punch"></div>
  </div>

  <div class="two-col" style="margin-top:16px">
    <div class="card"><h2>Session length</h2><div id="hist"></div></div>
    <div class="card"><h2>How sessions ended</h2><div id="reasons"></div></div>
  </div>

  <footer>Live from track.db — nothing here leaves your Mac.</footer>
</div>
<div class="tooltip" id="tooltip"></div>

<script>
let DATA = __DATA_JSON__;

function fmtHM(seconds) {
  seconds = Math.max(0, Math.round(seconds));
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  if (h === 0) return m + "m";
  return h + "h " + String(m).padStart(2, "0") + "m";
}

function weekBand(seconds) {
  const h = seconds / 3600;
  const g = DATA.goals;
  if (h < g.low) return { key: "low", label: "Low Week" };
  if (h < g.good) return { key: "below", label: "Below Goal" };
  if (h < g.amazing) return { key: "good", label: "Good Week" };
  if (h < g.carmack) return { key: "amazing", label: "Amazing Week" };
  return { key: "carmack", label: "John Carmack Level" };
}

const tooltip = document.getElementById("tooltip");
function showTooltip(evt, title, sub) {
  tooltip.innerHTML = title + (sub ? '<div class="tt-sub">' + sub + "</div>" : "");
  tooltip.style.left = evt.clientX + "px";
  tooltip.style.top = evt.clientY + "px";
  tooltip.classList.add("show");
}
function hideTooltip() { tooltip.classList.remove("show"); }

function svgEl(tag, attrs) {
  const e = document.createElementNS("http://www.w3.org/2000/svg", tag);
  for (const k in attrs) e.setAttribute(k, attrs[k]);
  return e;
}

function renderHeader() {
  const meta = document.getElementById("meta");
  meta.innerHTML = (DATA.summary.is_tracking_now ? '<span class="live-dot"></span> Tracking now &middot; ' : "") +
    "Updated " + DATA.generated_at;
}

function renderHero() {
  const s = DATA.summary;
  const band = weekBand(s.week_seconds);
  const g = DATA.goals;
  const hero = document.getElementById("hero");

  const scaleMax = Math.max(g.carmack + 8, s.week_seconds / 3600 + 4);
  const pct = Math.min(100, (s.week_seconds / 3600 / scaleMax) * 100);

  let subText;
  const hrs = s.week_seconds / 3600;
  if (band.key === "carmack") {
    subText = fmtHM((hrs - g.carmack) * 3600) + " past 60h — John Carmack Level";
  } else if (band.key === "amazing") {
    subText = fmtHM((g.carmack - hrs) * 3600) + " to John Carmack Level (60h)";
  } else if (band.key === "good") {
    subText = fmtHM((g.amazing - hrs) * 3600) + " to an amazing week (40h)";
  } else if (band.key === "below") {
    subText = fmtHM((g.good - hrs) * 3600) + " to hit your 30h goal";
  } else {
    subText = fmtHM(Math.max(0, g.good * 3600 - s.week_seconds)) + " to reach the 30h weekly goal";
  }

  hero.innerHTML =
    '<div class="hero-left">' +
      '<div class="hero-label">This Week</div>' +
      '<div class="hero-value num">' + fmtHM(s.week_seconds) + '</div>' +
      '<div class="badge ' + band.key + '">' + band.label + '</div>' +
      '<div class="hero-sub">' + subText + '</div>' +
    '</div>' +
    '<div class="hero-right">' +
      '<div class="goalbar">' +
        tick(g.low, scaleMax, "20h") + tick(g.good, scaleMax, "30h · goal") + tick(g.amazing, scaleMax, "40h") + tick(g.carmack, scaleMax, "60h") +
        '<div class="goalbar-fill ' + band.key + '" id="goalbar-fill"></div>' +
      '</div>' +
    '</div>';

  requestAnimationFrame(() => {
    document.getElementById("goalbar-fill").style.width = pct + "%";
  });

  function tick(hours, max, label) {
    const left = (hours / max) * 100;
    return '<div class="goalbar-tick" style="left:' + left + '%">' + label + '</div>';
  }
}

function dayBand(seconds) {
  const h = seconds / 3600;
  const g = DATA.goals;
  if (h < g.daily / 2) return { key: "low", label: "Low Day" };
  if (h < g.daily) return { key: "below", label: "Below Goal" };
  return { key: "good", label: "Goal Met" };
}

// Compares "this month so far" against the same number of days at the start of last
// month — a partial month vs. a full one wouldn't be a fair comparison.
function monthOverMonth() {
  const byDate = {};
  DATA.daily.forEach(d => { byDate[d.date] = d.seconds; });
  const today = new Date();
  const dom = today.getDate();
  const thisStart = new Date(today.getFullYear(), today.getMonth(), 1);
  const lastStart = new Date(today.getFullYear(), today.getMonth() - 1, 1);

  function sumRange(start, days) {
    let total = 0;
    for (let i = 0; i < days; i++) {
      const d = new Date(start);
      d.setDate(d.getDate() + i);
      total += byDate[d.toISOString().slice(0, 10)] || 0;
    }
    return total;
  }

  return { thisMonth: sumRange(thisStart, dom), lastMonthComparable: sumRange(lastStart, dom) };
}

function trendBadgeHTML(pct, suffix, opts) {
  opts = opts || {};
  const tag = opts.tag || "div";
  const up = pct >= 1, down = pct <= -1;
  const cls = up ? "good" : down ? "low" : "below";
  const arrow = up ? "▲" : down ? "▼" : "→";
  const style = tag === "div" ? "font-size:10.5px; padding:2px 7px; margin-top:6px;" : "font-size:10.5px; padding:2px 7px;";
  return "<" + tag + ' class="badge ' + cls + '" style="' + style + '">' + arrow + " " + Math.abs(pct).toFixed(0) + suffix + "</" + tag + ">";
}

function renderStats() {
  const s = DATA.summary;
  const band = dayBand(s.today_seconds);
  const remaining = DATA.goals.daily * 3600 - s.today_seconds;
  const todaySub = remaining > 0 ? fmtHM(remaining) + " to daily goal (" + DATA.goals.daily + "h)" : fmtHM(-remaining) + " past goal";
  const todayTile =
    '<div class="stat" style="animation-delay:0ms">' +
      '<div class="label">Today</div>' +
      '<div class="value num">' + fmtHM(s.today_seconds) + '</div>' +
      '<div class="badge ' + band.key + '" style="font-size:11px; padding:3px 9px; margin-top:6px;">' + band.label + '</div>' +
      '<div class="sub">' + todaySub + '</div>' +
    '</div>';

  const mom = monthOverMonth();
  const momBadge = mom.lastMonthComparable > 0
    ? trendBadgeHTML(((mom.thisMonth - mom.lastMonthComparable) / mom.lastMonthComparable) * 100, "% vs last month")
    : "";
  const monthTile =
    '<div class="stat" style="animation-delay:35ms">' +
      '<div class="label">This Month</div>' +
      '<div class="value num">' + fmtHM(s.month_seconds) + '</div>' +
      momBadge +
    '</div>';

  const items = [
    ["All Time", fmtHM(s.all_time_seconds), s.first_day + " → " + s.last_day],
    ["Current Streak", s.current_streak + (s.current_streak === 1 ? " day" : " days"), "longest: " + s.longest_streak],
    ["Avg / Day Worked", fmtHM(s.avg_daily_seconds), s.days_at_goal + " of " + s.days_tracked + " days hit " + DATA.goals.daily + "h"],
    ["Avg Session", fmtHM(s.avg_session_seconds), s.total_sessions + " sessions total"],
    ["Longest Session", fmtHM(s.longest_session_seconds), null],
    ["Typical Hours", (s.typical_start || "—") + " – " + (s.typical_stop || "—"), "median clock-in/out"],
  ];
  const grid = document.getElementById("stats");
  grid.innerHTML = todayTile + monthTile + items.map(([label, value, sub], i) =>
    '<div class="stat" style="animation-delay:' + ((i + 2) * 35) + 'ms">' +
      '<div class="label">' + label + '</div>' +
      '<div class="value num">' + value + '</div>' +
      (sub ? '<div class="sub">' + sub + '</div>' : "") +
    '</div>'
  ).join("");
}

function fmtDateLabel(iso) {
  return new Date(iso + "T00:00:00").toLocaleDateString("en-US", { weekday: "short", month: "short", day: "numeric" });
}

function renderRecords() {
  const r = DATA.records;
  const items = [
    ["Best Day", fmtHM(r.best_day.seconds), fmtDateLabel(r.best_day.date)],
    ["Best Week", fmtHM(r.best_week.seconds), "week of " + fmtDateLabel(r.best_week.week_start)],
    ["Most Sessions in a Day", r.most_sessions_day.count + (r.most_sessions_day.count === 1 ? " session" : " sessions"), fmtDateLabel(r.most_sessions_day.date)],
  ];
  const grid = document.getElementById("records");
  grid.innerHTML = items.map(([label, value, sub], i) =>
    '<div class="stat" style="animation-delay:' + (i * 35) + 'ms">' +
      '<div class="label">' + label + '</div>' +
      '<div class="value num">' + value + '</div>' +
      '<div class="sub">' + sub + '</div>' +
    '</div>'
  ).join("");
}

// GitHub-style calendar heatmap. DATA.daily is already a Sunday-aligned window ending
// today, so this just lays it out in 7-row columns — no date math needed here.
function renderCalendar() {
  const container = document.getElementById("calendar");
  const data = DATA.daily;
  let max = 0;
  data.forEach(d => { if (d.seconds > max) max = d.seconds; });
  const days = data.map(d => new Date(d.date + "T00:00:00"));

  const cell = 11, gap = 3, leftPad = 26, topPad = 16;
  const weeks = Math.ceil(days.length / 7);
  const width = weeks * (cell + gap) + leftPad;
  const height = 7 * (cell + gap) + topPad;
  const svg = svgEl("svg", { width, height, viewBox: "0 0 " + width + " " + height });

  function level(sec) {
    if (!sec || sec <= 0) return 0;
    const r = sec / max;
    if (r < 0.25) return 1;
    if (r < 0.5) return 2;
    if (r < 0.75) return 3;
    return 4;
  }
  const colors = ["var(--track)", "#ff7a4530", "#ff7a4570", "#ff7a45ab", "#ff7a45"];

  let lastMonth = -1;
  days.forEach((d, i) => {
    const col = Math.floor(i / 7), row = i % 7; // row 0 = Sunday, matching GitHub
    const sec = data[i].seconds;
    const rect = svgEl("rect", {
      class: "heat-cell",
      x: col * (cell + gap) + leftPad, y: row * (cell + gap) + topPad,
      width: cell, height: cell, rx: 2.5,
      fill: colors[level(sec)],
    });
    rect.addEventListener("mousemove", (e) => showTooltip(e, fmtHM(sec), d.toDateString()));
    rect.addEventListener("mouseleave", hideTooltip);
    svg.appendChild(rect);

    if (row === 0) {
      const m = d.getMonth();
      if (m !== lastMonth) {
        const t = svgEl("text", { x: col * (cell + gap) + leftPad, y: 10 });
        t.textContent = d.toLocaleString("en-US", { month: "short" });
        svg.appendChild(t);
        lastMonth = m;
      }
    }
  });

  ["Mon", "Wed", "Fri"].forEach((label, idx) => {
    const row = [1, 3, 5][idx];
    const t = svgEl("text", { x: 0, y: row * (cell + gap) + topPad + 9 });
    t.textContent = label;
    svg.appendChild(t);
  });

  container.innerHTML = "";
  container.appendChild(svg);

  document.getElementById("calendar-legend").innerHTML =
    'Less ' + colors.map(c => '<span class="dot" style="background:' + c + '"></span>').join("") + ' More';
}

// Weekly totals with explicit 20h/30h/40h goal reference lines drawn on the chart
// itself, so the goal context doesn't depend on reading the legend below.
function renderWeekly() {
  const container = document.getElementById("weekly");
  const items = DATA.weekly;
  const g = DATA.goals;
  const width = Math.max(container.clientWidth || 600, 300);
  const height = 200, padBottom = 24, padTop = 28;
  const gap = 6;
  const n = items.length;
  const barW = (width - gap * (n - 1)) / n;
  // Scale is driven by the actual data (with headroom to the 30h goal line at minimum),
  // not by the full goal ladder — otherwise a handful of low weeks get dwarfed by
  // reference lines for 40h/60h weeks that never happened.
  const maxHours = Math.max(g.good + 8, ...items.map(w => w.seconds / 3600 + 4));
  const yFor = hours => height - padBottom - (hours / maxHours) * (height - padTop - padBottom);

  const svg = svgEl("svg", { width, height, viewBox: "0 0 " + width + " " + height });
  const defs = svgEl("defs", {});
  defs.innerHTML = '<linearGradient id="amazingGrad" x1="0" y1="0" x2="0" y2="1">' +
    '<stop offset="0%" stop-color="var(--amazing1)"/><stop offset="100%" stop-color="var(--amazing2)"/></linearGradient>' +
    '<linearGradient id="carmackGrad" x1="0" y1="0" x2="0" y2="1">' +
    '<stop offset="0%" stop-color="var(--carmack1)"/><stop offset="100%" stop-color="var(--carmack2)"/></linearGradient>';
  svg.appendChild(defs);
  svg.appendChild(svgEl("line", { class: "axis-line", x1: 0, x2: width, y1: height - padBottom, y2: height - padBottom }));

  [[g.low, "20h"], [g.good, "30h · goal"], [g.amazing, "40h"], [g.carmack, "60h · Carmack"]].forEach(([hrs, label]) => {
    if (hrs > maxHours * 1.02) return; // don't draw reference lines far above any real data
    const y = yFor(hrs);
    svg.appendChild(svgEl("line", { class: "goal-line", x1: 0, x2: width, y1: y, y2: y }));
    const t = svgEl("text", { x: width, y: y - 4, "text-anchor": "end" });
    t.textContent = label;
    svg.appendChild(t);
  });

  items.forEach((w, i) => {
    const hrs = w.seconds / 3600;
    const y = yFor(hrs);
    const h = Math.max(1, height - padBottom - y);
    const x = i * (barW + gap);
    const band = weekBand(w.seconds).key;
    const rect = svgEl("rect", {
      class: "bar", x, y, width: barW, height: h,
      rx: Math.min(4, barW / 3),
      fill: band === "amazing" ? "url(#amazingGrad)" : band === "carmack" ? "url(#carmackGrad)" : "var(--" + band + ")",
      style: "transform-box: fill-box; transform-origin: bottom; transform: scaleY(0);",
    });
    requestAnimationFrame(() => {
      rect.style.transitionDelay = (i * 18) + "ms";
      rect.style.transform = "scaleY(1)";
    });
    rect.addEventListener("mousemove", (e) => showTooltip(e, fmtHM(w.seconds), "week of " + w.week_start));
    rect.addEventListener("mouseleave", hideTooltip);
    svg.appendChild(rect);

    if (i % Math.ceil(n / 10 || 1) === 0) {
      const t = svgEl("text", { x: x + barW / 2, y: height - 6, "text-anchor": "middle" });
      t.textContent = w.week_start.slice(5);
      svg.appendChild(t);
    }
  });

  container.innerHTML = "";
  container.appendChild(svg);
}

// A compact strip, one cell per week, colored by goal band — a win/loss record for the
// 30h goal itself rather than raw activity, so a long run of misses is as visible as a
// long streak of hits.
function renderAdherence() {
  const items = DATA.weekly;
  const container = document.getElementById("adherence");
  const width = Math.max(container.clientWidth || 600, 300);
  const gap = 2;
  const cell = Math.max(4, Math.min(14, width / items.length - gap));
  const height = cell;
  const svg = svgEl("svg", { width: items.length * (cell + gap), height, viewBox: "0 0 " + (items.length * (cell + gap)) + " " + height });
  const colorMap = { low: "var(--low)", below: "var(--below)", good: "var(--good)", amazing: "var(--amazing2)", carmack: "var(--carmack1)" };

  let hit = 0;
  items.forEach((w, i) => {
    const band = weekBand(w.seconds);
    if (band.key !== "low" && band.key !== "below") hit++;
    const rect = svgEl("rect", { class: "heat-cell", x: i * (cell + gap), y: 0, width: cell, height: cell, rx: 2, fill: colorMap[band.key] });
    rect.addEventListener("mousemove", (e) => showTooltip(e, band.label, "week of " + w.week_start + " · " + fmtHM(w.seconds)));
    rect.addEventListener("mouseleave", hideTooltip);
    svg.appendChild(rect);
  });

  container.innerHTML = "";
  container.appendChild(svg);

  const pct = items.length ? Math.round((hit / items.length) * 100) : 0;
  document.getElementById("adherence-stat").textContent = hit + " of " + items.length + " weeks hit the 30h goal (" + pct + "%)";
}

function renderMonthly() {
  barChart("monthly", DATA.monthly, {
    height: 180,
    value: m => m.seconds,
    label: m => m.label.split(" ")[0],
    color: () => "var(--accent)",
    tooltipTitle: m => fmtHM(m.seconds),
    tooltipSub: m => m.label,
  });
}

function renderDeepWork() {
  const d = DATA.deep_work;
  const badgeClass = d.all_time_ratio >= 60 ? "good" : d.all_time_ratio >= 35 ? "below" : "low";
  let statHTML = '<span class="badge ' + badgeClass + '">' + d.all_time_ratio.toFixed(0) + '% all-time</span>';
  if (d.weekly.length >= 4) {
    const avg = arr => arr.reduce((a, b) => a + b.ratio, 0) / arr.length;
    const delta = avg(d.weekly.slice(-2)) - avg(d.weekly.slice(-4, -2));
    statHTML += " " + trendBadgeHTML(delta, "pts / 2wk", { tag: "span" });
  }
  document.getElementById("deepwork-stat").innerHTML = statHTML;
  barChart("deepwork", d.weekly, {
    height: 150,
    gap: 4,
    fixedMax: 100,
    value: w => w.ratio,
    label: w => w.week_start.slice(5),
    color: () => "var(--accent2)",
    tooltipTitle: w => w.ratio.toFixed(0) + "% deep work",
    tooltipSub: w => "week of " + w.week_start,
  });
}

// Lifestyle badges from the last 14 days only — a pattern from months ago shouldn't
// still be flashing "Night Owl" if you've since become a morning person.
function renderRecentBadges() {
  const r = DATA.recent;
  const container = document.getElementById("badges");
  const badges = [];

  if (r.total_seconds > 0) {
    if (r.night_ratio >= 0.25) {
      badges.push(["Night Owl", Math.round(r.night_ratio * 100) + "% of tracked time fell between 9pm–5am"]);
    } else if (r.early_ratio >= 0.25) {
      badges.push(["Early Bird", Math.round(r.early_ratio * 100) + "% of tracked time fell between 5am–9am"]);
    }
    if (r.weekend_ratio >= 0.25) {
      badges.push(["Weekend Warrior", Math.round(r.weekend_ratio * 100) + "% of tracked time was on Sat/Sun"]);
    }
  }
  if (r.session_count > 0) {
    if (r.avg_session_seconds >= 5400) {
      badges.push(["Marathoner", "averaged " + fmtHM(r.avg_session_seconds) + " per session"]);
    } else if (r.avg_session_seconds < 1800 && r.session_count >= 10) {
      badges.push(["Sprinter", r.session_count + " short sessions, frequent context switches"]);
    }
  }
  if (r.days_tracked >= 12) {
    badges.push(["Consistent", r.days_tracked + " of the last 14 days tracked"]);
  }

  if (badges.length === 0) {
    container.innerHTML = '<div class="hero-sub" style="margin:0;">Not enough of a pattern yet — keep tracking.</div>';
    return;
  }

  container.innerHTML = badges.map(([label, detail]) =>
    '<span class="badge pattern" style="margin:0 8px 8px 0;" title="' + detail + '">' + label + '</span>'
  ).join("");
}

// 7-day rolling average of daily hours over the last 90 days, with a dashed reference
// line for the daily pace needed to hit the 30h weekly goal, plus a badge comparing the
// last 7 days to the 7 before that so the trend direction is explicit, not implied.
function renderTrend() {
  const container = document.getElementById("trend");
  const series = DATA.daily;
  const rolling = series.map((d, i) => {
    const from = Math.max(0, i - 6);
    const slice = series.slice(from, i + 1);
    return { date: d.date, seconds: slice.reduce((a, b) => a + b.seconds, 0) / slice.length };
  });
  const shown = rolling.slice(-90);

  const width = Math.max(container.clientWidth || 600, 300);
  const height = 160, padBottom = 22, padTop = 16;
  const paceSec = (DATA.goals.good * 3600) / 7;
  const maxSec = Math.max(...shown.map(d => d.seconds), paceSec * 1.15);
  const xFor = i => (i / (shown.length - 1)) * width;
  const yFor = sec => height - padBottom - (sec / maxSec) * (height - padTop - padBottom);

  const svg = svgEl("svg", { width, height, viewBox: "0 0 " + width + " " + height });
  const defs = svgEl("defs", {});
  defs.innerHTML = '<linearGradient id="trendGrad" x1="0" y1="0" x2="0" y2="1">' +
    '<stop offset="0%" stop-color="var(--accent)" stop-opacity="0.35"/><stop offset="100%" stop-color="var(--accent)" stop-opacity="0"/></linearGradient>';
  svg.appendChild(defs);

  const py = yFor(paceSec);
  svg.appendChild(svgEl("line", { class: "goal-line", x1: 0, x2: width, y1: py, y2: py }));
  const pt = svgEl("text", { x: width, y: py - 4, "text-anchor": "end" });
  pt.textContent = "pace for 30h/wk";
  svg.appendChild(pt);

  let linePath = "";
  shown.forEach((d, i) => { linePath += (i === 0 ? "M" : "L") + xFor(i) + "," + yFor(d.seconds) + " "; });
  linePath = linePath.trim();
  const areaPath = linePath + " L " + xFor(shown.length - 1) + "," + (height - padBottom) +
    " L " + xFor(0) + "," + (height - padBottom) + " Z";

  const area = svgEl("path", { d: areaPath, fill: "url(#trendGrad)", opacity: "0" });
  svg.appendChild(area);
  const line = svgEl("path", { d: linePath, fill: "none", stroke: "var(--accent)", "stroke-width": 2, "stroke-linecap": "round", "stroke-linejoin": "round" });
  svg.appendChild(line);

  container.innerHTML = "";
  container.appendChild(svg);

  requestAnimationFrame(() => {
    const len = line.getTotalLength();
    line.style.strokeDasharray = len;
    line.style.strokeDashoffset = len;
    requestAnimationFrame(() => {
      line.style.transition = "stroke-dashoffset 900ms cubic-bezier(.16,1,.3,1)";
      line.style.strokeDashoffset = 0;
      area.style.transition = "opacity 900ms ease 200ms";
      area.style.opacity = "1";
    });
  });

  const last7 = series.slice(-7).reduce((a, b) => a + b.seconds, 0);
  const prev7 = series.slice(-14, -7).reduce((a, b) => a + b.seconds, 0);
  const badge = document.getElementById("trend-badge");
  if (prev7 <= 0) {
    badge.innerHTML = "";
  } else {
    const pct = ((last7 - prev7) / prev7) * 100;
    const up = pct >= 1, down = pct <= -1;
    const arrow = up ? "▲" : down ? "▼" : "→";
    const cls = up ? "good" : down ? "low" : "below";
    badge.innerHTML = '<span class="badge ' + cls + '">' + arrow + " " + Math.abs(pct).toFixed(0) + "% vs prior week</span>";
  }
}

// Day × hour "punch card" — replaces separate day-of-week and hour-of-day charts with
// one grid that shows exactly when work happens (e.g. "Tuesday mornings"), not just
// which days or which hours in isolation.
function renderPunch() {
  const container = document.getElementById("punch");
  const grid = DATA.punch; // 7 (Mon..Sun) x 24
  const dayLabels = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
  let max = 0;
  grid.forEach(row => row.forEach(v => { if (v > max) max = v; }));

  const cell = Math.min(15, ((Math.max(container.clientWidth || 640, 320)) - 34) / 24 - 3);
  const gap = 3, leftPad = 32, topPad = 16;
  const width = 24 * (cell + gap) + leftPad;
  const height = 7 * (cell + gap) + topPad;
  const svg = svgEl("svg", { width, height, viewBox: "0 0 " + width + " " + height });

  function level(v) {
    if (!v || v <= 0) return 0;
    const r = v / max;
    if (r < 0.25) return 1;
    if (r < 0.5) return 2;
    if (r < 0.75) return 3;
    return 4;
  }
  const colors = ["var(--track)", "#8b5cf630", "#8b5cf670", "#8b5cf6ab", "#8b5cf6"];

  for (let h = 0; h < 24; h++) {
    if (h % 3 === 0) {
      const t = svgEl("text", { x: h * (cell + gap) + leftPad, y: 10 });
      t.textContent = String(h).padStart(2, "0");
      svg.appendChild(t);
    }
  }
  for (let d = 0; d < 7; d++) {
    const t = svgEl("text", { x: 0, y: d * (cell + gap) + topPad + cell - 2 });
    t.textContent = dayLabels[d];
    svg.appendChild(t);
    for (let h = 0; h < 24; h++) {
      const v = grid[d][h];
      const rect = svgEl("rect", {
        class: "heat-cell",
        x: h * (cell + gap) + leftPad, y: d * (cell + gap) + topPad,
        width: cell, height: cell, rx: 3,
        fill: colors[level(v)],
      });
      rect.addEventListener("mousemove", (e) => showTooltip(e, fmtHM(v), dayLabels[d] + " " + String(h).padStart(2, "0") + ":00"));
      rect.addEventListener("mouseleave", hideTooltip);
      svg.appendChild(rect);
    }
  }

  container.innerHTML = "";
  container.appendChild(svg);
}

function barChart(containerId, items, opts) {
  const container = document.getElementById(containerId);
  const width = Math.max(container.clientWidth || 600, 300);
  const height = opts.height || 160;
  const padBottom = 22, padTop = 10;
  const n = items.length;
  const gap = opts.gap ?? 6;
  const barW = (width - gap * (n - 1)) / n;
  const max = opts.fixedMax || Math.max(1, ...items.map(opts.value));
  const labelSkip = Math.max(1, Math.ceil(n / 15));

  const svg = svgEl("svg", { width, height, viewBox: "0 0 " + width + " " + height });
  svg.appendChild(svgEl("line", { class: "axis-line", x1: 0, x2: width, y1: height - padBottom, y2: height - padBottom }));

  items.forEach((item, i) => {
    const v = opts.value(item);
    const h = Math.max(1, (v / max) * (height - padTop - padBottom));
    const x = i * (barW + gap);
    const rect = svgEl("rect", {
      class: "bar",
      x, y: height - padBottom - h, width: barW, height: h,
      rx: Math.min(4, barW / 3),
      fill: opts.color ? opts.color(item) : "var(--accent)",
      style: "transform-box: fill-box; transform-origin: bottom; transform: scaleY(0);",
    });
    requestAnimationFrame(() => {
      rect.style.transitionDelay = (i * 22) + "ms";
      rect.style.transform = "scaleY(1)";
    });
    rect.addEventListener("mousemove", (e) => showTooltip(e, opts.tooltipTitle(item), opts.tooltipSub ? opts.tooltipSub(item) : null));
    rect.addEventListener("mouseleave", hideTooltip);
    svg.appendChild(rect);

    if (opts.label && i % labelSkip === 0) {
      const t = svgEl("text", { x: x + barW / 2, y: height - 6, "text-anchor": "middle" });
      t.textContent = opts.label(item);
      svg.appendChild(t);
    }
  });

  container.innerHTML = "";
  container.appendChild(svg);
}

function renderHist() {
  barChart("hist", DATA.histogram, {
    value: b => b.count,
    label: b => b.label,
    color: () => "var(--accent2)",
    tooltipTitle: b => b.count + (b.count === 1 ? " session" : " sessions"),
    tooltipSub: b => b.label,
  });
}

function renderReasons() {
  const container = document.getElementById("reasons");
  const items = DATA.stop_reasons;
  const max = Math.max(1, ...items.map(r => r.seconds));
  const colors = { "Manual stop": "var(--good)", "Screen locked": "var(--accent)", "System slept": "var(--accent2)", "App quit": "var(--below)", "Crash recovery": "var(--low)" };
  container.innerHTML = items.map(r =>
    '<div class="rbar-row">' +
      '<div class="rbar-label">' + r.reason + '</div>' +
      '<div class="rbar-track"><div class="rbar-fill" style="background:' + (colors[r.reason] || "var(--accent)") + '" data-w="' + ((r.seconds / max) * 100) + '"></div></div>' +
      '<div class="rbar-val num">' + fmtHM(r.seconds) + " · " + r.count + '</div>' +
    '</div>'
  ).join("");
  requestAnimationFrame(() => {
    container.querySelectorAll(".rbar-fill").forEach(el => { el.style.width = el.dataset.w + "%"; });
  });
}

function renderAll() {
  renderHeader();
  renderHero();
  renderStats();
  renderRecords();
  renderCalendar();
  renderWeekly();
  renderAdherence();
  renderMonthly();
  renderTrend();
  renderDeepWork();
  renderRecentBadges();
  renderPunch();
  renderHist();
  renderReasons();
}

renderAll();
window.addEventListener("resize", renderAll);
</script>
</body>
</html>
"""#
}
