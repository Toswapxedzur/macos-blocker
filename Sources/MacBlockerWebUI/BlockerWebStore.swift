import Foundation
import MacBlockerCore

/// Persists the editor's raw chrome.storage snapshot (the same
/// `blockedGroups` / `globalSettings` / usage keys the Chrome extension used)
/// into the App Group shared container so the native policy core and the
/// Screen Time extensions can read it. Every save also rebuilds the
/// JavaScript-free `EnforcementPlan` that the DeviceActivityMonitor extension
/// applies.
public final class BlockerWebStore: @unchecked Sendable {
    private let shared: SharedAppGroupStore

    public init(shared: SharedAppGroupStore = SharedAppGroupStore()) {
        self.shared = shared
    }

    public var fileURL: URL {
        shared.url(for: SharedAppGroupStore.webStoreFileName)
    }

    /// Creates a default `web-store.json` with an empty `blockedGroups` array
    /// if the file does not already exist. Call once at launch so the
    /// enforcement bridge always has a store to read from.
    public func seedIfNeeded() {
        let existing = shared.readData(SharedAppGroupStore.webStoreFileName)
        if existing != nil {
            print("[BlockerWebStore] seedIfNeeded: file already exists (\(shared.url(for: SharedAppGroupStore.webStoreFileName).path))")
            return
        }
        print("[BlockerWebStore] seedIfNeeded: no file at \(shared.url(for: SharedAppGroupStore.webStoreFileName).path) — writing default store")
        let defaultStore: [String: Any] = ["blockedGroups": [] as [[String: Any]]]
        save(rawStore: defaultStore)
        let verify = shared.readData(SharedAppGroupStore.webStoreFileName)
        if verify != nil {
            print("[BlockerWebStore] seedIfNeeded: ✓ file written successfully")
        } else {
            print("[BlockerWebStore] seedIfNeeded: ✗ file still missing after write!")
        }
    }

    public func loadRawJSON() -> String? {
        guard let data = shared.readData(SharedAppGroupStore.webStoreFileName) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    public func save(rawStore: Any) {
        guard JSONSerialization.isValidJSONObject(rawStore),
              let data = try? JSONSerialization.data(withJSONObject: rawStore, options: [.sortedKeys])
        else {
            return
        }
        shared.writeData(data, to: SharedAppGroupStore.webStoreFileName)
        rebuildEnforcementPlan(from: data)
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
    }

    public func loadUsageTimers() -> UsageTimers {
        guard let object = loadStoreObject() else {
            return UsageTimers(timersMs: [:], resetAtMs: [:])
        }
        return UsageTimers(
            timersMs: doubleMap(object["usageTimersMs"]),
            resetAtMs: doubleMap(object["usageResetAtMs"])
        )
    }

    /// Overwrites the given per-group `usageTimersMs` / `usageResetAtMs` entries
    /// (merging into whatever is stored, preserving untouched groups and every
    /// other key). Used by the enforcement bridge to accrue time and to apply
    /// reset-interval rollovers, keeping the popup and native enforcement on one
    /// source of truth. A no-op write when both maps are empty.
    public func writeUsage(timersMs: [String: Double], resetAtMs: [String: Double]) {
        guard !timersMs.isEmpty || !resetAtMs.isEmpty, var object = loadStoreObject() else {
            return
        }
        if !timersMs.isEmpty {
            var stored = doubleMap(object["usageTimersMs"])
            for (key, value) in timersMs { stored[key] = value }
            object["usageTimersMs"] = stored
        }
        if !resetAtMs.isEmpty {
            var stored = doubleMap(object["usageResetAtMs"])
            for (key, value) in resetAtMs { stored[key] = value }
            object["usageResetAtMs"] = stored
        }
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
            shared.writeData(data, to: SharedAppGroupStore.webStoreFileName)
        }
    }

    /// Parses the editor's `groupSnoozes` into the core `SnoozeState` model so
    /// native enforcement honors an active snooze (temporary unblock) the same
    /// way the popup does.
    public func loadSnoozes() -> [String: SnoozeState] {
        guard let object = loadStoreObject(),
              let raw = object["groupSnoozes"] as? [String: Any]
        else {
            return [:]
        }
        var result: [String: SnoozeState] = [:]
        for (groupID, value) in raw {
            guard let dictionary = value as? [String: Any] else { continue }
            result[groupID] = SnoozeState(
                startsAt: msToDate(dictionary["startsAtMs"]),
                until: msToDate(dictionary["untilMs"]),
                cooldownUntil: msToDate(dictionary["cooldownUntilMs"]),
                justification: (dictionary["justification"] as? String) ?? ""
            )
        }
        return result
    }

    private func msToDate(_ value: Any?) -> Date? {
        let ms: Double?
        if let number = value as? Double { ms = number }
        else if let number = value as? Int { ms = Double(number) }
        else if let number = (value as? NSNumber)?.doubleValue { ms = number }
        else { ms = nil }
        guard let ms, ms > 0 else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }

    private func loadStoreObject() -> [String: Any]? {
        guard let data = shared.readData(SharedAppGroupStore.webStoreFileName),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return object
    }

    private func doubleMap(_ value: Any?) -> [String: Double] {
        guard let dictionary = value as? [String: Any] else { return [:] }
        var result: [String: Double] = [:]
        for (key, raw) in dictionary {
            if let number = raw as? Double {
                result[key] = number
            } else if let number = raw as? Int {
                result[key] = Double(number)
            } else if let number = (raw as? NSNumber)?.doubleValue {
                result[key] = number
            }
        }
        return result
    }

    /// Bridges the editor's stored `blockedGroups` into the typed core model.
    public func importedGroups() -> ChromeExtensionImportResult? {
        guard let data = shared.readData(SharedAppGroupStore.webStoreFileName) else {
            print("[BlockerWebStore] No web store file found at: \(shared.url(for: SharedAppGroupStore.webStoreFileName).path)")
            return nil
        }
        do {
            return try ChromeExtensionImporter.importGroups(from: data)
        } catch {
            print("[BlockerWebStore] importGroups failed: \(error)")
            return nil
        }
    }

    /// Recomputes the enforcement plan that the Screen Time extensions read,
    /// merging any natively-assigned app/category targets.
    private func rebuildEnforcementPlan(from data: Data) {
        guard let result = try? ChromeExtensionImporter.importGroups(from: data) else {
            return
        }
        let plan = EnforcementPlanBuilder.build(
            from: result.groups,
            nativeTargetsByGroup: shared.loadGroupTargets()
        )
        shared.saveEnforcementPlan(plan)
    }

    /// Rebuilds the plan without a fresh save — call after assigning native
    /// targets so the plan reflects them immediately.
    public func rebuildEnforcementPlan() {
        guard let data = shared.readData(SharedAppGroupStore.webStoreFileName) else {
            let plan = EnforcementPlan()
            shared.saveEnforcementPlan(plan)
            return
        }
        rebuildEnforcementPlan(from: data)
    }
}
