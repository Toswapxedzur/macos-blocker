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
        guard shared.readData(SharedAppGroupStore.webStoreFileName) == nil else { return }
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
    public func loadForTick(nowMs: Double) -> [String: Any] {
        let object = loadStoreObject() ?? [:]
        guard Self.tidied(object, nowMs: nowMs) != nil else { return object }
        return GroupStore.withFileLock {
            guard let fresh = loadStoreObject(), let tidy = Self.tidied(fresh, nowMs: nowMs) else {
                return loadStoreObject() ?? object
            }
            write(tidy)
            return tidy
        }
    }

    private static let perGroupKeys = ["usageTimersMs", "usageResetAtMs", "usageBucketsMs", "groupSnoozes", "groupSnoozeTotalsMs", "parentalPinAttempts"]

    /// The document with finished snoozes counted and deleted groups' entries
    /// dropped, or nil when neither applies.
    public static func tidied(_ document: [String: Any], nowMs: Double) -> [String: Any]? {
        let counted = countFinishedSnoozes(in: document, nowMs: nowMs)
        var next = counted ?? document
        var changed = counted != nil
        let ids = Set((next["blockedGroups"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String })
        for key in perGroupKeys {
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
    private static func countFinishedSnoozes(in document: [String: Any], nowMs: Double) -> [String: Any]? {
        guard var snoozes = document["groupSnoozes"] as? [String: Any] else { return nil }
        var totals = document["groupSnoozeTotalsMs"] as? [String: Any] ?? [:]
        var changed = false
        for (groupID, value) in snoozes {
            guard var entry = value as? [String: Any], entry["activeMsApplied"] as? Bool != true,
                  let start = (entry["startsAtMs"] as? NSNumber)?.doubleValue,
                  let until = (entry["untilMs"] as? NSNumber)?.doubleValue, nowMs >= until else { continue }
            totals[groupID] = ((totals[groupID] as? NSNumber)?.doubleValue ?? 0) + max(0, until - start)
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
            guard keys.contains(where: { Self.canonical(adopted[$0]) != Self.canonical(object[$0]) }) else { return false }
            var next = object
            for key in keys where adopted[key] != nil { next[key] = adopted[key] }
            write(next)
            return true
        }
        if wrote { GroupStore.postDidChange() }
        return wrote
    }

    private static func canonical(_ value: Any?) -> String {
        guard let value, let data = try? JSONSerialization.data(withJSONObject: ["v": value], options: [.sortedKeys]) else { return "" }
        return String(decoding: data, as: UTF8.self)
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
    public func writeUsage(
        timersMs: [String: Double],
        resetAtMs: [String: Double],
        bucketsMs: [String: [Double: Double]] = [:]
    ) {
        guard !timersMs.isEmpty || !resetAtMs.isEmpty || !bucketsMs.isEmpty else { return }
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
            return SnoozeState(startsAt: date("startsAtMs"), until: date("untilMs"),
                               cooldownUntil: date("cooldownUntilMs"),
                               justification: (entry["justification"] as? String) ?? "")
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
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func write(_ object: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
            shared.writeData(data, to: SharedAppGroupStore.webStoreFileName)
        }
    }
}
