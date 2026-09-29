#if os(macOS) && canImport(WebKit)
import AppKit
import WebKit
import MacBlockerCore

/// The Activity scene (activity.js / activity.css, in the editor's one web
/// view and document) bridged to the ActivityStore: it pushes render-ready
/// snapshots and applies the scene's range / settings / delete messages.
@MainActor
public final class ActivityPage: NSObject, WKScriptMessageHandler {
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

    /// The scene's place in the editor's web view (its files are part of the
    /// editor's own assets).
    public var scene: WebScene {
        WebScene(
            install: { [unowned self] configuration in
                configuration.userContentController.add(self, name: "activity")
            },
            attach: { [unowned self] webView in self.webView = webView },
            reloaded: { [unowned self] in self.loaded = false }
        )
    }

    /// The scene came to the front: show the newest numbers.
    public func sceneShown() {
        pushSnapshot()
    }

    public func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let kind = body["kind"] as? String else { return }
        switch kind {
        case "ready", "range":
            loaded = true
            if let range = body["range"] as? String { self.range = range }
            pushSnapshot()
        case "setSettings":
            applySettings(body)
            pushSnapshot()
        case "delete":
            applyDelete(body)
            pushSnapshot()
        case "history":
            pushHistory(body)
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

    /// The detail charts' data for the picked item: `lens` "app" or "web",
    /// `key` nil = all usage, `hourDays` how many days the hour-by-hour bars
    /// compare. Echoes the request so the page ignores a stale answer.
    private func pushHistory(_ body: [String: Any]) {
        guard loaded, let store, let webView else { return }
        let category: ActivityCategory = (body["lens"] as? String) == "web" ? .webVisit : .appUsage
        let key = body["key"] as? String
        let hourDays = max(1, min((body["hourDays"] as? Int) ?? 3, 14))
        let history = store.itemHistory(category: category, key: key, days: Self.historyDays, hourDays: hourDays)
        guard let data = try? JSONEncoder().encode(history),
              let json = String(data: data, encoding: .utf8),
              let requestData = try? JSONSerialization.data(withJSONObject: ["lens": category == .webVisit ? "web" : "app", "key": (key as Any?) ?? NSNull(), "hourDays": hourDays] as [String: Any]),
              let requestJSON = String(data: requestData, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.activityHistory && window.activityHistory(\(requestJSON), \(json));", completionHandler: nil)
    }

    /// The day map's span.
    static let historyDays = 180

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

}
#endif
