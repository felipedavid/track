# Track

A native macOS menu bar app for logging working hours. Start/stop tracking with a
click, run a focus timer that beeps when it's up, and it auto-stops if you lock your
screen or the machine sleeps — so idle time never gets logged as work. Everything is
saved forever in a local SQLite database.

Built with Swift + AppKit via Swift Package Manager — no Xcode project file, no
external dependencies. It links directly against the `libsqlite3` that ships with
macOS.

## Features

- **Start / Stop Tracking** — one click in the menu bar, logged as a session in SQLite
- **Focus Timer** — presets (25 min, 1h, 2h, 3h) or a custom duration in minutes; beeps
  three times when the target is reached but keeps tracking (and counting past target)
  until you stop it yourself
- **Auto-stop on screen lock / system sleep** — stepping away from the computer stops
  an active session automatically, tagged with why it stopped
- **Global keyboard shortcut** — `⌃⌥⌘T` (Control+Option+Command+T) toggles tracking
  from anywhere, even when another app is frontmost
- **Sound feedback** — a distinct sound plays whenever tracking starts ("Pop") or stops
  ("Bottle"), regardless of what triggered it — menu click, hotkey, or auto-stop
- **Menu bar indicator** — `○` idle, `●` tracking, `⏰` focus target reached, each
  followed by today's running total (e.g. `● 1h 23m`), refreshed every 15s
- **Productivity dashboard** — "Dashboard…" in the menu opens a live window (built with
  a `WKWebView`, no data ever leaves the Mac) with a GitHub-style calendar heatmap, a
  30h/40h/60h weekly goal tracker, a day×hour "when you work" grid, a 7-day momentum
  trend, deep-work ratio, personal records, month-over-month and trend indicators, and
  "last 2 weeks" lifestyle badges (Night Owl, Early Bird, Marathoner, ...) — computed
  fresh from `track.db` every time the window is opened
- **Launch at Login** — a menu toggle (via `SMAppService`) to open Track automatically
  on login, no need to touch System Settings
- **Crash-safe** — if the app is killed while tracking, the next launch closes the
  dangling session at zero duration instead of silently inflating your hours

## Requirements

- macOS 13 (Ventura) or later
- Xcode Command Line Tools (`xcode-select -p` should print a path) — provides `swift`
  and the macOS SDK's `sqlite3.h`

## Project structure

```
track/
  Package.swift               SPM manifest: CSQLite system library + Track executable
  build.sh                    Release build -> Track.app bundle, ad-hoc codesigned
  Sources/
    CSQLite/                  Module map exposing the system libsqlite3 to Swift
      module.modulemap
      shim.h
    Track/
      main.swift               Entry point, starts NSApplication
      AppDelegate.swift        Wires all components together at launch
      Database.swift           SQLite wrapper: schema, session CRUD, crash recovery
      TimeTracker.swift        Start/stop state machine, live elapsed-time math, sounds
      FocusTimer.swift         Countdown timer, beep on completion
      LockMonitor.swift        Screen lock / sleep notifications -> auto-stop
      GlobalHotKey.swift       System-wide keyboard shortcut (Carbon hot key API)
      ReportGenerator.swift    Computes every dashboard metric, renders the HTML/JS report
      DashboardWindowController.swift  Live WKWebView window showing the dashboard
      StatusBarController.swift Menu bar item, dropdown menu, all UI
```

## How it works

**Database.swift** opens (creating if needed) a SQLite file at
`~/Library/Application Support/Track/track.db` with a single table:

```sql
CREATE TABLE sessions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  start_time INTEGER NOT NULL,   -- unix epoch seconds
  end_time INTEGER,              -- NULL while the session is still running
  stop_reason TEXT               -- 'manual' | 'screen-lock' | 'sleep' | 'app-quit' | 'crash-recovery'
);
```

A session is "open" while `end_time IS NULL`. On every launch, `Database` checks for a
leftover open session (meaning the app didn't shut down cleanly last time) and closes
it immediately at its own start time — zero duration, tagged `crash-recovery` — so a
crash or force-quit can never silently add hours to your log.

**TimeTracker.swift** holds `isTracking` / `currentStart` and calls into `Database` on
`start()` / `stop(reason:)`. Elapsed time is always computed live from `Date()` rather
than accumulated in a counter, so it's correct no matter how often the UI redraws. Every
`start()`/`stop()` call plays a system sound (`Pop` / `Bottle`), so this is the single
place all triggers — menu click, hot key, lock/sleep auto-stop, app quit — get audible
feedback for free.

**GlobalHotKey.swift** registers `⌃⌥⌘T` system-wide using Carbon's `RegisterEventHotKey`
— the same mechanism menu bar utilities have used for global shortcuts for decades. It
doesn't require Accessibility/Input Monitoring permission (unlike an `NSEvent` global
monitor or `CGEventTap`), so there's no permission prompt to grant. `AppDelegate` defines
the toggle logic once and passes it to both the menu item and this hot key, so "stop also
cancels an active focus timer" only has to be expressed in one place. To change the
shortcut, edit the `keyCode`/`modifiers` passed to `GlobalHotKey(...)` in
`AppDelegate.swift` (key codes are the `kVK_*` constants from `Carbon.HIToolbox`).

**FocusTimer.swift** starts tracking if it isn't already running, schedules a `Timer`
for the requested duration, and on fire plays `NSSound.beep()` three times and flips a
`targetReached` flag. It does **not** stop tracking — that's a manual action, same as
any other stop.

**LockMonitor.swift** subscribes to `DistributedNotificationCenter`'s
`com.apple.screenIsLocked` and `NSWorkspace.willSleepNotification`. Either one stops an
active tracking session (`reason: "screen-lock"` or `"sleep"`) and cancels any running
focus timer, since its target stops being meaningful once you've stepped away.

**StatusBarController.swift** owns the `NSStatusItem`, builds the dropdown menu (Start/
Stop Tracking, Start Focus Timer submenu, Stop Focus Timer, today's total, Dashboard,
Launch at Login, Quit), and redraws the title on every state change plus a 15-second
timer for the live counter. The Launch at Login checkbox reflects `SMAppService.mainApp
.status` and is re-synced every time the menu opens, so it stays correct even if login
items were changed outside the app.

**ReportGenerator.swift** reads every session via `Database.allSessions()` and computes
every metric shown on the dashboard — streaks, a Sunday-aligned rolling-year calendar
heatmap, weekly/monthly totals, a day×hour "punch card" of when you work, a 7-day
rolling-average momentum trend, deep-work ratio (time in sessions ≥1h), session-length
distribution, and personal records — then renders it into a single self-contained HTML
string (inline CSS/JS, charts drawn as hand-built SVG, no external requests). It never
touches disk; `buildHTML()` produces the full page for the first load, and
`buildRefreshJSON()` produces just the data for subsequent refreshes.

**DashboardWindowController.swift** owns the dashboard's `NSWindow` and `WKWebView`. The
page loads once; a 30-second timer (and `windowDidBecomeKey`) keeps it live by pushing
fresh JSON into the already-loaded page and calling its `renderAll()` again, rather than
reloading the page outright — a reload would reset scroll position every refresh.

**AppDelegate.swift** constructs `Database` → `TimeTracker` → `FocusTimer` /
`LockMonitor` → `StatusBarController` at launch, sets `NSApp.setActivationPolicy(.accessory)`
so the app has no Dock icon, and stops any active session with reason `app-quit` on a
clean quit.

## Building

```bash
swift build              # debug build -> .build/debug/Track
swift build -c release   # release build -> .build/release/Track
./build.sh                # release build + assembles Track.app, ad-hoc codesigned
```

## Running

```bash
open Track.app            # after ./build.sh
# or, for console output while developing:
swift run
```

To have it always available, copy `Track.app` to `/Applications`, open it, and toggle
"Launch at Login" in its menu (uses `SMAppService`, macOS 13+ — no need to touch System
Settings). It runs with no Dock icon or window — the menu bar item is the entire UI. Quit
from its menu, or `pkill -x Track`.

## Querying your history

The database is plain SQLite, so anything can read it:

```bash
sqlite3 ~/Library/Application\ Support/Track/track.db "SELECT * FROM sessions ORDER BY id DESC LIMIT 20;"

# total hours logged, all time
sqlite3 ~/Library/Application\ Support/Track/track.db \
  "SELECT ROUND(SUM(end_time - start_time) / 3600.0, 2) FROM sessions WHERE end_time IS NOT NULL;"

# today's sessions with human-readable times
sqlite3 ~/Library/Application\ Support/Track/track.db \
  "SELECT datetime(start_time,'unixepoch','localtime'), datetime(end_time,'unixepoch','localtime'), stop_reason FROM sessions WHERE date(start_time,'unixepoch','localtime') = date('now','localtime');"
```

## Known limitations

- A session that runs past midnight is attributed entirely to the day it started on —
  "today's total" won't split it at the day boundary.
- `SMAppService` registration is keyed to the app's bundle path, so "Launch at Login"
  needs re-toggling if `Track.app` is moved or rebuilt in place at a different path.
- No packaging/notarization for distribution outside your own Mac — `build.sh` ad-hoc
  signs just enough for Gatekeeper to allow a local launch.
