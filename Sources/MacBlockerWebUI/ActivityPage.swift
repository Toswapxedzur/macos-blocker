#if os(macOS) && canImport(WebKit)
import AppKit
import WebKit
import MacBlockerCore

/// Hosts the Activity dashboard (activity.html) in a WKWebView and bridges it to
/// the ActivityStore: it pushes render-ready snapshots and applies the page's
/// range / settings / delete messages. macOS-only; the same asset is reused by
/// Windows' WebView2 in a later phase.
@MainActor
public final class ActivityPage: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    public static let shared = ActivityPage()

    private var store: ActivityStore?
    private weak var webView: WKWebView?
    private var range = "today"
    private var loaded = false
    /// bundle id → app-icon data URI (or "" when the app can't be resolved).
    private var appIconCache: [String: String] = [:]

    private override init() { super.init() }

    /// Called once at launch with the shared store (see BlockerAppDelegate).
    public func configure(store: ActivityStore) { self.store = store }

    public func makeView() -> NSView {
        if let webView { return webView }
        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "activity")
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        if let html = Self.pageHTML() {
            webView.loadHTMLString(html, baseURL: nil)
        }
        self.webView = webView
        return webView
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        pushSnapshot()
    }

    public func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let kind = body["kind"] as? String else { return }
        switch kind {
        case "ready", "range":
            if let range = body["range"] as? String { self.range = range }
            pushSnapshot()
        case "setSettings":
            applySettings(body)
            pushSnapshot()
        case "delete":
            applyDelete(body)
            pushSnapshot()
        case "switch-scene":
            #if os(macOS)
            if let scene = body["scene"] as? String {
                NotificationCenter.default.post(name: .vaultSwitchScene, object: nil, userInfo: ["scene": scene])
            }
            #endif
        default:
            break
        }
    }

    // MARK: - Store bridge

    private func applySettings(_ body: [String: Any]) {
        guard let store, let categoryRaw = body["category"] as? String,
              let category = ActivityCategory(rawValue: categoryRaw) else { return }
        store.updateSettings { settings in
            var value = settings.settings(for: category)
            if let enabled = body["enabled"] as? Bool { value.enabled = enabled }
            if let retention = body["retentionDays"] as? Int { value.retentionDays = max(0, retention) }
            settings.set(value, for: category)
        }
    }

    private func applyDelete(_ body: [String: Any]) {
        guard let store, let scope = body["scope"] as? String else { return }
        switch scope {
        case "all":
            store.deleteAllRecords()
        case "category":
            if let raw = body["category"] as? String, let category = ActivityCategory(rawValue: raw) {
                store.delete(category: category)
            }
        case "range":
            let (start, end) = rangeDates()
            store.delete(from: start, to: end)
        default:
            break
        }
    }

    private func pushSnapshot() {
        guard loaded, let store, let webView else { return }
        let (start, end) = rangeDates()
        let snapshot = store.dashboardSnapshot(from: start, to: end)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot), let json = String(data: data, encoding: .utf8) else { return }
        let icons = resolveIcons(snapshot: snapshot, store: store)
        guard let iconsData = try? JSONSerialization.data(withJSONObject: icons),
              let iconsJSON = String(data: iconsData, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.activityApply(\(json), \(iconsJSON));", completionHandler: nil)
    }

    /// Local icons keyed by bar key: app icons resolved from the bundle id via
    /// NSWorkspace, website favicons from the store's local cache (data URIs the
    /// extension supplied). No network.
    private func resolveIcons(snapshot: ActivityDashboardSnapshot, store: ActivityStore) -> [String: String] {
        var icons: [String: String] = [:]
        for bar in snapshot.app.bars {
            if let uri = appIconDataURI(bundleID: bar.key) { icons[bar.key] = uri }
        }
        let web = store.webIcons()
        for bar in snapshot.web.bars where web[bar.key] != nil {
            icons[bar.key] = web[bar.key]
        }
        return icons
    }

    private func appIconDataURI(bundleID: String) -> String? {
        if let cached = appIconCache[bundleID] { return cached.isEmpty ? nil : cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            appIconCache[bundleID] = ""
            return nil
        }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        let uri = Self.pngDataURI(image, side: 36) ?? ""
        appIconCache[bundleID] = uri
        return uri.isEmpty ? nil : uri
    }

    private static func pngDataURI(_ image: NSImage, side: CGFloat) -> String? {
        let target = NSImage(size: NSSize(width: side, height: side))
        target.lockFocus()
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .sourceOver, fraction: 1)
        target.unlockFocus()
        guard let tiff = target.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return "data:image/png;base64," + png.base64EncodedString()
    }

    private func rangeDates() -> (Date, Date) {
        let now = Date()
        let calendar = Calendar.current
        switch range {
        case "7d":
            let start = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)) ?? now
            return (start, now)
        case "30d":
            let start = calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: now)) ?? now
            return (start, now)
        default: // today
            return (calendar.startOfDay(for: now), now)
        }
    }

    private static func pageHTML() -> String? {
        guard let dir = WebAssetsLocator.assetsDirectory else { return nil }
        let url = dir.appendingPathComponent("activity.html", isDirectory: false)
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
#endif
