import AppKit
import WebKit

/// Owns the "Productivity Dashboard" window: a `WKWebView` showing the report built by
/// `ReportGenerator`. Nothing is written to disk. There's no background refresh — every
/// click on "Dashboard…" in the menu re-fetches from the database, either loading the
/// page for the first time or, if it's already open, pushing fresh data into the
/// already-loaded page (`DATA = ...; renderAll();`) instead of reloading it, so bringing
/// the window forward doesn't reset your scroll position out from under you.
final class DashboardWindowController: NSObject {
    private let reportGenerator: ReportGenerator
    private var window: NSWindow?
    private var webView: WKWebView?
    private var hasLoadedContent = false

    init(database: Database) {
        self.reportGenerator = ReportGenerator(database: database)
    }

    func show() {
        if window == nil {
            let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1040, height: 800))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1040, height: 800),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Track — Dashboard"
            window.contentView = webView
            window.center()
            window.isReleasedWhenClosed = false
            self.window = window
            self.webView = webView
            loadFull()
        } else {
            refresh()
        }

        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func loadFull() {
        let (html, hasData) = reportGenerator.buildHTML()
        hasLoadedContent = hasData
        webView?.loadHTMLString(html, baseURL: nil)
    }

    /// Updates the already-loaded page in place. Falls back to a full (scroll-resetting)
    /// load only when the page currently on screen is the empty state — nothing to
    /// preserve the scroll position of there, and the empty-state HTML has no `DATA` or
    /// `renderAll` to inject into.
    private func refresh() {
        guard hasLoadedContent else {
            loadFull()
            return
        }
        guard let json = reportGenerator.buildRefreshJSON() else { return }
        webView?.evaluateJavaScript("DATA = " + json + "; renderAll();", completionHandler: nil)
    }
}
