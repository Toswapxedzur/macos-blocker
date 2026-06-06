import Foundation
import MacBlockerCore

#if os(iOS)
import ManagedSettings

/// Applies shields to a `ManagedSettingsStore` by resolving the precomputed
/// `EnforcementPlan` target IDs into FamilyControls tokens. Used by both the
/// main app and the DeviceActivityMonitor extension.
public struct ScreenTimeEnforcer {
    private let store: ManagedSettingsStore

    public init(storeName: String = "macosBlocker") {
        self.store = ManagedSettingsStore(named: ManagedSettingsStore.Name(rawValue: storeName))
    }

    /// Shields a single group's targets (called from `intervalDidStart` /
    /// `eventDidReachThreshold` with the activity == groupID).
    public func applyShield(
        forGroupID groupID: String,
        plan: EnforcementPlan,
        tokens: ScreenTimeTokenSet
    ) {
        guard let entry = plan.entry(forGroupID: groupID) else {
            return
        }
        applyShield(entry: entry, tokens: tokens)
    }

    public func applyShield(entry: EnforcementPlanEntry, tokens: ScreenTimeTokenSet) {
        let apps = resolve(entry.applicationTargetIDs, in: tokens.applications)
        let categories = resolve(entry.categoryTargetIDs, in: tokens.categories)
        let webDomains = resolve(entry.webDomainTargetIDs, in: tokens.webDomains)

        if !apps.isEmpty {
            store.shield.applications = apps
        }
        if !categories.isEmpty {
            store.shield.applicationCategories = .specific(categories)
        }
        if !webDomains.isEmpty {
            store.shield.webDomains = webDomains
        }
    }

    /// Applies every entry in the plan at once (e.g. an app foreground refresh).
    public func applyAll(plan: EnforcementPlan, tokens: ScreenTimeTokenSet) {
        var apps: Set<ApplicationToken> = []
        var categories: Set<ActivityCategoryToken> = []
        var webDomains: Set<WebDomainToken> = []

        for entry in plan.entries {
            apps.formUnion(resolve(entry.applicationTargetIDs, in: tokens.applications))
            categories.formUnion(resolve(entry.categoryTargetIDs, in: tokens.categories))
            webDomains.formUnion(resolve(entry.webDomainTargetIDs, in: tokens.webDomains))
        }

        store.shield.applications = apps.isEmpty ? nil : apps
        store.shield.applicationCategories = categories.isEmpty ? nil : .specific(categories)
        store.shield.webDomains = webDomains.isEmpty ? nil : webDomains
    }

    public func clear() {
        store.clearAllSettings()
    }

    private func resolve<Token>(
        _ targetIDs: Set<String>,
        in map: [String: Token]
    ) -> Set<Token> where Token: Hashable {
        Set(targetIDs.compactMap { map[$0] })
    }
}
#endif
