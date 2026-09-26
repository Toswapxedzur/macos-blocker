import Foundation

/// The native, authoritative owner of `web-store.json` — the editor's
/// chrome.storage snapshot (`blockedGroups` plus `globalSettings`, usage, snooze
/// and log keys) living in the App Group container.
///
/// Design (Option A): the raw chrome.storage envelope stays the source of truth.
/// The web editor authors a richer per-group object than the native typed
/// `BlockGroup` projection can represent (platform lines, feed filters, the
/// redirect field, …), and `ChromeExtensionImporter`
/// is deliberately lossy because it only needs an enforcement view. So native
/// mutations here are **field-surgical**: they edit the exact fields they own on
/// the matching group dictionary and preserve every other field and every other
/// top-level key verbatim. Round-tripping through `BlockGroup` would silently
/// drop the editor's data, so we never do it.
///
/// `BlockGroup` remains the read-only enforcement projection: `save` re-derives
/// the JavaScript-free `EnforcementPlan` the Screen Time extensions read, exactly
/// as the WebView persist path does.
///
/// This is the single write surface both the WebView bridge and (later) MCP call,
/// so there is one implementation of every group mutation.
public final class GroupStore: @unchecked Sendable {
    private let shared: SharedAppGroupStore
    /// One lock for the process: every GroupStore (editor bridge, AI tools, the
    /// "+" panel) and the engine's usage writes load-modify-save the one file.
    private static let fileLock = NSLock()
    private var lock: NSLock { Self.fileLock }

    /// Runs `body` holding the store-file lock (for writers outside GroupStore,
    /// like the engine's usage counters), so no write is lost to a race.
    public static func withFileLock<T>(_ body: () throws -> T) rethrows -> T {
        fileLock.lock(); defer { fileLock.unlock() }
        return try body()
    }

    public init(shared: SharedAppGroupStore = SharedAppGroupStore()) {
        self.shared = shared
    }

    // MARK: Reads

    /// The current document, or an empty one when no store exists yet.
    public func load() -> WebStoreDocument {
        lock.lock(); defer { lock.unlock() }
        return loadLocked()
    }

    /// Lays the live shared state of linked groups over a stored document (set
    /// by the app to the hub's overlay). The AI tools read and lock-check through
    /// it, exactly like enforcement and the user's view — never a stale copy.
    public static var sharedOverlay: (([String: Any]) -> [String: Any])?

    /// The typed, read-only projection of the current groups, as linked devices
    /// share them.
    public func loadGroups() -> [BlockGroup] {
        guard var data = shared.readData(SharedAppGroupStore.webStoreFileName, silent: true) else { return [] }
        if let overlay = Self.sharedOverlay,
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let overlaid = try? JSONSerialization.data(withJSONObject: overlay(object)) {
            data = overlaid
        }
        return (try? ChromeExtensionImporter.importGroups(from: data))?.groups ?? []
    }

    // MARK: Writes

    /// Persists the document verbatim, then rebuilds the enforcement plan the
    /// Screen Time extensions read. Kept private-of-behavior identical to the
    /// WebView persist path so the two writers can never derive different plans.
    /// Writes the whole document (and rebuilds the enforcement plan) under the
    /// lock. `notify` posts `didChangeNotification` so a live editor re-seeds; the
    /// editor's OWN persist path passes `false` (it already shows this state, and
    /// re-seeding itself would be wasted work), while native/MCP writers leave it
    /// true so the open editor learns about the out-of-band change.
    public func save(_ document: WebStoreDocument, notify: Bool = true) {
        lock.lock()
        saveLocked(document)
        lock.unlock()
        if notify { Self.postDidChange() }
    }

    /// Load → mutate → save under one lock, so two concurrent edits (e.g. the
    /// editor and an MCP call) can't read-modify-write over each other. The
    /// closure receives the current document; if it throws, nothing is written.
    /// Returns the persisted document so a caller can reconcile the live WebView.
    @discardableResult
    public func mutate(_ body: (inout WebStoreDocument) throws -> Void) rethrows -> WebStoreDocument {
        lock.lock()
        let document: WebStoreDocument
        do {
            var working = loadLocked()
            // Locks are judged on the shared view: a group locked on a linked
            // device is locked here too, even before the editor adopts it.
            if let overlay = Self.sharedOverlay {
                let groups = overlay(working.raw)["blockedGroups"] as? [[String: Any]] ?? []
                working.sharedView = Dictionary(groups.compactMap { g in (g["id"] as? String).map { ($0, g) } },
                                                uniquingKeysWith: { first, _ in first })
            }
            try body(&working)
            saveLocked(working)
            document = working
        } catch {
            lock.unlock()
            throw error
        }
        lock.unlock()
        Self.postDidChange()
        return document
    }

    /// Fired after any native write to `web-store.json` (an MCP tool call, a
    /// direct `save`), so a live WebView editor can re-seed itself instead of
    /// showing a stale tree. Posted OUTSIDE the lock: an observer that reads the
    /// store back must never re-enter it while the writer still holds the lock.
    /// A no-op when nothing is listening (no editor open).
    public static let didChangeNotification = Notification.Name("com.adamancia.vault.GroupStoreDidChange")

    private static func postDidChange() {
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    // MARK: Locked internals

    private func loadLocked() -> WebStoreDocument {
        guard let data = shared.readData(SharedAppGroupStore.webStoreFileName, silent: true),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return WebStoreDocument(raw: ["blockedGroups": [] as [[String: Any]]])
        }
        return WebStoreDocument(raw: object)
    }

    private func saveLocked(_ document: WebStoreDocument) {
        guard JSONSerialization.isValidJSONObject(document.raw),
              let data = try? JSONSerialization.data(withJSONObject: document.raw, options: [.sortedKeys]) else {
            return
        }
        shared.writeData(data, to: SharedAppGroupStore.webStoreFileName)
        if let plan = EnforcementPlanBuilder.build(
            fromWebStoreData: data,
            nativeTargetsByGroup: shared.loadGroupTargets()
        ) {
            shared.saveEnforcementPlan(plan)
        }
    }
}

public enum GroupStoreError: Error, Equatable {
    case groupNotFound(String)
    case invalidInput(String)
    /// The group is frozen, strict or parental-locked; like the editor, the
    /// store refuses edits to it.
    case groupLocked(String)
    /// Another group already has this name (case-insensitively): groups link by
    /// name, so names stay unique, as in the editor.
    case duplicateName(String)
    case notLocked(String)
    /// A parental lock without a PIN yet: the lock sets one.
    case pinRequired
}

/// A parsed `web-store.json` envelope plus the field-surgical group mutations.
///
/// The whole raw dictionary is preserved; a mutation only ever touches the field
/// it names on the group it names. Unknown top-level keys and unknown per-group
/// fields survive every edit unchanged — that is what lets native code co-own a
/// store whose full schema is authored by the JavaScript editor.
public struct WebStoreDocument {
    public private(set) var raw: [String: Any]
    /// Each group as linked devices share it (see GroupStore.sharedOverlay),
    /// by id; nil = judge by the stored group alone. Locks and PINs are read
    /// from here.
    public var sharedView: [String: [String: Any]]?

    /// Per-group companion maps the editor keys by group id. They are cleared for
    /// a deleted group so the store doesn't accrue orphaned usage/snooze entries.
    private static let perGroupMapKeys = [
        "usageTimersMs", "usageResetAtMs", "usageBucketsMs", "groupSnoozes", "groupSnoozeTotalsMs",
    ]

    public init(raw: [String: Any]) {
        self.raw = raw
    }

    // MARK: Read helpers

    public var groupIDs: [String] {
        groups.compactMap { $0["id"] as? String }
    }

    public var groupCount: Int { groups.count }

    public func group(id: String) -> [String: Any]? {
        groups.first { ($0["id"] as? String) == id }
    }

    // MARK: Mutations

    public mutating func setGroupEnabled(id: String, _ enabled: Bool) throws {
        try mutateGroup(id: id) { $0["enabled"] = enabled }
    }

    /// Switching to a timed mode restarts the budget, as the editor's save does.
    public mutating func setGroupMode(id: String, _ mode: BlockingMode, now: Date = Date()) throws {
        let before = group(id: id)?["mode"] as? String
        try mutateGroup(id: id) { $0["mode"] = mode.rawValue }
        guard mode == .afterMinutes, before != mode.rawValue else { return }
        var timers = raw["usageTimersMs"] as? [String: Any] ?? [:]
        var resets = raw["usageResetAtMs"] as? [String: Any] ?? [:]
        var buckets = raw["usageBucketsMs"] as? [String: Any] ?? [:]
        timers[id] = 0
        resets[id] = (now.timeIntervalSince1970 * 1000).rounded()
        buckets.removeValue(forKey: id)
        raw["usageTimersMs"] = timers
        raw["usageResetAtMs"] = resets
        raw["usageBucketsMs"] = buckets
    }

    public mutating func setGroupAllowedMinutes(id: String, _ minutes: Int) throws {
        guard minutes >= 0 else { throw GroupStoreError.invalidInput("allowedMinutes") }
        try mutateGroup(id: id) { $0["allowedMinutes"] = minutes }
    }

    public mutating func renameGroup(id: String, name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GroupStoreError.invalidInput("name") }
        if groups.contains(where: { ($0["id"] as? String) != id && (($0["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == trimmed.lowercased() }) {
            throw GroupStoreError.duplicateName(trimmed)
        }
        try mutateGroup(id: id) { $0["name"] = trimmed }
    }

    /// Since 2026-09-24 a group's website list and app list are scope lines
    /// ({surface: "site", sites, sitesExcept} / {surface: "apps", apps}), the
    /// same shape the extension stores. A mutation edits that line, creating it
    /// when missing and folding a legacy top-level `sites` / `apps` field into
    /// it on the way (older stores written by the previous editor).
    private static func mutateScopeLine(
        _ group: inout [String: Any],
        surface: String,
        _ body: (inout [String: Any]) -> Void
    ) {
        var scopes = group["scopes"] as? [[String: Any]] ?? []
        var index = scopes.firstIndex { ($0["surface"] as? String) == surface }
        if index == nil {
            var line: [String: Any] = ["id": "\(surface)-1", "surface": surface, "platform": NSNull(), "action": "block"]
            if surface == "site" {
                line["sites"] = group["sites"] as? [String] ?? []
                line["sitesExcept"] = (group["allowlist"] as? Bool) ?? false
            } else {
                line["apps"] = group["apps"] as? [[String: Any]] ?? []
            }
            scopes.append(line)
            index = scopes.count - 1
        }
        body(&scopes[index!])
        group["scopes"] = scopes
        group.removeValue(forKey: surface == "site" ? "sites" : "apps")
        if surface == "site" { group.removeValue(forKey: "allowlist") }
    }

    /// The website list of a stored group (its site line, else a legacy field).
    public static func sites(of group: [String: Any]) -> [String] {
        let scopes = group["scopes"] as? [[String: Any]] ?? []
        if let line = scopes.first(where: { ($0["surface"] as? String) == "site" }) {
            return line["sites"] as? [String] ?? []
        }
        return group["sites"] as? [String] ?? []
    }

    /// "Block every application except these" on the group's Apps entry.
    public static func appsExcept(of group: [String: Any]) -> Bool {
        let scopes = group["scopes"] as? [[String: Any]] ?? []
        guard let line = scopes.first(where: { ($0["surface"] as? String) == "apps" }) else { return false }
        return (line["appsExcept"] as? Bool) == true
    }

    /// True when the group's website list uses the extension's "pause" page
    /// action (a countdown before the page is let through) rather than a block.
    public static func siteListPauses(_ group: [String: Any]) -> Bool {
        let scopes = group["scopes"] as? [[String: Any]] ?? []
        guard let line = scopes.first(where: { ($0["surface"] as? String) == "site" }) else { return false }
        return (line["action"] as? String) == "pause"
    }

    /// The app list of a stored group (its apps line, else a legacy field).
    public static func apps(of group: [String: Any]) -> [[String: Any]] {
        let scopes = group["scopes"] as? [[String: Any]] ?? []
        if let line = scopes.first(where: { ($0["surface"] as? String) == "apps" }) {
            return line["apps"] as? [[String: Any]] ?? []
        }
        return group["apps"] as? [[String: Any]] ?? []
    }

    /// Adds a website to a group's Websites entry, idempotently. Dedupe compares
    /// normalized hosts (the same normalization enforcement uses) so `www.x.com`,
    /// `x.com`, and `https://x.com/p` are one entry; the caller's original text is
    /// stored so the editor still shows what the user typed.
    public mutating func addWebsite(id: String, host: String) throws {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GroupStoreError.invalidInput("host") }
        let key = ChromeExtensionImporter.normalizeHost(trimmed)
        try mutateGroup(id: id) { group in
            Self.mutateScopeLine(&group, surface: "site") { line in
                var sites = line["sites"] as? [String] ?? []
                let alreadyPresent = sites.contains {
                    if let key { return ChromeExtensionImporter.normalizeHost($0) == key }
                    return $0 == trimmed
                }
                guard !alreadyPresent else { return }
                sites.append(trimmed)
                line["sites"] = sites
            }
        }
    }

    public mutating func removeWebsite(id: String, host: String) throws {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = ChromeExtensionImporter.normalizeHost(trimmed) ?? trimmed
        try mutateGroup(id: id) { group in
            Self.mutateScopeLine(&group, surface: "site") { line in
                var sites = line["sites"] as? [String] ?? []
                sites.removeAll { (ChromeExtensionImporter.normalizeHost($0) ?? $0) == key }
                line["sites"] = sites
            }
        }
    }

    /// Adds an application target `{ id: <bundleId>, name: <displayName> }` to a
    /// group's Apps entry, idempotently by bundle id.
    public mutating func addApplication(id: String, bundleID: String, name: String?) throws {
        let bundle = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundle.isEmpty else { throw GroupStoreError.invalidInput("bundleID") }
        let display = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        try mutateGroup(id: id) { group in
            Self.mutateScopeLine(&group, surface: "apps") { line in
                var apps = line["apps"] as? [[String: Any]] ?? []
                guard !apps.contains(where: { ($0["id"] as? String) == bundle }) else { return }
                apps.append(["id": bundle, "name": (display?.isEmpty == false) ? display! : bundle])
                line["apps"] = apps
            }
        }
    }

    public mutating func removeApplication(id: String, bundleID: String) throws {
        let bundle = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        try mutateGroup(id: id) { group in
            Self.mutateScopeLine(&group, surface: "apps") { line in
                var apps = line["apps"] as? [[String: Any]] ?? []
                apps.removeAll { ($0["id"] as? String) == bundle }
                line["apps"] = apps
            }
        }
    }

    private func isLocked(_ group: [String: Any]) -> Bool {
        if let sharedView, let id = group["id"] as? String, let shared = sharedView[id] { return Self.isLocked(shared) }
        return Self.isLocked(group)
    }

    /// Same rule as the extension (`cbGroupIsLocked`): any freeze mode locks.
    public static func isLocked(_ group: [String: Any]) -> Bool {
        guard let mode = group["freezeMode"] as? String else { return false }
        return mode != "none"
    }

    public mutating func deleteGroup(id: String) throws {
        if let group = group(id: id), isLocked(group) { throw GroupStoreError.groupLocked(id) }
        var list = groups
        let before = list.count
        list.removeAll { ($0["id"] as? String) == id }
        guard list.count < before else { throw GroupStoreError.groupNotFound(id) }
        groups = list
        for key in Self.perGroupMapKeys {
            guard var map = raw[key] as? [String: Any] else { continue }
            map.removeValue(forKey: id)
            raw[key] = map
        }
    }

    // MARK: Private

    private var groups: [[String: Any]] {
        get { raw["blockedGroups"] as? [[String: Any]] ?? [] }
        set { raw["blockedGroups"] = newValue }
    }

    // MARK: Create, lock, unlock, move — the editor's actions and gates

    /// A new, unlocked group with the editor's defaults (a site group; the
    /// editor fills every other field on load). Returns its id.
    @discardableResult
    public mutating func createGroup(name: String, now: Date = Date()) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GroupStoreError.invalidInput("name") }
        if groups.contains(where: { (($0["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == trimmed.lowercased() }) {
            throw GroupStoreError.duplicateName(trimmed)
        }
        let nowMs = (now.timeIntervalSince1970 * 1000).rounded()
        let id = "group-\(Int(nowMs))-\(UUID().uuidString.prefix(6).lowercased())"
        groups.append([
            "id": id, "groupType": "site", "name": trimmed, "enabled": true, "mode": "instant",
            "allowedMinutes": 15, "resetIntervalHours": 24, "resetAtMidnight": false, "rollingLimit": false,
            "activeDays": ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"],
            "timeWindowsText": "", "freezeMode": "none", "freezeModeChoice": "frozen", "strictFreezeHours": 24,
            "frozenAtMs": NSNull(), "parentalPasswordHash": NSNull(), "parentalPasswordSalt": NSNull(), "scopes": [],
        ])
        var timers = raw["usageTimersMs"] as? [String: Any] ?? [:]
        var resets = raw["usageResetAtMs"] as? [String: Any] ?? [:]
        timers[id] = 0
        resets[id] = nowMs
        raw["usageTimersMs"] = timers
        raw["usageResetAtMs"] = resets
        return id
    }

    public enum LockMode: String { case frozen, strict, parental }

    /// Locks a group, as the editor's Freeze does: strict for 0 < hours ≤ 72;
    /// parental needs the group's PIN (through the retry wait) or, when none is
    /// set yet, takes `pin` as the new PIN (the guardian settings' step).
    @discardableResult
    public mutating func lockGroup(id: String, mode: LockMode, strictHours: Double? = nil, pin: String? = nil, now: Date = Date()) throws -> LockOutcome {
        guard let group = group(id: id) else { throw GroupStoreError.groupNotFound(id) }
        if isLocked(group) { throw GroupStoreError.groupLocked(id) }
        let nowMs = (now.timeIntervalSince1970 * 1000).rounded()
        var fields: [String: Any] = ["freezeMode": mode.rawValue, "freezeModeChoice": mode.rawValue,
                                     "frozenAtMs": nowMs, "freezeChangedAtMs": nowMs]
        switch mode {
        case .frozen: break
        case .strict:
            let hours = strictHours ?? ((group["strictFreezeHours"] as? NSNumber)?.doubleValue ?? 24)
            guard hours > 0, hours <= 72 else { throw GroupStoreError.invalidInput("strictHours (0 < hours ≤ 72)") }
            fields["strictFreezeHours"] = hours
        case .parental:
            let shared = sharedView?[id] ?? group
            if let hash = shared["parentalPasswordHash"] as? String, !hash.isEmpty {
                switch passPinGate(group: shared, pin: pin ?? "", nowMs: nowMs) {
                case .success(let upgraded): if let upgraded { fields["parentalPasswordHash"] = upgraded }
                case .failure(let refused): return refused
                }
            } else {
                guard let pin, ParentalPin.isValid(pin) else { throw GroupStoreError.pinRequired }
                fields.merge(ParentalPin.newPinFields(pin: pin)) { _, new in new }
            }
        }
        try writeFields(id: id, fields)
        return .done
    }

    /// What a lock or unlock came to. Anything but `.done` changed no group
    /// (a wrong PIN is still counted, so the caller saves the document).
    public enum LockOutcome: Error, Equatable {
        case done
        /// A strict lock opens only at this moment.
        case strictUntil(Date)
        /// The editor's confirmation: ask, wait, confirm.
        case needsConfirmation
        /// Still inside the wait after a wrong PIN: the PIN was not checked.
        case pinWait(seconds: Int)
        /// Wrong PIN: the next try waits this long.
        case pinWrong(waitSeconds: Int)
    }

    /// Unlocks a group through the editor's gates. A parental lock with a PIN
    /// opens with the PIN (retry wait applies); any other lock returns the gate
    /// to pass unless `confirmed` (the caller runs the ask-wait-confirm step).
    @discardableResult
    public mutating func unlockGroup(id: String, pin: String? = nil, confirmed: Bool = false, now: Date = Date()) throws -> LockOutcome {
        guard let stored = group(id: id) else { throw GroupStoreError.groupNotFound(id) }
        let group = sharedView?[id] ?? stored
        guard Self.isLocked(group) else { throw GroupStoreError.notLocked(id) }
        let nowMs = (now.timeIntervalSince1970 * 1000).rounded()
        var fields: [String: Any] = ["freezeMode": "none", "frozenAtMs": NSNull(), "freezeChangedAtMs": nowMs]
        let mode = group["freezeMode"] as? String
        let hasPin = !((group["parentalPasswordHash"] as? String) ?? "").isEmpty
        if mode == "parental" {
            if hasPin {
                switch passPinGate(group: group, pin: pin ?? "", nowMs: nowMs) {
                case .success(let upgraded): if let upgraded { fields["parentalPasswordHash"] = upgraded }
                case .failure(let refused): return refused
                }
            }
            try writeFields(id: id, fields)
            return .done
        }
        if mode == "strict" {
            let frozenAt = (group["frozenAtMs"] as? NSNumber)?.doubleValue ?? 0
            let hours = (group["strictFreezeHours"] as? NSNumber)?.doubleValue ?? 0
            let opensAt = frozenAt + hours * 3_600_000
            if opensAt > nowMs { return .strictUntil(Date(timeIntervalSince1970: opensAt / 1000)) }
        }
        guard confirmed else { return .needsConfirmation }
        try writeFields(id: id, fields)
        return .done
    }

    /// Moves a group in the list (the editor's drag). A locked group stays put.
    /// The order is this device's own; it is not shared with linked devices.
    public mutating func moveGroup(id: String, to index: Int) throws {
        var list = groups
        guard let from = list.firstIndex(where: { ($0["id"] as? String) == id }) else { throw GroupStoreError.groupNotFound(id) }
        if isLocked(list[from]) { throw GroupStoreError.groupLocked(id) }
        guard index >= 0, index < list.count else { throw GroupStoreError.invalidInput("index (0…\(list.count - 1))") }
        let moved = list.remove(at: from)
        list.insert(moved, at: index)
        groups = list
    }

    /// The PIN gate over the editor's stored wrong-PIN counts. Returns an
    /// upgraded hash to store when the PIN was in an old format.
    private mutating func passPinGate(group: [String: Any], pin: String, nowMs: Double) -> Result<String?, LockOutcome> {
        var attempts = raw[ParentalPin.attemptsKey] as? [String: Any] ?? [:]
        let result = ParentalPin.check(attempts: &attempts, group: group, pin: pin, nowMs: nowMs)
        raw[ParentalPin.attemptsKey] = attempts
        switch result {
        case .ok(let upgraded): return .success(upgraded)
        case .waiting(let seconds): return .failure(.pinWait(seconds: seconds))
        case .wrong(let seconds): return .failure(.pinWrong(waitSeconds: seconds))
        }
    }

    /// Writes fields without the lock check (the lock actions themselves).
    private mutating func writeFields(id: String, _ fields: [String: Any]) throws {
        var list = groups
        guard let index = list.firstIndex(where: { ($0["id"] as? String) == id }) else { throw GroupStoreError.groupNotFound(id) }
        list[index].merge(fields) { _, new in new }
        groups = list
    }

    private mutating func mutateGroup(
        id: String,
        _ body: (inout [String: Any]) throws -> Void
    ) throws {
        var list = groups
        guard let index = list.firstIndex(where: { ($0["id"] as? String) == id }) else {
            throw GroupStoreError.groupNotFound(id)
        }
        var group = list[index]
        if isLocked(group) { throw GroupStoreError.groupLocked(id) }
        try body(&group)
        list[index] = group
        groups = list
    }
}
