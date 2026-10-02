import Foundation
import VaultClassifierCore
import VaultActivityCore

/// Activity's desktop-independent bridge to the shared store. The Windows host
/// supplies focused native app intervals and local app icons; browser records
/// pass the same category/privacy validation as Mac Vault.
@MainActor
final class VaultClassifierWorkerActivity {
    private let store: ActivityStore
    private unowned let model: VaultClassifierViewModel
    private let emit: ([String: Any]) -> Void
    private var ranges = ["usage": "today", "content": "today"]
    private var appIcons: [String: String] = [:]
    private var factsAsked: [String: Date] = [:]
    private var loaded = false
    private let accumulator = ActivityUsageAccumulator(maxStepSeconds: 60)
    private var nativeMonotonic = 0.0
    private static let historyDays = 365

    init(directory: URL, model: VaultClassifierViewModel, emit: @escaping ([String: Any]) -> Void) {
        self.store = ActivityStore(directory: directory)
        self.model = model
        self.emit = emit
    }

    func refresh() {
        guard loaded, let value = try? snapshot() else { return }
        emit(["event": "activity", "value": value])
    }

    func handle(_ body: [String: Any]) throws -> [String: Any] {
        let kind = body["kind"] as? String ?? "ready"
        if appIcons.count > 500 { appIcons = Dictionary(uniqueKeysWithValues: appIcons.sorted { $0.key < $1.key }.prefix(500).map { ($0.key, $0.value) }) }
        switch kind {
        case "ready", "snapshot":
            loaded = true
        case "range":
            if let section = body["section"] as? String, ranges[section] != nil,
               let range = body["range"] as? String, range.count <= 128 { ranges[section] = range }
        case "collection-record":
            if let platform = body["platformID"] as? String, let enabled = body["record"] as? Bool {
                model.setCollectionEnabled(platformID: platform, enabled: enabled)
                model.onWebStateChange?()
            }
        case "collection-keep":
            if let days = body["days"] as? Int, days >= -1 {
                model.setCollectionKeep(platformID: body["platformID"] as? String, days: days)
                model.onWebStateChange?()
            }
        case "collection-clear":
            if let platform = body["platformID"] as? String { model.clearCollectedData(platformID: platform); model.onWebStateChange?() }
        case "setSettings":
            applySettings(body)
        case "settings":
            if let update = body["settings"] as? [String: Any] {
                store.updateSettings { $0 = ActivityWire.merged($0, with: update) }
            }
            return ["kind": "settings", "settings": ActivityWire.settingsPayload(store.loadSettings())]
        case "browser-record":
            let payload = body["body"] as? [String: Any] ?? body
            let settings = store.loadSettings()
            let records = ActivityWire.records(from: payload)
            var accepted = 0
            for record in records where store.record(record, settings: settings) { accepted += 1 }
            if let icons = payload["webIcons"] as? [String: String] { store.mergeWebIcons(icons) }
            recordWatchedFacts(keys: records.filter { $0.category == .contentWatched }.map(\.key))
            refresh()
            return ["kind": "recorded", "accepted": accepted]
        case "native-sample":
            guard let elapsed = (body["elapsedMs"] as? NSNumber)?.doubleValue, elapsed.isFinite, elapsed >= 0,
                  let milliseconds = (body["atMs"] as? NSNumber)?.doubleValue, milliseconds.isFinite else { throw ActivityWorkerError.invalidOperation }
            nativeMonotonic = (body["monotonicMs"] as? NSNumber).map { $0.doubleValue / 1_000 } ?? (nativeMonotonic + elapsed / 1_000)
            let settings = store.loadSettings()
            guard settings.isEnabled(.appUsage) else {
                if let record = accumulator.flush() { _ = store.record(record, settings: settings) }
                return ["kind": "recorded", "accepted": 0]
            }
            let sample = ActivitySample(monotonic: nativeMonotonic, wall: Date(timeIntervalSince1970: milliseconds / 1_000),
                appKey: body["appId"] as? String, appLabel: body["name"] as? String ?? "Unknown", active: body["active"] as? Bool ?? true)
            var accepted = 0
            if let record = accumulator.sample(sample), store.record(record, settings: settings) { accepted = 1 }
            if let key = body["appId"] as? String, let icon = body["icon"] as? String, icon.hasPrefix("data:image/"), icon.utf8.count <= 24_000 { appIcons[key] = icon }
            if accepted > 0 { refresh() }
            return ["kind": "recorded", "accepted": accepted]
        case "native-flush":
            var accepted = 0
            if let record = accumulator.flush(), store.record(record) { accepted = 1 }
            refresh()
            return ["kind": "recorded", "accepted": accepted]
        case "native-record":
            let settings = store.loadSettings()
            let records = body["records"] as? [[String: Any]] ?? []
            var accepted = 0
            for item in records.prefix(500) {
                guard let key = item["key"] as? String, !key.isEmpty, key.count <= 32_768,
                      let label = item["label"] as? String, label.count <= 1_024,
                      let seconds = (item["seconds"] as? NSNumber)?.doubleValue, seconds.isFinite, seconds > 0,
                      let milliseconds = (item["startedAtMs"] as? NSNumber)?.doubleValue, milliseconds.isFinite,
                      let id = item["id"] as? String, !id.isEmpty, id.count <= 256 else { continue }
                if store.record(.init(id: id, category: .appUsage, startedAt: Date(timeIntervalSince1970: milliseconds / 1_000), seconds: seconds, key: key, label: label), settings: settings) { accepted += 1 }
            }
            if let icons = body["icons"] as? [String: String] {
                for (key, icon) in icons where icon.hasPrefix("data:image/") && icon.utf8.count <= 24_000 { appIcons[key] = icon }
                if appIcons.count > 500 { appIcons = Dictionary(uniqueKeysWithValues: appIcons.sorted { $0.key < $1.key }.prefix(500).map { ($0.key, $0.value) }) }
            }
            refresh()
            return ["kind": "recorded", "accepted": accepted]
        case "delete":
            if body["scope"] as? String == "all" { store.deleteAllRecords() }
            else if body["scope"] as? String == "category", let raw = body["category"] as? String, let category = ActivityCategory(rawValue: raw) { store.delete(category: category) }
        case "history":
            return try history(body)
        case "group-save":
            let raw = body["group"] as? [String: Any] ?? [:]
            let group = ActivityGroup(id: raw["id"] as? String ?? "", name: raw["name"] as? String ?? "", merge: raw["merge"] as? Bool ?? false, members: raw["members"] as? [String] ?? [])
            var answer: [String: Any] = ["request": body["request"] as? String ?? ""]
            switch store.saveGroup(group, move: body["move"] as? Bool ?? false) {
            case .success(let id): answer["ok"] = true; answer["id"] = id
            case .failure(let refusal):
                answer["ok"] = false; answer["message"] = refusal.message
                if case .inAnotherMergeGroup(let owners) = refusal { answer["conflicts"] = owners }
            }
            return ["kind": "group-save", "answer": answer, "snapshot": try snapshot()]
        case "group-delete":
            if let id = body["id"] as? String { _ = store.deleteGroup(id: id) }
        case "known-items":
            let items = store.knownItems(days: Self.historyDays)
            var icons = store.webIcons()
            for item in items where item.id.hasPrefix("app|") { if let icon = appIcons[String(item.id.dropFirst(4))] { icons[String(item.id.dropFirst(4))] = icon } }
            return ["kind": "known-items", "items": try encode(items), "icons": icons]
        case "prune":
            store.prune()
        default:
            throw ActivityWorkerError.invalidOperation
        }
        return try snapshot()
    }

    private func applySettings(_ body: [String: Any]) {
        guard let raw = body["category"] as? String, let category = ActivityCategory(rawValue: raw) else {
            if let days = body["retentionDays"] as? Int {
                store.updateSettings { $0.retentionDays = max(0, days) }
                model.setCollectionKeep(platformID: nil, days: max(0, days))
            }
            return
        }
        store.updateSettings {
            var value = $0.settings(for: category)
            if let enabled = body["enabled"] as? Bool { value.enabled = enabled }
            if let retention = body["retentionDays"] as? Int { value.retentionDays = retention < 0 ? nil : retention }
            $0.set(value, for: category)
        }
    }

    private func snapshot() throws -> [String: Any] {
        let usageRange = ranges["usage"] ?? "today", contentRange = ranges["content"] ?? "today"
        let (start, end) = Self.dates(for: usageRange)
        let snapshot = store.dashboardSnapshot(from: start, to: end)
        let content: ActivityDashboardSnapshot
        if contentRange == usageRange { content = snapshot }
        else { let dates = Self.dates(for: contentRange); content = store.dashboardSnapshot(from: dates.0, to: dates.1) }
        var icons = store.webIcons()
        for bar in snapshot.app.bars { if let icon = appIcons[bar.key] { icons[bar.key] = icon } }
        for group in snapshot.groups {
            for id in group.members where id.hasPrefix("app|") {
                let key = String(id.dropFirst(4)); if let icon = appIcons[key] { icons[key] = icon }
            }
        }
        let watchedKeys = content.watched.map(\.key)
        let missing = watchedKeys.filter { key in
            let saved = store.watchedFacts(for: [key])[key]
            return (saved?.author?.icon == nil || saved?.tags == nil) && Date().timeIntervalSince(factsAsked[key] ?? .distantPast) > 600
        }
        if !missing.isEmpty { missing.forEach { factsAsked[$0] = Date() }; recordWatchedFacts(keys: missing) }
        let saved = store.watchedFacts(for: watchedKeys)
        var facts: [String: Any] = [:]
        for key in watchedKeys {
            guard let fact = saved[key] else { continue }
            var value: [String: Any] = ["tags": (fact.tags ?? []).map { ["id": $0.id, "name": $0.name, "color": $0.color] }]
            if let author = fact.author { value["creator"] = author.name; if let icon = author.icon { value["creatorIcon"] = icon } }
            facts[key] = value
        }
        let days = store.loadSettings().retentionDays
        if model.localState?.workspaceCatalog.collectionKeepDays != days { model.setCollectionKeep(platformID: nil, days: days) }
        return ["kind": "snapshot", "snapshot": try encode(snapshot), "icons": icons, "facts": facts,
                "collection": collectionState(), "tags": tagTree(), "contentSnapshot": contentRange == usageRange ? NSNull() : try encode(content)]
    }

    private func recordWatchedFacts(keys: [String]) {
        let tags = model.watchedTags(keys: keys), authors = model.watchedAuthors(keys: keys)
        store.recordWatchedFacts(keys.map { key in
            let author = authors[key]
            return ActivityWatchedEntry(videoKey: key, authorID: author?["id"], authorName: author?["name"], authorIcon: author?["icon"],
                tags: tags[key]?.map { ActivityTag(id: $0["id"] ?? "", name: $0["name"] ?? "", color: $0["color"] ?? "") })
        })
    }

    private func collectionState() -> [String: Any] {
        guard let catalog = model.localState?.workspaceCatalog else { return [:] }
        var counts: [String: Int] = [:]
        for dataset in catalog.datasets { for entry in dataset.collectedEntries { counts[entry.platformID, default: 0] += 1 } }
        let platforms = catalog.bindings.sorted {
            let left = CollectionPlatformRegistry.definition(for: $0.id)?.supportsLocalModel == true
            let right = CollectionPlatformRegistry.definition(for: $1.id)?.supportsLocalModel == true
            return left != right ? left : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }.map { binding -> [String: Any] in
            ["id": binding.id, "name": binding.name, "classifies": CollectionPlatformRegistry.definition(for: binding.id)?.supportsLocalModel == true,
             "record": binding.collectionEnabled, "keepDays": binding.collectionKeepDays, "entries": counts[binding.id] ?? 0]
        }
        return ["keepDays": catalog.collectionKeepDays, "platforms": platforms]
    }

    private func tagTree() -> [[String: String]] {
        guard let catalog = model.localState?.workspaceCatalog else { return [] }
        var seen = Set<String>(), nodes: [[String: String]] = []
        for type in catalog.classifierTypes where !type.applicablePlatformIDs.isEmpty {
            guard let tree = catalog.trees.first(where: { $0.id == type.treeID }) else { continue }
            for node in tree.nodes where !node.isRetired && seen.insert(node.id).inserted {
                nodes.append(["id": node.id, "name": node.name, "color": TagColorAssignment.normalizedHex(node.lightColorHex ?? "") ?? "", "parentID": node.parentID ?? ""])
            }
        }
        return nodes
    }

    private func history(_ body: [String: Any]) throws -> [String: Any] {
        let pickID = body["pick"] as? String ?? "all"
        if body["section"] as? String == "content" {
            let tags = pickID.hasPrefix("tag|") ? Set(pickID.dropFirst(4).split(separator: ",").map(String.init)) : nil
            return ["kind": "history", "request": ["section": "content", "pick": pickID], "value": try encode(store.contentHistory(tagIDs: tags, days: Self.historyDays))]
        }
        let pick: ActivityStore.DetailPick
        if pickID.hasPrefix("app|") { pick = .item(.appUsage, String(pickID.dropFirst(4))) }
        else if pickID.hasPrefix("web|") { pick = .item(.webVisit, String(pickID.dropFirst(4))) }
        else if pickID.hasPrefix("group|") { pick = .group(String(pickID.dropFirst(6))) }
        else { pick = .all }
        let days = min(Self.historyDays, max(1, body["barDays"] as? Int ?? 1))
        return ["kind": "history", "request": ["section": "usage", "pick": pickID, "barDays": days] as [String: Any], "value": try encode(store.detail(pick: pick, mapDays: Self.historyDays, barDays: days))]
    }

    private func encode<T: Encodable>(_ value: T) throws -> Any {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try JSONSerialization.jsonObject(with: encoder.encode(value))
    }

    private static func dates(for range: String) -> (Date, Date) {
        let now = Date(), calendar = Calendar.current
        switch range {
        case "7d", "30d":
            return (calendar.date(byAdding: .day, value: -((Int(range.dropLast()) ?? 1) - 1), to: calendar.startOfDay(for: now)) ?? now, now)
        default:
            if range.hasPrefix("since:"), let milliseconds = Double(range.dropFirst(6)), milliseconds.isFinite, milliseconds > 0 {
                return (min(calendar.startOfDay(for: Date(timeIntervalSince1970: milliseconds / 1_000)), calendar.startOfDay(for: now)), now)
            }
            return (calendar.startOfDay(for: now), now)
        }
    }
}

private enum ActivityWorkerError: String, Error, LocalizedError {
    case invalidOperation = "invalid-activity-operation"
    var errorDescription: String? { rawValue }
}
