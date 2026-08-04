import Foundation

/// A precomputed, JavaScript-free description of what to shield for one block
/// group. The main app builds this (it can run the JS runtime); the
/// DeviceActivityMonitor extension only reads it and applies shields, staying
/// well within the extension's memory budget.
public struct EnforcementPlanEntry: Codable, Equatable, Sendable {
    public var groupID: String
    public var name: String
    public var mode: BlockingMode
    public var weekdays: Set<Weekday>
    public var windows: [TimeWindow]
    public var allowedMinutes: Int
    public var thresholdMinutes: Int?
    public var applicationTargetIDs: Set<String>
    public var categoryTargetIDs: Set<String>
    public var webDomainTargetIDs: Set<String>
    public var shieldTitle: String
    public var shieldMessage: String
    /// Custom-rule groups cannot be fully resolved without the JS runtime.
    /// The extension applies their static targets but leaves nuanced logic to
    /// the app, which refreshes the plan whenever it runs.
    public var requiresHostEvaluation: Bool

    public init(
        groupID: String,
        name: String,
        mode: BlockingMode,
        weekdays: Set<Weekday>,
        windows: [TimeWindow],
        allowedMinutes: Int,
        thresholdMinutes: Int?,
        applicationTargetIDs: Set<String>,
        categoryTargetIDs: Set<String>,
        webDomainTargetIDs: Set<String>,
        shieldTitle: String,
        shieldMessage: String,
        requiresHostEvaluation: Bool
    ) {
        self.groupID = groupID
        self.name = name
        self.mode = mode
        self.weekdays = weekdays
        self.windows = windows
        self.allowedMinutes = allowedMinutes
        self.thresholdMinutes = thresholdMinutes
        self.applicationTargetIDs = applicationTargetIDs
        self.categoryTargetIDs = categoryTargetIDs
        self.webDomainTargetIDs = webDomainTargetIDs
        self.shieldTitle = shieldTitle
        self.shieldMessage = shieldMessage
        self.requiresHostEvaluation = requiresHostEvaluation
    }

    public var allTargetIDs: Set<String> {
        applicationTargetIDs.union(categoryTargetIDs).union(webDomainTargetIDs)
    }
}

public struct EnforcementPlan: Codable, Equatable, Sendable {
    public var generatedAt: Date
    public var entries: [EnforcementPlanEntry]

    public init(generatedAt: Date = Date(), entries: [EnforcementPlanEntry] = []) {
        self.generatedAt = generatedAt
        self.entries = entries
    }

    public func entry(forGroupID groupID: String) -> EnforcementPlanEntry? {
        entries.first { $0.groupID == groupID }
    }
}

public enum EnforcementPlanBuilder {
    /// Rebuilds a plan straight from a raw `web-store.json` blob (the editor's
    /// chrome.storage snapshot), merging natively-assigned targets. This is the
    /// single derivation every writer of `web-store.json` funnels through, so the
    /// enforcement plan can never drift between the WebView persist path and the
    /// native `GroupStore`. Returns nil only if the blob can't be parsed.
    public static func build(
        fromWebStoreData data: Data,
        nativeTargetsByGroup: [String: [BlockTarget]],
        generatedAt: Date = Date()
    ) -> EnforcementPlan? {
        guard let result = try? ChromeExtensionImporter.importGroups(from: data) else { return nil }
        return build(from: result.groups, nativeTargetsByGroup: nativeTargetsByGroup, generatedAt: generatedAt)
    }

    /// Builds a plan, merging any natively-assigned targets (app/category
    /// tokens the web editor can't express) into each group by ID.
    public static func build(
        from groups: [BlockGroup],
        nativeTargetsByGroup: [String: [BlockTarget]],
        generatedAt: Date = Date()
    ) -> EnforcementPlan {
        let merged = groups.map { group -> BlockGroup in
            guard let extra = nativeTargetsByGroup[group.id], !extra.isEmpty else {
                return group
            }
            var copy = group
            let existingIDs = Set(group.targets.map(\.id))
            copy.targets.append(contentsOf: extra.filter { !existingIDs.contains($0.id) })
            return copy
        }
        return build(from: merged, generatedAt: generatedAt)
    }

    public static func build(from groups: [BlockGroup], generatedAt: Date = Date()) -> EnforcementPlan {
        let entries = groups
            .filter { $0.enabled }
            .map { group -> EnforcementPlanEntry in
                let appIDs = targetIDs(in: group, kinds: [.application, .legacyPlatform])
                let categoryIDs = targetIDs(in: group, kinds: [.category])
                let webIDs = targetIDs(in: group, kinds: [.webDomain, .urlPattern])
                let message = group.fallbackMessage.isEmpty
                    ? "\(group.name) is blocked."
                    : group.fallbackMessage
                return EnforcementPlanEntry(
                    groupID: group.id,
                    name: group.name,
                    mode: group.mode,
                    weekdays: group.activeDays,
                    windows: group.timeWindows,
                    allowedMinutes: group.allowedMinutes,
                    thresholdMinutes: group.mode.isTimed ? group.allowedMinutes : nil,
                    applicationTargetIDs: appIDs,
                    categoryTargetIDs: categoryIDs,
                    webDomainTargetIDs: webIDs,
                    shieldTitle: group.name,
                    shieldMessage: message,
                    requiresHostEvaluation: group.groupType == .custom
                )
            }
        return EnforcementPlan(generatedAt: generatedAt, entries: entries)
    }

    private static func targetIDs(in group: BlockGroup, kinds: Set<BlockTarget.Kind>) -> Set<String> {
        Set(group.targets.filter { kinds.contains($0.kind) }.map(\.id))
    }
}
