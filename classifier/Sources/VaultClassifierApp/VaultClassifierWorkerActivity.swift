import Foundation
import VaultClassifierCore
import VaultActivityCore

/// Activity's desktop-independent bridge to the shared store. The Windows host
/// supplies focused native app intervals and local app icons; browser records
/// pass the same category/privacy validation as Mac Vault.
@MainActor
final class VaultClassifierWorkerActivity {
    private let store: ActivityStore
    private let model: VaultClassifierViewModel
    private let emit: ([String: Any]) -> Void
    private var ranges = ["usage": "today", "content": "today"]
    private var appIcons: [String: String] = [:]
    private var factsAsked: [String: Date] = [:]
    private var loaded = false
    private var refreshRevision: UInt64 = 0
    private let accumulator = ActivityUsageAccumulator(maxStepSeconds: 60)
    private var nativeMonotonic = 0.0
    nonisolated private static let historyDays = 365

    init(directory: URL, model: VaultClassifierViewModel, emit: @escaping ([String: Any]) -> Void) {
        self.store = ActivityStore(directory: directory)
        self.model = model
        self.emit = emit
    }

    func refresh() {
        guard loaded else { return }
        refreshRevision &+= 1
        let revision = refreshRevision
        Task { @MainActor [weak self] in
            guard let self, let value = try? await self.snapshot(), self.refreshRevision == revision else { return }
            self.emit(["event": "activity", "value": value])
        }
    }

    /// The public Activity tools share the page's store and group validation.
    /// Their result shapes match Mac Vault's ActivityMCPTools, independently of
    /// the page's broader snapshot and 365-day searchable item catalog.
    func handleMcp(_ body: [String: Any]) async throws -> Any {
        guard let tool = body["tool"] as? String,
              let raw = body["arguments"] as? [String: Any] else {
            throw ActivityMCPError.invalidArguments
        }
        switch tool {
        case "list_activity_groups":
            let store = self.store
            let data = try await Task.detached(priority: .userInitiated) {
                let groups = store.groups().map {
                    ["id": $0.id, "name": $0.name, "merge": $0.merge, "members": $0.members] as [String: Any]
                }
                let items = store.knownItems(days: 180).prefix(300).map {
                    ["id": $0.id, "label": $0.label, "seconds": Int($0.seconds)] as [String: Any]
                }
                return try JSONSerialization.data(withJSONObject: ["groups": groups, "items": items])
            }.value
            return try JSONSerialization.jsonObject(with: data)
        case "save_activity_group":
            let arguments = try ActivityMCPArguments.decode(raw)
            guard let name = arguments.name, let members = arguments.members else {
                throw ActivityMCPError.invalidArguments
            }
            let group = ActivityGroup(id: arguments.id ?? "", name: name,
                                      merge: arguments.merge ?? false, members: members)
            switch store.saveGroup(group, move: arguments.move ?? false) {
            case .success(let id):
                refresh()
                return ["id": id]
            case .failure(let refusal):
                throw ActivityMCPError.refused("Refused: \(refusal.message).")
            }
        case "delete_activity_group":
            guard let id = raw["id"] as? String else {
                throw ActivityMCPError.invalidArguments
            }
            guard store.deleteGroup(id: id) else {
                throw ActivityMCPError.refused("Refused: no such group.")
            }
            refresh()
            return "Deleted."
        default:
            throw ActivityMCPError.unknownTool
        }
    }

    func handle(_ body: [String: Any]) async throws -> [String: Any] {
        let kind = body["kind"] as? String ?? "ready"
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
            if let icons = payload["icons"] as? [String: String] { store.mergeWebIcons(icons) }
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
            for item in records {
                guard let key = item["key"] as? String, !key.isEmpty, key.count <= 32_768,
                      let label = item["label"] as? String, label.count <= 1_024,
                      let seconds = (item["seconds"] as? NSNumber)?.doubleValue, seconds.isFinite, seconds > 0,
                      let milliseconds = (item["startedAtMs"] as? NSNumber)?.doubleValue, milliseconds.isFinite,
                      let id = item["id"] as? String, !id.isEmpty, id.count <= 256 else { continue }
                if store.record(.init(id: id, category: .appUsage, startedAt: Date(timeIntervalSince1970: milliseconds / 1_000), seconds: seconds, key: key, label: label), settings: settings) { accepted += 1 }
            }
            if let icons = body["icons"] as? [String: String] {
                for (key, icon) in icons where icon.hasPrefix("data:image/") && icon.utf8.count <= 24_000 { appIcons[key] = icon }
            }
            refresh()
            return ["kind": "recorded", "accepted": accepted]
        case "delete":
            if body["scope"] as? String == "all" { store.deleteAllRecords() }
            else if body["scope"] as? String == "category", let raw = body["category"] as? String, let category = ActivityCategory(rawValue: raw) { store.delete(category: category) }
        case "history":
            return try await history(body)
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
            return ["kind": "group-save", "answer": answer, "snapshot": try await snapshot()]
        case "group-delete":
            if let id = body["id"] as? String { _ = store.deleteGroup(id: id) }
        case "known-items":
            let store = self.store
            let (items, data, web) = try await Task.detached(priority: .userInitiated) {
                let items = store.knownItems(days: Self.historyDays)
                return (items, try Self.encoded(items), store.webIcons())
            }.value
            return ["kind": "known-items", "items": try JSONSerialization.jsonObject(with: data), "icons": await icons(for: items.map(\.id), web: web)]
        case "prune":
            store.prune()
        default:
            throw ActivityWorkerError.invalidOperation
        }
        return try await snapshot()
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

    private func snapshot() async throws -> [String: Any] {
        let usageRange = ranges["usage"] ?? "today", contentRange = ranges["content"] ?? "today"
        let usageDates = Self.dates(for: usageRange), contentDates = Self.dates(for: contentRange)
        let store = self.store
        let (snapshot, content, data, contentData, web) = try await Task.detached(priority: .userInitiated) {
            let snapshot = store.dashboardSnapshot(from: usageDates.0, to: usageDates.1)
            let content = contentRange == usageRange ? snapshot : store.dashboardSnapshot(from: contentDates.0, to: contentDates.1)
            return (snapshot, content, try Self.encoded(snapshot), contentRange == usageRange ? nil : try Self.encoded(content), store.webIcons())
        }.value
        let ids = snapshot.app.bars.map { "app|" + $0.key } + snapshot.web.bars.map { "web|" + $0.key } + snapshot.groups.flatMap(\.members)
        let icons = await icons(for: ids, web: web)
        let watchedKeys = content.watched.map(\.key)
        var saved = store.watchedFacts(for: watchedKeys)
        let now = Date()
        let missing = watchedKeys.filter { key in
            return (saved[key]?.author?.icon == nil || saved[key]?.tags == nil) && now.timeIntervalSince(factsAsked[key] ?? .distantPast) > 600
        }
        if !missing.isEmpty { missing.forEach { factsAsked[$0] = now }; recordWatchedFacts(keys: missing); saved = store.watchedFacts(for: watchedKeys) }
        var facts: [String: Any] = [:]
        for key in watchedKeys {
            guard let fact = saved[key] else { continue }
            var value: [String: Any] = ["tags": (fact.tags ?? []).map { ["id": $0.id, "name": $0.name, "color": $0.color] }]
            if let author = fact.author { value["creator"] = author.name; if let icon = author.icon { value["creatorIcon"] = icon } }
            facts[key] = value
        }
        let days = store.loadSettings().retentionDays
        if model.localState?.workspaceCatalog.collectionKeepDays != days { model.setCollectionKeep(platformID: nil, days: days) }
        return ["kind": "snapshot", "snapshot": try JSONSerialization.jsonObject(with: data), "icons": icons, "facts": facts,
                "collection": collectionState(), "tags": tagTree(), "contentSnapshot": try contentData.map { try JSONSerialization.jsonObject(with: $0) } ?? NSNull()]
    }

    private func icons(for ids: [String], web: [String: String]) async -> [String: String] {
        var icons: [String: String] = [:]
        for (index, id) in Set(ids).enumerated() {
            if index % 32 == 0 { await Task.yield() }
            let key = String(id.dropFirst(4))
            if let icon = id.hasPrefix("app|") ? appIcons[key] : web[key] { icons[key] = icon }
        }
        return icons
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

    private func history(_ body: [String: Any]) async throws -> [String: Any] {
        let pickID = body["pick"] as? String ?? "all"
        let store = self.store
        if body["section"] as? String == "content" {
            let tags = pickID.hasPrefix("tag|") ? Set(pickID.dropFirst(4).split(separator: ",").map(String.init)) : nil
            let data = try await Task.detached(priority: .userInitiated) { try Self.encoded(store.contentHistory(tagIDs: tags, days: Self.historyDays)) }.value
            return ["kind": "history", "request": ["section": "content", "pick": pickID], "value": try JSONSerialization.jsonObject(with: data)]
        }
        let pick: ActivityStore.DetailPick
        if pickID.hasPrefix("app|") { pick = .item(.appUsage, String(pickID.dropFirst(4))) }
        else if pickID.hasPrefix("web|") { pick = .item(.webVisit, String(pickID.dropFirst(4))) }
        else if pickID.hasPrefix("group|") { pick = .group(String(pickID.dropFirst(6))) }
        else { pick = .all }
        let days = min(Self.historyDays, max(1, body["barDays"] as? Int ?? 1))
        let data = try await Task.detached(priority: .userInitiated) { try Self.encoded(store.detail(pick: pick, mapDays: Self.historyDays, barDays: days)) }.value
        return ["kind": "history", "request": ["section": "usage", "pick": pickID, "barDays": days] as [String: Any], "value": try JSONSerialization.jsonObject(with: data)]
    }

    nonisolated private static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
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

private struct ActivityMCPArguments: Decodable {
    var id: String?
    var name: String?
    var members: [String]?
    var merge: Bool?
    var move: Bool?

    static func decode(_ raw: [String: Any]) throws -> Self {
        guard !["id", "name", "members", "merge", "move"].contains(where: { raw[$0] is NSNull }) else {
            throw ActivityMCPError.invalidArguments
        }
        do {
            return try JSONDecoder().decode(Self.self, from: JSONSerialization.data(withJSONObject: raw))
        } catch {
            throw ActivityMCPError.invalidArguments
        }
    }
}

private enum ActivityMCPError: Error, LocalizedError {
    case invalidArguments
    case unknownTool
    case refused(String)
    var errorDescription: String? {
        switch self {
        case .invalidArguments: return "invalid-activity-mcp-arguments"
        case .unknownTool: return "unknown-tool"
        case .refused(let message): return message
        }
    }
}
