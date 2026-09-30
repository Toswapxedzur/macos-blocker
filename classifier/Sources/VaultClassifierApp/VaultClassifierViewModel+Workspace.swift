import AppKit
import Foundation
import VaultClassifierCore
import VaultClassifierBridge
import VaultClassifierLLM

// Collection platforms, classifier types (create/reorder/configure/activate/delete), the trash, collection diagnostics and the native confirmation sheet they share.
// Split out of VaultClassifierApp.swift (CLASSIFIER-INDEPENDENCE §7, Phase 5):
// same type, same behaviour — pinned by ViewModelCharacterizationTests.
@MainActor
extension VaultClassifierViewModel {
    /// Copies a valid retired Keychain credential into the provider's ordinary
    /// workspace field, then deletes the old Keychain item. Existing plain
    /// workspace values take precedence.
    /// Opportunistic trash purge: on launch, drop entries whose 24h lifetime
    /// has elapsed. There is no background timer.
    func purgeExpiredTrashOnLaunch() {
        guard var catalog = localState?.workspaceCatalog, !catalog.trash.isEmpty else { return }
        guard catalog.purgeExpiredTrash() > 0 else { return }
        try? coordinator?.updateWorkspaceCatalog(catalog)
        localState = coordinator?.snapshot()
    }

    /// A type's Options: "Delete collected data" — the platform's collected
    /// entries go to the trash (restorable for a day); the platform and its
    /// type stay.
    func clearCollectedData(platformID: String) {
        do {
            guard var catalog = localState?.workspaceCatalog,
                  catalog.trashCollectedEntries(platformID) != nil else {
                throw WebBridgeInputError.invalidChoice("collection platform")
            }
            try coordinator?.updateWorkspaceCatalog(catalog)
            refreshLocalState()
            issue = nil
        } catch { issue = error.localizedDescription }
    }

    /// The Collection page's Keep: a platform's (`platformID`; -1 = the same
    /// as all) or, without one, the Keep for all platforms. Entries past it go now.
    func setCollectionKeep(platformID: String?, days: Int) {
        do {
            guard var catalog = localState?.workspaceCatalog else { throw WebBridgeInputError.invalidChoice("collection keep") }
            if let platformID {
                guard days >= -1, let index = catalog.bindings.firstIndex(where: { $0.id == platformID }) else {
                    throw WebBridgeInputError.invalidChoice("collection platform")
                }
                catalog.bindings[index].collectionKeepDays = days
            } else {
                guard days >= 0 else { throw WebBridgeInputError.invalidChoice("collection keep") }
                catalog.collectionKeepDays = days
            }
            catalog.pruneCollectedEntries()
            try coordinator?.updateWorkspaceCatalog(catalog)
            refreshLocalState()
            issue = nil
        } catch { issue = error.localizedDescription }
    }

    func setCollectionEnabled(platformID: String, enabled: Bool) {
        do {
            guard var catalog = localState?.workspaceCatalog,
                  let bindingIndex = catalog.bindings.firstIndex(where: { $0.id == platformID }) else {
                throw WebBridgeInputError.invalidChoice("collection platform")
            }
            catalog.bindings[bindingIndex].collectionEnabled = enabled
            try coordinator?.updateWorkspaceCatalog(catalog)
            refreshLocalState()
            issue = nil
        } catch { issue = error.localizedDescription }
    }

    /// The platforms a type may take (owner 2026-09-30): classifiable ones only,
    /// each once, none held by another type (a platform belongs to at most one
    /// type — refused here so the owner sees why, rather than reconciled away).
    /// Makes sure each has its binding; returns them with the shared dataset.
    private func claimPlatforms(
        _ ids: [String],
        forType typeID: String?,
        in catalog: inout WorkspaceCatalog
    ) throws -> (ids: [String], dataset: ClassificationDataset) {
        let cleaned = ClassifierTypeAsset.cleanedPlatformIDs(ids)
        var datasetID = catalog.datasets.first?.id
        for platformID in cleaned {
            guard CollectionPlatformRegistry.definition(for: platformID)?.supportsLocalModel == true else {
                throw WebBridgeInputError.invalidChoice("platform")
            }
            if catalog.classifierTypes.contains(where: { $0.id != typeID && $0.applicablePlatformIDs.contains(platformID) }) {
                throw WorkspaceCatalogError.duplicateApplicablePlatform(platformID)
            }
            datasetID = try catalog.ensurePlatformBinding(platformID).datasetID
        }
        guard let dataset = catalog.datasets.first(where: { $0.id == datasetID }) else {
            throw WebBridgeInputError.invalidChoice("classifier type")
        }
        return (cleaned, dataset)
    }

    /// Creates a classifier type (a "group") for the chosen platforms. It starts
    /// with an empty tree of its own and follows the global dials, house rules
    /// and research switch until the person gives it positions of its own.
    func createClassifierType(name: String, platformIDs: [String]) {
        do {
            let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty,
                  cleaned.count <= ClassifierTypeAsset.maximumNameLength,
                  var catalog = localState?.workspaceCatalog else {
                throw WebBridgeInputError.invalidChoice("classifier type")
            }
            let (platforms, dataset) = try claimPlatforms(platformIDs, forType: nil, in: &catalog)
            // Each type owns a fresh, empty tree — its own taxonomy.
            let tree = TagTreeAsset(name: cleaned, nodes: [])
            catalog.trees.append(tree)
            let nextOrder = (catalog.classifierTypes.map(\.order).max() ?? -1) + 1
            catalog.classifierTypes.append(.init(
                name: cleaned,
                treeID: tree.id,
                treeRevision: tree.revision,
                datasetID: dataset.id,
                datasetRevision: dataset.revision,
                applicablePlatformIDs: platforms,
                order: nextOrder
            ))
            try coordinator?.updateWorkspaceCatalog(catalog)
            refreshLocalState()
            issue = nil
        } catch { issue = error.localizedDescription }
    }

    /// Rewrites the reorderable list positions from the order the person dragged
    /// them into. Unknown ids are ignored; omitted types keep their position.
    func reorderClassifierTypes(orderedIDs: [String]) {
        do {
            guard var catalog = localState?.workspaceCatalog else {
                throw WebBridgeInputError.invalidChoice("classifier type order")
            }
            var rank: [String: Int] = [:]
            for (index, id) in orderedIDs.enumerated() { rank[id] = index }
            for index in catalog.classifierTypes.indices {
                if let position = rank[catalog.classifierTypes[index].id] {
                    catalog.classifierTypes[index].order = position
                }
            }
            try coordinator?.updateWorkspaceCatalog(catalog)
            refreshLocalState()
            issue = nil
        } catch { issue = error.localizedDescription }
    }

    func configureClassifierType(
        typeID: String,
        name: String,
        applicablePlatformIDs: [String]
    ) {
        do {
            let cleanedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanedName.isEmpty,
                  cleanedName.count <= ClassifierTypeAsset.maximumNameLength,
                  var catalog = localState?.workspaceCatalog,
                  let typeIndex = catalog.classifierTypes.firstIndex(where: { $0.id == typeID }) else {
                throw WebBridgeInputError.invalidChoice("classifier type")
            }
            let existingClassifierType = catalog.classifierTypes[typeIndex]
            // A platform belongs to at most one classifier type; claimPlatforms
            // refuses outright — updateWorkspaceCatalog reconciles before it
            // validates, which would otherwise silently unbind one of the two.
            let (platforms, dataset) = try claimPlatforms(applicablePlatformIDs, forType: typeID, in: &catalog)
            // A type owns its own tree; the bindings only supply the shared
            // dataset and the platforms.
            guard let tree = catalog.trees.first(where: { $0.id == existingClassifierType.treeID }) else {
                throw WebBridgeInputError.invalidChoice("classifier type")
            }
            catalog.classifierTypes[typeIndex] = .init(
                id: catalog.classifierTypes[typeIndex].id,
                name: cleanedName,
                treeID: tree.id,
                treeRevision: tree.revision,
                datasetID: dataset.id,
                datasetRevision: dataset.revision,
                applicablePlatformIDs: platforms,
                localModelOverrides: existingClassifierType.localModelOverrides,
                researchEnabled: existingClassifierType.researchEnabled,
                order: catalog.classifierTypes[typeIndex].order
            )
            try coordinator?.updateWorkspaceCatalog(catalog)
            refreshLocalState()
            issue = nil
        } catch { issue = error.localizedDescription }
    }

    func deleteClassifierType(typeID: String) {
        do {
            guard var catalog = localState?.workspaceCatalog,
                  catalog.trashClassifierType(typeID) != nil else {
                throw WebBridgeInputError.invalidChoice("classifier type")
            }
            try coordinator?.updateWorkspaceCatalog(catalog)
            refreshLocalState()
            issue = nil
        } catch { issue = error.localizedDescription }
    }

    func restoreTrashedEntry(entryID: String) {
        do {
            guard var catalog = localState?.workspaceCatalog,
                  catalog.restoreTrashedEntry(entryID) else {
                throw WebBridgeInputError.invalidChoice("trash entry")
            }
            try coordinator?.updateWorkspaceCatalog(catalog)
            refreshLocalState()
            issue = nil
        } catch { issue = error.localizedDescription }
    }

    func permanentlyDeleteTrashedEntry(entryID: String) {
        do {
            guard var catalog = localState?.workspaceCatalog,
                  catalog.permanentlyDeleteTrashedEntry(entryID) else {
                throw WebBridgeInputError.invalidChoice("trash entry")
            }
            try coordinator?.updateWorkspaceCatalog(catalog)
            refreshLocalState()
            issue = nil
        } catch { issue = error.localizedDescription }
    }

    func presentNativeConfirmation(
        title: String,
        message: String,
        confirmTitle: String,
        action: @escaping () -> Void
    ) {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) else {
            issue = WebBridgeInputError.invalidChoice("application window").localizedDescription
            return
        }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        alert.beginSheetModal(for: window) { [weak self] response in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard response == .alertFirstButtonReturn else { return }
                action()
                self.onWebStateChange?()
            }
        }
    }
}
