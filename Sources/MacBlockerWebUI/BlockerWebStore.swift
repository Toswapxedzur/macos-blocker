import Foundation
import MacBlockerCore

/// Persists the editor's raw chrome.storage snapshot (the same
/// `blockedGroups` / `globalSettings` / usage keys the Chrome extension uses)
/// in the shared container the Mac engine reads. Enforcement reads it through
/// the live shared state of linked groups (`GroupStore.sharedOverlay`), so the
/// Mac follows edits and snoozes made on another device with no editor open.
public final class BlockerWebStore: @unchecked Sendable {
    private let shared: SharedAppGroupStore
    /// The native owner of `web-store.json`. The editor persists THROUGH it so the
    /// editor and MCP/native writers share one lock (no read-modify-write race).
    private let groupStore: GroupStore

    public init(shared: SharedAppGroupStore = SharedAppGroupStore()) {
        self.shared = shared
        self.groupStore = GroupStore(shared: shared)
    }

    public var fileURL: URL {
        shared.url(for: SharedAppGroupStore.webStoreFileName)
    }

    /// Creates a default `web-store.json` with an empty `blockedGroups` array
    /// if the file does not already exist. Call once at launch so the
    /// enforcement bridge always has a store to read from.
    public func seedIfNeeded() {
        guard !FileManager.default.fileExists(atPath: fileURL.path) else { return }
        save(rawStore: ["blockedGroups": [] as [[String: Any]]])
    }

    public func loadRawJSON() -> String? {
        guard let data = shared.readData(SharedAppGroupStore.webStoreFileName) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    public func save(rawStore: Any) {
        guard let raw = rawStore as? [String: Any],
              JSONSerialization.isValidJSONObject(raw)
        else {
            return
        }
        // notify is false — this is the editor persisting its own state, so it
        // must not trigger a re-seed of itself.
        groupStore.save(WebStoreDocument(raw: raw), notify: false)
    }

    /// The editor's writes: only the keys it set are merged into the file
    /// (NSNull removes one), under the lock — so a key another writer changed
    /// meanwhile (the engine, a tool) is kept, as chrome.storage does.
    public func merge(changes: [String: Any]) {
        guard !changes.isEmpty else { return }
        GroupStore.withFileLock {
            var object = loadStoreObject() ?? [:]
            for (key, value) in changes {
                if value is NSNull {
                    object.removeValue(forKey: key)
                } else if WebStoreDocument.perGroupMapKeys.contains(key), let entries = value as? [String: Any] {
                    // A per-group map (snoozes…) merges by group: the editor's copy
                    // of the other groups' entries may be older than the engine's.
                    object[key] = (object[key] as? [String: Any] ?? [:]).merging(entries) { $1 }
                } else {
                    object[key] = value
                }
            }
            write(object)
        }
    }

    // MARK: The engine tick

    /// What enforcement acts on this tick, from ONE read of the store.
    public struct EnforcementView {
        public var groups: [BlockGroup]
        public var snoozes: [String: SnoozeState]
        public var usage: UsageTimers
        /// Settings ▸ "Ask a blocked app to quit again every (minutes)": 0 = never.
        public var quitRetryMinutes: Double
    }

    /// The tick's one read of the stored document, tidied by the runtime owner
    /// (the editor writes only its groups): a snooze that ran out (or was
    /// ended) adds its time to the group's total once (`activeMsApplied`), and
    /// a deleted group leaves no per-group entry behind — as the browser's
    /// worker does. Written only when something changed, under the file lock.
    public func loadForTick(nowMs: Double, linkedGroupIds: [String] = []) -> [String: Any] {
        let object = loadStoreObject() ?? [:]
        guard Self.tidied(object, nowMs: nowMs, linkedGroupIds: linkedGroupIds) != nil else { return object }
        return GroupStore.withFileLock {
            guard let fresh = loadStoreObject(), let tidy = Self.tidied(fresh, nowMs: nowMs, linkedGroupIds: linkedGroupIds) else {
                return loadStoreObject() ?? object
            }
            write(tidy)
            // An open editor shows (and later writes) the tidied state.
            DispatchQueue.main.async { GroupStore.postDidChange() }
            return tidy
        }
    }

    /// The document with finished snoozes counted, deleted groups' entries
    /// dropped and duplicate names renamed silently (a linked group keeps its
    /// name — group-actions.js dedupeNames), or nil when none applies.
    public static func tidied(_ document: [String: Any], nowMs: Double, linkedGroupIds: [String] = []) -> [String: Any]? {
        let counted = countFinishedSnoozes(in: document, nowMs: nowMs)
        var next = counted ?? document
        var changed = counted != nil
        var groups = next["blockedGroups"] as? [[String: Any]] ?? []
        // A lock stored before 2026-09-26 (freezeMode) becomes the editor's lock
        // unit once — the same conversion as group-actions.js normalizeLock — so
        // every rule reads one lock.
        if groups.contains(where: { !$0.keys.contains("lockedAtMs") }) {
            groups = groups.map { group in
                guard !group.keys.contains("lockedAtMs"),
                      let unit = GroupActionsRuntime.shared.call("normalizeLock", [group]) as? [String: Any] else { return group }
                var converted = group.merging(unit) { _, new in new }
                if converted["lockedAtMs"] == nil { converted["lockedAtMs"] = NSNull() }
                for legacy in ["freezeMode", "freezeModeChoice", "strictFreezeHours", "frozenAtMs", "freezeChangedAtMs"] { converted.removeValue(forKey: legacy) }
                return converted
            }
            next["blockedGroups"] = groups
            changed = true
        }
        // The scope line (owner 2026-09-27): Mac Vault's own group names only
        // apps; website and platform lines come only from a link (a browser's),
        // so a group outside a link drops any it still carries.
        let linked = Set(linkedGroupIds)
        if groups.contains(where: { group in
            guard let id = group["id"] as? String, !linked.contains(id) else { return false }
            return (group["scopes"] as? [[String: Any]] ?? []).contains { ($0["surface"] as? String) != "apps" }
        }) {
            groups = groups.map { group in
                guard let id = group["id"] as? String, !linked.contains(id), let scopes = group["scopes"] as? [[String: Any]] else { return group }
                var own = group
                own["scopes"] = scopes.filter { ($0["surface"] as? String) == "apps" }
                return own
            }
            next["blockedGroups"] = groups
            changed = true
        }
        let nameKeys = groups.compactMap { ($0["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty }
        if Set(nameKeys).count < nameKeys.count,
           let renamed = GroupActionsRuntime.shared.call("dedupeNames", [groups, linkedGroupIds]) as? [[String: Any]] {
            next["blockedGroups"] = renamed
            changed = true
        }
        let ids = Set((next["blockedGroups"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String })
        for key in WebStoreDocument.perGroupMapKeys {
            guard let map = next[key] as? [String: Any], map.keys.contains(where: { !ids.contains($0) }) else { continue }
            next[key] = map.filter { ids.contains($0.key) }
            changed = true
        }
        if let quickAdd = next["quickAddGroupId"] as? String, !quickAdd.isEmpty, !ids.contains(quickAdd) {
            next["quickAddGroupId"] = ""
            changed = true
        }
        return changed ? next : nil
    }

    /// The document with finished snoozes counted, or nil when none finished.
    /// As the browser's worker does (group-actions.js): a budget snooze whose
    /// extra room is used up ends now, and a finished time snooze adds its clock
    /// time to the total once (a budget snooze is counted as it is used).
    private static func countFinishedSnoozes(in document: [String: Any], nowMs: Double) -> [String: Any]? {
        guard var snoozes = document["groupSnoozes"] as? [String: Any] else { return nil }
        var totals = document["groupSnoozeTotalsMs"] as? [String: Any] ?? [:]
        let groups = Dictionary((document["blockedGroups"] as? [[String: Any]] ?? []).compactMap { group in
            (group["id"] as? String).map { ($0, group) }
        }, uniquingKeysWith: { first, _ in first })
        let timers = document["usageTimersMs"] as? [String: Any] ?? [:]
        var changed = false
        for (groupID, value) in snoozes {
            guard var entry = value as? [String: Any] else { continue }
            let group: Any = groups[groupID] ?? NSNull()
            let used = (timers[groupID] as? NSNumber)?.doubleValue ?? 0
            if (entry["kind"] as? String) == "budget",
               let settled = GroupActionsRuntime.shared.call("settleBudgetSnooze", [entry, group, used, nowMs]) as? [String: Any] {
                entry = settled
                snoozes[groupID] = entry
                changed = true
            }
            guard entry["activeMsApplied"] as? Bool != true,
                  let until = (entry["untilMs"] as? NSNumber)?.doubleValue, nowMs >= until else { continue }
            let counted = (GroupActionsRuntime.shared.call("snoozeCountedMs", [entry]) as? NSNumber)?.doubleValue ?? 0
            totals[groupID] = ((totals[groupID] as? NSNumber)?.doubleValue ?? 0) + max(0, counted)
            entry["activeMsApplied"] = true
            snoozes[groupID] = entry
            changed = true
        }
        guard changed else { return nil }
        var counted = document
        counted["groupSnoozes"] = snoozes
        counted["groupSnoozeTotalsMs"] = totals
        return counted
    }

    /// Mac Vault owns adoption, as the browser's worker does: a linked group's
    /// shared definition, lock, snooze and snooze total are written into this
    /// Mac's own file, so the editor shows — and edits — the shared group, open
    /// or opened later. Returns whether it wrote (an open editor is told).
    @discardableResult
    public func adoptShared() -> Bool {
        guard let overlay = GroupStore.sharedOverlay else { return false }
        let keys = ["blockedGroups", "groupSnoozes", "groupSnoozeTotalsMs"]
        let wrote: Bool = GroupStore.withFileLock {
            guard let object = loadStoreObject() else { return false }
            let adopted = overlay(object)
            guard keys.contains(where: { WebStoreDocument.canonicalJSON(adopted[$0]) != WebStoreDocument.canonicalJSON(object[$0]) }) else { return false }
            var next = object
            for key in keys where adopted[key] != nil { next[key] = adopted[key] }
            write(next)
            return true
        }
        if wrote { GroupStore.postDidChange() }
        return wrote
    }

    /// A Mac group that left a link (Unlink, or its link dissolved) keeps the
    /// shared settings and only its own program's lines: the Apps lines
    /// (owner 2026-09-27). An open editor is told.
    public func keepOwnLines(groupIds: Set<String>) {
        guard !groupIds.isEmpty else { return }
        let wrote: Bool = GroupStore.withFileLock {
            guard var object = loadStoreObject(), var groups = object["blockedGroups"] as? [[String: Any]] else { return false }
            var changed = false
            for index in groups.indices {
                guard let id = groups[index]["id"] as? String, groupIds.contains(id),
                      let scopes = groups[index]["scopes"] as? [[String: Any]] else { continue }
                let own = scopes.filter { ($0["surface"] as? String) == "apps" }
                if own.count != scopes.count { groups[index]["scopes"] = own; changed = true }
            }
            guard changed else { return false }
            object["blockedGroups"] = groups
            write(object)
            return true
        }
        if wrote { GroupStore.postDidChange() }
    }

    /// Groups and snoozes as linked devices share them; usage and settings as
    /// stored (the engine folds shared usage in itself).
    public static func enforcementView(of document: [String: Any]) -> EnforcementView {
        let overlaid = GroupStore.sharedOverlay?(document) ?? document
        let settings = document["globalSettings"] as? [String: Any]
        return EnforcementView(
            groups: (try? ChromeExtensionImporter.importGroups(fromObject: overlaid))?.groups ?? [],
            snoozes: snoozes(overlaid["groupSnoozes"]),
            usage: usageTimers(document),
            quitRetryMinutes: max(0, (settings?["quitRetryMinutes"] as? NSNumber)?.doubleValue ?? 0)
        )
    }

    /// Bridges the stored `blockedGroups`, as linked devices share them, into
    /// the typed core model (for events fired outside the tick).
    public func importedGroups() -> [BlockGroup] {
        groupStore.loadGroups()
    }

    // MARK: Usage timers (the editor's own per-group spent-time, in ms)
    //
    // These mirror the Chrome extension's `usageTimersMs` / `usageResetAtMs`
    // chrome.storage keys. On macOS the native enforcement bridge is the
    // heartbeat that advances them (while a blocked app is frontmost), and the
    // web view pushes them back into the live popup so the countdown ticks.

    public struct UsageTimers: Sendable {
        public var timersMs: [String: Double]
        public var resetAtMs: [String: Double]
        /// Rolling-limit usage per group: minute-start ms -> ms used in that minute.
        public var bucketsMs: [String: [Double: Double]] = [:]
    }

    public func loadUsageTimers() -> UsageTimers {
        Self.usageTimers(loadStoreObject() ?? [:])
    }

    private static func usageTimers(_ document: [String: Any]) -> UsageTimers {
        UsageTimers(
            timersMs: numbers(document["usageTimersMs"]),
            resetAtMs: numbers(document["usageResetAtMs"]),
            bucketsMs: (document["usageBucketsMs"] as? [String: Any] ?? [:])
                .compactMapValues { UsageBudget.parseBuckets($0)?.filter { $0.value > 0 } }
        )
    }

    /// Overwrites the given per-group `usageTimersMs` / `usageResetAtMs` entries
    /// (merging into whatever is stored, preserving untouched groups and every
    /// other key). Used by the enforcement bridge to accrue time and to apply
    /// reset-interval rollovers, keeping the popup and native enforcement on one
    /// source of truth. A no-op write when both maps are empty.
    /// An imported group starts fresh (owner 2026-09-27): its usage, snooze
    /// and snooze total go; a new budget period starts now. Mac Vault owns the
    /// runtime maps, so the editor asks for this rather than writing them.
    public func resetRuntime(groupID: String, now: Date = Date()) {
        GroupStore.withFileLock {
            guard var object = loadStoreObject() else { return }
            for key in ["usageTimersMs", "usageResetAtMs", "usageBucketsMs", "groupSnoozes", "groupSnoozeTotalsMs"] {
                var map = object[key] as? [String: Any] ?? [:]
                map.removeValue(forKey: groupID)
                object[key] = map
            }
            var anchors = object["usageResetAtMs"] as? [String: Any] ?? [:]
            anchors[groupID] = (now.timeIntervalSince1970 * 1000).rounded()
            object["usageResetAtMs"] = anchors
            write(object)
        }
        GroupStore.postDidChange()
    }

    /// A custom rule's memory (`v.state`), JSON text: "{}" when it has none.
    /// Kept in the store's `cbRuleState` map, as the browser keeps its own.
    public func ruleState(groupID: String) -> String {
        guard let state = (loadStoreObject()?["cbRuleState"] as? [String: Any])?[groupID],
              JSONSerialization.isValidJSONObject(state),
              let data = try? JSONSerialization.data(withJSONObject: state) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Writes rules' states (JSON text; nil forgets a group's).
    public func writeRuleStates(_ states: [String: String?]) {
        guard !states.isEmpty else { return }
        GroupStore.withFileLock {
            guard var object = loadStoreObject() else { return }
            var stored = object["cbRuleState"] as? [String: Any] ?? [:]
            for (groupID, json) in states {
                stored[groupID] = json.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }
            }
            object["cbRuleState"] = stored
            write(object)
        }
    }

    /// `snoozeGivenMs` is what running budget snoozes gave this tick: added to
    /// the groups' snooze totals (a budget snooze is counted as it is used).
    public func writeUsage(
        timersMs: [String: Double],
        resetAtMs: [String: Double],
        bucketsMs: [String: [Double: Double]] = [:],
        snoozeGivenMs: [String: Double] = [:]
    ) {
        guard !timersMs.isEmpty || !resetAtMs.isEmpty || !bucketsMs.isEmpty || !snoozeGivenMs.isEmpty else { return }
        // Under the store's file lock: an edit saved between this read and
        // write would otherwise be lost.
        GroupStore.withFileLock {
            guard var object = loadStoreObject() else { return }
            if !bucketsMs.isEmpty {
                var stored = object["usageBucketsMs"] as? [String: Any] ?? [:]
                for (groupID, buckets) in bucketsMs { stored[groupID] = UsageBudget.bucketJSON(buckets) }
                object["usageBucketsMs"] = stored
            }
            if !timersMs.isEmpty {
                object["usageTimersMs"] = Self.numbers(object["usageTimersMs"]).merging(timersMs) { $1 }
            }
            if !resetAtMs.isEmpty {
                object["usageResetAtMs"] = Self.numbers(object["usageResetAtMs"]).merging(resetAtMs) { $1 }
            }
            if !snoozeGivenMs.isEmpty {
                object["groupSnoozeTotalsMs"] = Self.numbers(object["groupSnoozeTotalsMs"]).merging(snoozeGivenMs) { $0 + $1 }
            }
            write(object)
        }
    }

    // MARK: Parsing

    /// The editor's `groupSnoozes` as the core `SnoozeState` model.
    private static func snoozes(_ value: Any?) -> [String: SnoozeState] {
        (value as? [String: Any] ?? [:]).compactMapValues { value in
            guard let entry = value as? [String: Any] else { return nil }
            func date(_ key: String) -> Date? {
                guard let ms = (entry[key] as? NSNumber)?.doubleValue, ms > 0 else { return nil }
                return Date(timeIntervalSince1970: ms / 1000)
            }
            let extraMs = (entry["extraMs"] as? NSNumber)?.doubleValue ?? 0
            return SnoozeState(startsAt: date("startsAtMs"), until: date("untilMs"),
                               cooldownUntil: date("cooldownUntilMs"),
                               justification: (entry["justification"] as? String) ?? "",
                               budgetExtra: (entry["kind"] as? String) == "budget" && extraMs > 0 ? extraMs / 1000 : nil)
        }
    }

    private static func numbers(_ value: Any?) -> [String: Double] {
        (value as? [String: Any] ?? [:]).compactMapValues { ($0 as? NSNumber)?.doubleValue }
    }

    /// The stored document, raw. Anything that writes the file back must start
    /// from this: persisting the shared overlay would bake another device's
    /// (possibly incomplete) copy into this Mac's own groups.
    private func loadStoreObject() -> [String: Any]? {
        guard let data = shared.readData(SharedAppGroupStore.webStoreFileName) else { return nil }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (try? SharedAppGroupStore.webSchema.validateFlat(root)) != nil else { return nil }
        return root
    }

    private func write(_ object: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
            shared.writeData(data, to: SharedAppGroupStore.webStoreFileName)
        }
    }
}
