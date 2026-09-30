#if os(macOS) && canImport(WebKit)
import AppKit
import WebKit
import MacBlockerCore

/// The Activity scene (activity.js / activity.css, in the editor's one web
/// view and document) bridged to the ActivityStore: it pushes render-ready
/// snapshots and applies the scene's range / settings / delete messages.
/// The classifier's per-platform recording, reached from Activity → Recording
/// (Mac Vault's classifier is a component this module can't see; injected).
public struct ActivityCollectionBridge {
    public var state: () -> [String: Any]
    public var setRecord: (String, Bool) -> Void
    /// A platform's Keep (-1 = same as all), or with nil the Keep for all.
    public var setKeep: (String?, Int) -> Void
    public var clear: (String) -> Void
    /// The classifier's tags with their parents (Content's focus).
    public var tagTree: () -> [[String: String]]

    public init(
        state: @escaping () -> [String: Any],
        setRecord: @escaping (String, Bool) -> Void,
        setKeep: @escaping (String?, Int) -> Void,
        clear: @escaping (String) -> Void,
        tagTree: @escaping () -> [[String: String]]
    ) {
        self.state = state
        self.setRecord = setRecord
        self.setKeep = setKeep
        self.clear = clear
        self.tagTree = tagTree
    }
}

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

    /// Saves watched videos' authors and tags from Mac Vault's classifier
    /// (injected; this module can't see it).
    private var recordWatchedFacts: ([String]) -> Void = { _ in }
    private var collection: ActivityCollectionBridge?

    /// Called once at launch with the shared store (see BlockerAppDelegate).
    public func configure(store: ActivityStore, recordWatchedFacts: @escaping ([String]) -> Void, collection: ActivityCollectionBridge) {
        self.store = store
        self.recordWatchedFacts = recordWatchedFacts
        self.collection = collection
    }

    /// What each platform records for the classifier, for Recording (owner
    /// 2026-09-30: it lives with the rest of what Vault records). Its Keep for
    /// all platforms is the one "Keep all history".
    private func collectionState(allKeepDays: Int) -> [String: Any] {
        guard let collection else { return [:] }
        var state = collection.state()
        if let keep = state["keepDays"] as? Int, keep != allKeepDays {
            collection.setKeep(nil, allKeepDays)
            state = collection.state()
        }
        return state
    }

    /// When each watched key was last looked up in the classifier.
    private var factsAsked: [String: Date] = [:]

    /// Watched key → { creator, creatorIcon, tags } for the page, from what is
    /// saved; videos still missing an author icon or tags are looked up first.
    private func watchedFacts(keys: [String], store: ActivityStore) -> [String: Any] {
        var saved = store.watchedFacts(for: keys)
        // Tags and icons can arrive later; ask the classifier again for a key
        // at most every ten minutes (every push re-asking cost ~140 ms).
        let now = Date()
        let missing = keys.filter {
            (saved[$0]?.author?.icon == nil || saved[$0]?.tags == nil)
                && now.timeIntervalSince(factsAsked[$0] ?? .distantPast) > 600
        }
        if !missing.isEmpty {
            missing.forEach { factsAsked[$0] = now }
            recordWatchedFacts(missing)
            saved = store.watchedFacts(for: keys)
        }
        var facts: [String: Any] = [:]
        for key in keys {
            guard let fact = saved[key] else { continue }
            var entry: [String: Any] = ["tags": (fact.tags ?? []).map { ["id": $0.id, "name": $0.name, "color": $0.color] }]
            if let author = fact.author {
                entry["creator"] = author.name
                if let icon = author.icon { entry["creatorIcon"] = icon }
            }
            facts[key] = entry
        }
        return facts
    }

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
        case "collection-record":
            if let platformID = body["platformID"] as? String, let record = body["record"] as? Bool {
                collection?.setRecord(platformID, record)
            }
            pushSnapshot()
        case "collection-keep":
            if let platformID = body["platformID"] as? String, let days = body["days"] as? Int, days >= -1 {
                collection?.setKeep(platformID, days)
            }
            pushSnapshot()
        case "collection-clear":
            if let platformID = body["platformID"] as? String { collection?.clear(platformID) }
            pushSnapshot()
        case "setSettings":
            applySettings(body)
            pushSnapshot()
        case "delete":
            applyDelete(body)
            pushSnapshot()
        case "history":
            pushHistory(body)
        case "group-save":
            saveGroup(body)
        case "group-delete":
            if let id = body["id"] as? String { store?.deleteGroup(id: id) }
            pushSnapshot()
        case "known-items":
            pushKnownItems()
        default:
            break
        }
    }

    // MARK: - Store bridge

    /// A kind's Record / Keep (`retentionDays` -1 = follow the global Keep),
    /// or, without a category, the global Keep.
    private func applySettings(_ body: [String: Any]) {
        guard let store else { return }
        guard let categoryRaw = body["category"] as? String,
              let category = ActivityCategory(rawValue: categoryRaw) else {
            if let retention = body["retentionDays"] as? Int {
                store.updateSettings { $0.retentionDays = max(0, retention) }
                collection?.setKeep(nil, max(0, retention))
            }
            return
        }
        store.updateSettings { settings in
            var value = settings.settings(for: category)
            if let enabled = body["enabled"] as? Bool { value.enabled = enabled }
            if let retention = body["retentionDays"] as? Int { value.retentionDays = retention < 0 ? nil : retention }
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
        let facts = watchedFacts(keys: snapshot.watched.map(\.key), store: store)
        let platforms = collectionState(allKeepDays: store.loadSettings().retentionDays)
        let tags = collection?.tagTree() ?? []
        guard let iconsData = try? JSONSerialization.data(withJSONObject: icons),
              let iconsJSON = String(data: iconsData, encoding: .utf8),
              let factsData = try? JSONSerialization.data(withJSONObject: facts),
              let factsJSON = String(data: factsData, encoding: .utf8),
              let platformsData = try? JSONSerialization.data(withJSONObject: platforms),
              let platformsJSON = String(data: platformsData, encoding: .utf8),
              let tagsJSON = Self.json(tags) else { return }
        webView.evaluateJavaScript("window.activityApply(\(json), \(iconsJSON), \(factsJSON), \(platformsJSON), \(tagsJSON));", completionHandler: nil)
    }

    /// The Details panel's data for the pick ("all", "app|<bundle id>",
    /// "web|<domain>" or "group|<id>") and the last `barDays` days. Echoes the
    /// request so the page ignores a stale answer.
    private func pushHistory(_ body: [String: Any]) {
        guard loaded, let store, let webView else { return }
        let pickID = (body["pick"] as? String) ?? "all"
        // Content: its year map, all of it or by tag ("tag|<id>,<id>…").
        if (body["section"] as? String) == "content" {
            let tagIDs = pickID.hasPrefix("tag|") ? Set(pickID.dropFirst(4).split(separator: ",").map(String.init)) : nil
            let map = store.contentHistory(tagIDs: tagIDs, days: Self.historyDays)
            guard let data = try? JSONEncoder().encode(map), let json = String(data: data, encoding: .utf8),
                  let requestJSON = Self.json(["section": "content", "pick": pickID]) else { return }
            webView.evaluateJavaScript("window.activityHistory && window.activityHistory(\(requestJSON), \(json));", completionHandler: nil)
            return
        }
        // Usage: the year map and every day of the range (up to the year).
        let barDays = max(1, min((body["barDays"] as? Int) ?? 1, Self.historyDays))
        let detail = store.detail(pick: Self.pick(pickID), mapDays: Self.historyDays, barDays: barDays)
        guard let data = try? JSONEncoder().encode(detail),
              let json = String(data: data, encoding: .utf8),
              let requestJSON = Self.json(["section": "usage", "pick": pickID, "barDays": barDays]) else { return }
        webView.evaluateJavaScript("window.activityHistory && window.activityHistory(\(requestJSON), \(json));", completionHandler: nil)
    }

    private static func pick(_ id: String) -> ActivityStore.DetailPick {
        if id.hasPrefix("app|") { return .item(.appUsage, String(id.dropFirst(4))) }
        if id.hasPrefix("web|") { return .item(.webVisit, String(id.dropFirst(4))) }
        if id.hasPrefix("group|") { return .group(String(id.dropFirst(6))) }
        return .all
    }

    private static func json(_ object: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Saves a group from the editor (or the Usage row's Add to group) and
    /// answers with the result: saved (its id), or refused (a merge group's
    /// member already in another merge group — the page offers to move it).
    private func saveGroup(_ body: [String: Any]) {
        guard let store, let webView, let raw = body["group"] as? [String: Any] else { return }
        let group = ActivityGroup(
            id: (raw["id"] as? String) ?? "",
            name: (raw["name"] as? String) ?? "",
            merge: (raw["merge"] as? Bool) ?? false,
            members: (raw["members"] as? [String]) ?? []
        )
        var answer: [String: Any] = ["request": (body["request"] as? String) ?? ""]
        switch store.saveGroup(group, move: (body["move"] as? Bool) ?? false) {
        case .success(let id):
            answer["ok"] = true
            answer["id"] = id
        case .failure(let refusal):
            answer["ok"] = false
            answer["message"] = refusal.message
            if case .inAnotherMergeGroup(let owners) = refusal { answer["conflicts"] = owners }
        }
        if let json = Self.json(answer) {
            webView.evaluateJavaScript("window.activityGroupSaved && window.activityGroupSaved(\(json));", completionHandler: nil)
        }
        pushSnapshot()
    }

    /// The apps and websites a group can hold (seen in the day map's span),
    /// with their icons (the editor shows them).
    private func pushKnownItems() {
        guard loaded, let store, let webView else { return }
        let items = store.knownItems(days: Self.historyDays)
        let web = store.webIcons()
        var icons: [String: String] = [:]
        for item in items { if let uri = iconDataURI(id: item.id, web: web) { icons[String(item.id.dropFirst(4))] = uri } }
        guard let data = try? JSONEncoder().encode(items), let json = String(data: data, encoding: .utf8),
              let iconsData = try? JSONSerialization.data(withJSONObject: icons),
              let iconsJSON = String(data: iconsData, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.activityKnownItems && window.activityKnownItems(\(json), \(iconsJSON));", completionHandler: nil)
    }

    /// Something outside the page changed Activity (an AI tool edited a group):
    /// show it.
    public func refresh() {
        pushSnapshot()
    }

    /// The day map's span.
    static let historyDays = 365

    /// Local icons keyed by bar key (bundle id / domain): app icons resolved
    /// from the bundle id via NSWorkspace, website favicons from the store's
    /// local cache (data URIs the extension supplied). No network. Every group
    /// member gets one too (a group's icon is made of its members' icons).
    private func resolveIcons(snapshot: ActivityDashboardSnapshot, store: ActivityStore) -> [String: String] {
        let web = store.webIcons()
        var ids = snapshot.app.bars.map { "app|" + $0.key } + snapshot.web.bars.map { "web|" + $0.key }
        for group in snapshot.groups { ids += group.members }
        var icons: [String: String] = [:]
        for id in ids {
            let key = String(id.dropFirst(4))
            if icons[key] == nil, let uri = iconDataURI(id: id, web: web) { icons[key] = uri }
        }
        return icons
    }

    /// "app|<bundle id>" or "web|<domain>" → its icon, when there is one.
    private func iconDataURI(id: String, web: [String: String]) -> String? {
        let key = String(id.dropFirst(4))
        if id.hasPrefix("app|") { return appIconDataURI(bundleID: key) }
        if id.hasPrefix("web|") { return web[key] }
        return nil
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
        case "7d", "30d", "90d":
            let days = Int(range.dropLast()) ?? 1
            let start = calendar.date(byAdding: .day, value: -(days - 1), to: calendar.startOfDay(for: now)) ?? now
            return (start, now)
        default:
            // "since:<ms>" — from the start of that day (owner 2026-09-30).
            if range.hasPrefix("since:"), let ms = Double(range.dropFirst(6)), ms > 0 {
                return (min(calendar.startOfDay(for: Date(timeIntervalSince1970: ms / 1000)), calendar.startOfDay(for: now)), now)
            }
            return (calendar.startOfDay(for: now), now)
        }
    }

}
#endif
