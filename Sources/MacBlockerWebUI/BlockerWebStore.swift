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

    /// Bridges the editor's stored `blockedGroups` into the typed core model.
    public func importedGroups() -> ChromeExtensionImportResult? {
        guard let data = shared.readData(SharedAppGroupStore.webStoreFileName) else {
            return nil
        }
        return try? ChromeExtensionImporter.importGroups(from: data)
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
