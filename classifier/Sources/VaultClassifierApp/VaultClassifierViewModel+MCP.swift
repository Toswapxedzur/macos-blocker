import Foundation
import VaultClassifierCore

// The classifier's MCP surface (owner 2026-09-23: "what the user can do, another
// process controlling the MCP server can also do — 1:1 parity"). It exposes the
// SAME two halves the web page runs on: the snapshot the page renders from, and
// the bounded web-action dispatcher its buttons call. Nothing here is a second
// implementation — a new page action is automatically an MCP action, and the
// catalog below is parity-checked against the dispatcher's source by a test.

/// One web action as a process sees it: its name, the `data` keys it reads, and
/// what it does. Keys are exactly what the page's form sends.
public struct ClassifierWebActionDescriptor: Equatable, Sendable {
    public let name: String
    public let keys: [String]
    public let summary: String

    public init(name: String, keys: [String], summary: String) {
        self.name = name
        self.keys = keys
        self.summary = summary
    }
}

public enum ClassifierWebActionCatalog {
    public static let actions: [ClassifierWebActionDescriptor] = [
        .init(name: "state", keys: [], summary: "Refresh local state from the store."),
        .init(name: "workspace", keys: ["workspace"], summary: "Switch the page's workspace (tagTree, llmAssist, browserBridge, classificationData, knowledge)."),
        .init(name: "createTree", keys: ["name"], summary: "Create an empty tag tree."),
        .init(name: "addCollectionPlatform", keys: ["platformID"], summary: "Add a platform binding (collection on)."),
        .init(name: "confirmDeleteCollectionPlatform", keys: ["platformID"], summary: "Remove a platform binding and its collected data (trash)."),
        .init(name: "restoreTrashedEntry", keys: ["id"], summary: "Restore a trashed entry."),
        .init(name: "permanentlyDeleteTrashedEntry", keys: ["id"], summary: "Purge a trashed entry."),
        .init(name: "setCollectionEnabled", keys: ["platformID", "enabled"], summary: "Turn collection on/off for a platform."),
        .init(name: "clearCollectionDiagnostics", keys: [], summary: "Clear the collection diagnostics log."),
        .init(name: "setActiveClassifierType", keys: ["platformID", "classifierTypeID"], summary: "Set which group answers a platform (classifierTypeID may be omitted to clear)."),
        .init(name: "createClassifierType", keys: ["name", "platformID"], summary: "Create a classifier group for one platform with its own empty tree; it follows the global dials until given its own."),
        .init(name: "reorderClassifierTypes", keys: ["orderedIDs"], summary: "Reorder groups (array of group ids)."),
        .init(name: "configureClassifierType", keys: ["typeID", "name", "applicablePlatformID"], summary: "Rename a group and/or move it to another platform."),
        .init(name: "confirmDeleteClassifierType", keys: ["typeID"], summary: "Delete a group."),
        .init(name: "createProviderProfile", keys: ["type"], summary: "Create a provider profile (gemini, openAI, anthropic, …)."),
        .init(name: "testProviderProfile", keys: ["profileID", "credential", "customEndpoint", "testModelIdentifier"], summary: "Test a provider profile's credential (stores it on success)."),
        .init(name: "updateProviderConnection", keys: ["profileID", "credential", "customEndpoint", "testModelIdentifier"], summary: "Update a provider profile's connection fields."),
        .init(name: "probeProviderModelCatalog", keys: ["profileID"], summary: "Fetch a provider's model list."),
        .init(name: "confirmDeleteProviderProfile", keys: ["profileID"], summary: "Delete a provider profile."),
        .init(name: "renameTree", keys: ["treeID", "name"], summary: "Rename a tree."),
        .init(name: "deleteTree", keys: ["treeID"], summary: "Delete a tree."),
        .init(name: "rearrangeTree", keys: ["treeID"], summary: "Auto-layout a tree's canvas."),
        .init(name: "addTag", keys: ["treeID", "name", "description", "parentID", "positionX", "positionY"], summary: "Add a tag (optionally under parentID) at a canvas position."),
        .init(name: "moveTag", keys: ["treeID", "nodeID", "positionX", "positionY"], summary: "Move a tag on the canvas."),
        .init(name: "renameTag", keys: ["treeID", "nodeID", "name"], summary: "Rename a tag."),
        .init(name: "updateTag", keys: ["treeID", "nodeID", "name", "description"], summary: "Rename a tag and set its description."),
        .init(name: "connectTag", keys: ["treeID", "nodeID", "parentID"], summary: "Make a tag a child of another."),
        .init(name: "disconnectTag", keys: ["treeID", "nodeID"], summary: "Detach a tag from its parent."),
        .init(name: "deleteTag", keys: ["treeID", "nodeID"], summary: "Delete a tag."),
        .init(name: "savePackageSettings", keys: ["packageUpdateMode"], summary: "Set the taxonomy package update mode (automatic, downloadThenAsk, manual)."),
        .init(name: "saveLocalLLMSettings", keys: ["speedQuality", "strictness", "houseRules"], summary: "Set the two dials (speedQuality fast|balanced|best, strictness 1–5) and the global house rules; reloads the engine."),
        .init(name: "downloadModel", keys: ["id"], summary: "Download a catalog model (id from settings.localLLM.modelLibrary)."),
        .init(name: "cancelModelDownload", keys: ["id"], summary: "Cancel a model download."),
        .init(name: "deleteModelFile", keys: ["fileName"], summary: "Delete a downloaded model file."),
        .init(name: "deleteKnowledgeEntry", keys: ["id"], summary: "Delete a knowledge entry (creator or term)."),
        .init(name: "addKnowledgeTerm", keys: ["subject", "meaning"], summary: "Add a term (meaning may be empty to look it up through research)."),
        .init(name: "editKnowledgeEntry", keys: ["id", "meaning"], summary: "Edit a knowledge entry's one sentence."),
        .init(name: "retryFailedResearch", keys: [], summary: "Clear research cooldowns and re-queue failed subjects."),
        .init(name: "saveResearchSettings", keys: ["enabled", "llmProviderProfileID", "llmModelIdentifier"], summary: "Research on/off and the provider profile + model that answers."),
        .init(name: "submitCorrection", keys: ["typeID", "platformID", "entryID", "correctTagIDs", "note"], summary: "Record a human correction for a video (authoritative tags)."),
        .init(name: "saveClassifierTypeLocalModel", keys: ["typeID", "speedQuality", "strictness", "houseRules"], summary: "A group's own dial positions and house rules (blank = follow global)."),
        .init(name: "saveClassifierTypeResearch", keys: ["typeID", "researchMode"], summary: "A group's research switch: inherit, on, off."),
        .init(name: "setBackupOwnerCode", keys: ["ownerCode"], summary: "Set the backup owner code."),
        .init(name: "unlockBackup", keys: ["ownerCode"], summary: "Unlock backup settings with the owner code."),
        .init(name: "saveBackup", keys: ["enabled", "directory"], summary: "Save backup settings."),
        .init(name: "backupNow", keys: [], summary: "Run a backup now (needs the backup unlocked and enabled)."),
    ]

    public static func descriptor(named name: String) -> ClassifierWebActionDescriptor? {
        actions.first { $0.name == name }
    }
}

/// The outcome of one MCP-driven action: whether the page would re-render, and
/// the issue text the page would show (nil = no error).
public struct ClassifierMCPActionOutcome: Equatable, Sendable {
    public let rerender: Bool
    public let issue: String?

    public init(rerender: Bool, issue: String?) {
        self.rerender = rerender
        self.issue = issue
    }
}

@MainActor
extension VaultClassifierViewModel {
    /// Top-level snapshot keys a process may ask for by name; `assets.<key>`
    /// selects one asset collection (trees, datasets, knowledge, classifierTypes,
    /// providerProfiles, providerProtocols, collectionPlatforms, bindings, …).
    static let mcpSnapshotSections = ["settings", "assets", "backup", "notices", "trash", "workspace", "issue"]

    /// The page's snapshot, whole (`all`), one section, or — with no section — a
    /// compact overview a model can read without the multi-megabyte collected
    /// data: settings, groups, platforms, and counts for the rest.
    func mcpSnapshot(section: String?) -> [String: Any]? {
        let snapshot = webSnapshot()
        guard let section = section?.trimmingCharacters(in: .whitespacesAndNewlines), !section.isEmpty else {
            return Self.mcpOverview(of: snapshot)
        }
        if section == "all" { return snapshot }
        let parts = section.split(separator: ".", maxSplits: 1).map(String.init)
        guard let value = snapshot[parts[0]] else { return nil }
        if parts.count == 1 { return [parts[0]: value] }
        guard let container = value as? [String: Any], let inner = container[parts[1]] else { return nil }
        return [section: inner]
    }

    static func mcpOverview(of snapshot: [String: Any]) -> [String: Any] {
        let assets = snapshot["assets"] as? [String: Any] ?? [:]
        var counts: [String: Int] = [:]
        for (key, value) in assets {
            if let array = value as? [Any] { counts[key] = array.count }
            else if let dictionary = value as? [String: Any] { counts[key] = dictionary.count }
        }
        return [
            "workspace": snapshot["workspace"] ?? NSNull(),
            "issue": snapshot["issue"] ?? NSNull(),
            "notices": snapshot["notices"] ?? NSNull(),
            "settings": snapshot["settings"] ?? NSNull(),
            "classifierTypes": assets["classifierTypes"] ?? [],
            "collectionPlatforms": assets["collectionPlatforms"] ?? [],
            "bindings": assets["bindings"] ?? [],
            "assetCounts": counts,
            "sections": mcpSnapshotSections + ["all", "assets.<key>"],
        ]
    }

    /// Runs one web action exactly as the page would (same validation, same
    /// bounds) and reports the page's issue text afterwards.
    func mcpPerform(action: String, data: [String: Any]) -> ClassifierMCPActionOutcome {
        let rerender = performWebAction(action, data: data)
        return .init(rerender: rerender, issue: issue)
    }
}
