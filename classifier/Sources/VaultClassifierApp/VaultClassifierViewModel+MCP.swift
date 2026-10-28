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
        .init(name: "workspace", keys: ["workspace"], summary: "Switch the page's workspace (browserBridge). API connections are in Settings."),
        .init(name: "clearCollectedData", keys: ["platformID"], summary: "Permanently clear a platform's collected entries (the platform and its group stay)."),
        .init(name: "setCollectionEnabled", keys: ["platformID", "enabled"], summary: "Turn collection on/off for a platform."),
        .init(name: "setCollectionKeep", keys: ["platformID", "days"], summary: "Days to keep collected entries: for a platform (-1 = same as all), or without platformID for all platforms (0 = forever)."),
        .init(name: "createClassifierType", keys: ["name", "platformIDs"], summary: "Create a classifier group for one or more classifiable platforms (platformIDs: youtube, reddit, twitter, bilibili; a platform belongs to at most one group) with its own empty tree; choose a connected subscription or API-key model explicitly before tagging."),
        .init(name: "reorderClassifierTypes", keys: ["orderedIDs"], summary: "Reorder groups (array of group ids)."),
        .init(name: "configureClassifierType", keys: ["typeID", "name"], summary: "Rename a group. Its platforms are fixed at creation."),
        .init(name: "confirmDeleteClassifierType", keys: ["typeID"], summary: "Delete a group."),
        .init(name: "saveTaggingConnection", keys: ["type", "credential"], summary: "Save or clear the single API key for OpenAI, Gemini or Grok; preserves existing connection IDs."),
        .init(name: "createProviderProfile", keys: ["type"], summary: "Create a provider profile (gemini, openAI, anthropic, …)."),
        .init(name: "testProviderProfile", keys: ["profileID", "credential", "customEndpoint", "testModelIdentifier"], summary: "Test a provider profile's credential (stores it on success)."),
        .init(name: "updateProviderConnection", keys: ["profileID", "credential", "customEndpoint", "testModelIdentifier"], summary: "Update a provider profile's connection fields."),
        .init(name: "probeProviderModelCatalog", keys: ["profileID"], summary: "Fetch a provider's model list."),
        .init(name: "confirmDeleteProviderProfile", keys: ["profileID"], summary: "Delete a provider profile."),
        .init(name: "rearrangeTree", keys: ["treeID"], summary: "Auto-layout a tree's canvas."),
        .init(name: "addTag", keys: ["treeID", "name", "description", "parentID", "positionX", "positionY"], summary: "Add a tag (optionally under parentID) at a canvas position."),
        .init(name: "moveTag", keys: ["treeID", "nodeID", "positionX", "positionY"], summary: "Move a tag on the canvas."),
        .init(name: "renameTag", keys: ["treeID", "nodeID", "name"], summary: "Rename a tag."),
        .init(name: "updateTag", keys: ["treeID", "nodeID", "name", "description"], summary: "Rename a tag and set its description."),
        .init(name: "connectTag", keys: ["treeID", "nodeID", "parentID"], summary: "Make a tag a child of another."),
        .init(name: "disconnectTag", keys: ["treeID", "nodeID"], summary: "Detach a tag from its parent."),
        .init(name: "deleteTag", keys: ["treeID", "nodeID"], summary: "Delete a tag."),
        .init(name: "saveClassificationSettings", keys: ["classificationEnabled"], summary: "Enable or disable automatic tagging globally in the Classifier."),
        .init(name: "connectChatGPT", keys: [], summary: "Open Vault's supported ChatGPT sign-in and plan-usage consent flow in the default browser."),
        .init(name: "openChatGPTUsage", keys: [], summary: "Open ChatGPT's usage settings in the default browser."),
        .init(name: "acknowledgeChatGPTPlan", keys: [], summary: "Dismiss the first-connection explanation of ChatGPT plan usage."),
        .init(name: "cancelChatGPTSignIn", keys: [], summary: "Cancel the pending ChatGPT sign-in without signing out the active account."),
        .init(name: "disconnectChatGPT", keys: [], summary: "Remove Vault's ChatGPT credentials and cancel active cloud requests; keep cached tags."),
        .init(name: "refreshChatGPTModels", keys: [], summary: "Fetch the connected account's currently available models."),
        .init(name: "retryChatGPTClassifications", keys: [], summary: "Retry failed cloud items without enabling local fallback."),
        .init(name: "saveChatGPTUsageLimit", keys: ["dailyRequestLimit"], summary: "Optional daily ChatGPT request cap on this device, UTC day; blank has no app cap. Failed dispatched requests count."),
        .init(name: "saveClassificationProvider", keys: ["typeID", "providerModel", "reasoningEffort"], summary: "Choose one group connection/model: chatgpt:<model> for subscription or api:<profileID>:<model> for a saved OpenAI, Gemini or Grok key. Fetch its model list first. Set reasoningEffort to default, low, medium or high when supported. Search is always enabled and model-directed; no fallback."),
        .init(name: "setClassifierTypePaused", keys: ["typeID", "paused"], summary: "Pause or resume automatic tagging for a classifier group."),
        .init(name: "saveClassifierTypeTagging", keys: ["typeID", "minimumConfidence", "houseRules"], summary: "Set the minimum evidence grade (1–5) for every automatic tag in this group, including the first. Zero tags are allowed. Blank tagging instructions add no extra rules."),
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
    /// selects one asset collection (trees, datasets, classifierTypes,
    /// providerProfiles, providerProtocols, collectionPlatforms, bindings, …).
    static let mcpSnapshotSections = ["settings", "assets", "backup", "notices", "workspace", "issue"]

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
