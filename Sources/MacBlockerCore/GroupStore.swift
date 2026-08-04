import Foundation

/// The native, authoritative owner of `web-store.json` — the editor's
/// chrome.storage snapshot (`blockedGroups` plus `globalSettings`, usage, snooze
/// and log keys) living in the App Group container.
///
/// Design (Option A): the raw chrome.storage envelope stays the source of truth.
/// The web editor authors a richer per-group object than the native typed
/// `BlockGroup` projection can represent (platform group types, DOM/feed
/// controls, `skipToNextOnBlock`, `fallbackUrl`, …), and `ChromeExtensionImporter`
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
    private let lock = NSLock()

    public init(shared: SharedAppGroupStore = SharedAppGroupStore()) {
        self.shared = shared
    }

    // MARK: Reads

    /// The current document, or an empty one when no store exists yet.
    public func load() -> WebStoreDocument {
        lock.lock(); defer { lock.unlock() }
        return loadLocked()
    }

    /// The typed, read-only enforcement projection of the current groups.
    public func loadGroups() -> [BlockGroup] {
        guard let data = shared.readData(SharedAppGroupStore.webStoreFileName, silent: true),
              let result = try? ChromeExtensionImporter.importGroups(from: data) else {
            return []
        }
        return result.groups
    }

    // MARK: Writes

    /// Persists the document verbatim, then rebuilds the enforcement plan the
    /// Screen Time extensions read. Kept private-of-behavior identical to the
    /// WebView persist path so the two writers can never derive different plans.
    public func save(_ document: WebStoreDocument) {
        lock.lock(); defer { lock.unlock() }
        saveLocked(document)
    }

    /// Load → mutate → save under one lock, so two concurrent edits (e.g. the
    /// editor and an MCP call) can't read-modify-write over each other. The
    /// closure receives the current document; if it throws, nothing is written.
    /// Returns the persisted document so a caller can reconcile the live WebView.
    @discardableResult
    public func mutate(_ body: (inout WebStoreDocument) throws -> Void) rethrows -> WebStoreDocument {
        lock.lock(); defer { lock.unlock() }
        var document = loadLocked()
        try body(&document)
        saveLocked(document)
        return document
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
}

/// A parsed `web-store.json` envelope plus the field-surgical group mutations.
///
/// The whole raw dictionary is preserved; a mutation only ever touches the field
/// it names on the group it names. Unknown top-level keys and unknown per-group
/// fields survive every edit unchanged — that is what lets native code co-own a
/// store whose full schema is authored by the JavaScript editor.
public struct WebStoreDocument {
    public private(set) var raw: [String: Any]

    /// Per-group companion maps the editor keys by group id. They are cleared for
    /// a deleted group so the store doesn't accrue orphaned usage/snooze entries.
    private static let perGroupMapKeys = [
        "usageTimersMs", "usageResetAtMs", "groupSnoozes", "groupSnoozeTotalsMs",
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

    public mutating func setGroupMode(id: String, _ mode: BlockingMode) throws {
        try mutateGroup(id: id) { $0["mode"] = mode.rawValue }
    }

    public mutating func setGroupAllowedMinutes(id: String, _ minutes: Int) throws {
        guard minutes >= 0 else { throw GroupStoreError.invalidInput("allowedMinutes") }
        try mutateGroup(id: id) { $0["allowedMinutes"] = minutes }
    }

    public mutating func renameGroup(id: String, name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GroupStoreError.invalidInput("name") }
        try mutateGroup(id: id) { $0["name"] = trimmed }
    }

    /// Adds a website to a group's `sites`, idempotently. Dedupe compares
    /// normalized hosts (the same normalization enforcement uses) so `www.x.com`,
    /// `x.com`, and `https://x.com/p` are one entry; the caller's original text is
    /// stored so the editor still shows what the user typed.
    public mutating func addWebsite(id: String, host: String) throws {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GroupStoreError.invalidInput("host") }
        let key = ChromeExtensionImporter.normalizeHost(trimmed)
        try mutateGroup(id: id) { group in
            var sites = group["sites"] as? [String] ?? []
            let alreadyPresent = sites.contains {
                if let key { return ChromeExtensionImporter.normalizeHost($0) == key }
                return $0 == trimmed
            }
            guard !alreadyPresent else { return }
            sites.append(trimmed)
            group["sites"] = sites
        }
    }

    public mutating func removeWebsite(id: String, host: String) throws {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = ChromeExtensionImporter.normalizeHost(trimmed) ?? trimmed
        try mutateGroup(id: id) { group in
            guard var sites = group["sites"] as? [String] else { return }
            sites.removeAll { (ChromeExtensionImporter.normalizeHost($0) ?? $0) == key }
            group["sites"] = sites
        }
    }

    /// Adds an application target `{ id: <bundleId>, name: <displayName> }` to a
    /// group's `apps`, idempotently by bundle id.
    public mutating func addApplication(id: String, bundleID: String, name: String?) throws {
        let bundle = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundle.isEmpty else { throw GroupStoreError.invalidInput("bundleID") }
        let display = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        try mutateGroup(id: id) { group in
            var apps = group["apps"] as? [[String: Any]] ?? []
            guard !apps.contains(where: { ($0["id"] as? String) == bundle }) else { return }
            apps.append(["id": bundle, "name": (display?.isEmpty == false) ? display! : bundle])
            group["apps"] = apps
        }
    }

    public mutating func removeApplication(id: String, bundleID: String) throws {
        let bundle = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        try mutateGroup(id: id) { group in
            guard var apps = group["apps"] as? [[String: Any]] else { return }
            apps.removeAll { ($0["id"] as? String) == bundle }
            group["apps"] = apps
        }
    }

    public mutating func deleteGroup(id: String) throws {
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

    private mutating func mutateGroup(
        id: String,
        _ body: (inout [String: Any]) throws -> Void
    ) throws {
        var list = groups
        guard let index = list.firstIndex(where: { ($0["id"] as? String) == id }) else {
            throw GroupStoreError.groupNotFound(id)
        }
        var group = list[index]
        try body(&group)
        list[index] = group
        groups = list
    }
}
