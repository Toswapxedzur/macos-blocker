import AppKit
import Foundation
import VaultClassifierCore
import VaultClassifierBridge
import VaultClassifierLLM

// Collection platforms, classifier types (create/reorder/configure/activate/delete), collection diagnostics and the native confirmation sheet they share.
// Split out of VaultClassifierApp.swift (CLASSIFIER-INDEPENDENCE §7, Phase 5):
// same type, same behaviour — pinned by ViewModelCharacterizationTests.
@MainActor
extension VaultClassifierViewModel {
    /// Permanently clears the platform's collected entries; its binding and
    /// classifier group stay.
    func clearCollectedData(platformID: String) {
        do {
            guard var catalog = localState?.workspaceCatalog,
                  catalog.clearCollectedEntries(platformID) else {
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
        guard !cleaned.isEmpty else { throw WebBridgeInputError.noPlatformsSelected }
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
            throw WebBridgeInputError.invalidChoice("Classifier group")
        }
        return (cleaned, dataset)
    }

    /// Creates a classifier type (a "group") for the chosen platforms. It starts
    /// with an empty tree and independent Balanced dials and empty house rules
    /// and follows the app-wide research consent.
    func createClassifierType(name: String, platformIDs: [String]) {
        do {
            let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty,
                  cleaned.count <= ClassifierTypeAsset.maximumNameLength,
                  var catalog = localState?.workspaceCatalog else {
                throw WebBridgeInputError.invalidChoice("Classifier group")
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
                throw WebBridgeInputError.invalidChoice("Classifier group order")
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

    func configureClassifierType(typeID: String, name: String) {
        do {
            let cleanedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanedName.isEmpty,
                  cleanedName.count <= ClassifierTypeAsset.maximumNameLength,
                  var catalog = localState?.workspaceCatalog,
                  let typeIndex = catalog.classifierTypes.firstIndex(where: { $0.id == typeID }) else {
                throw WebBridgeInputError.invalidChoice("Classifier group")
            }
            catalog.classifierTypes[typeIndex].name = cleanedName
            catalog.classifierTypes[typeIndex].updatedAtMilliseconds = WorkspaceCatalog.now()
            try coordinator?.updateWorkspaceCatalog(catalog)
            refreshLocalState()
            issue = nil
        } catch { issue = error.localizedDescription }
    }

    func deleteClassifierType(typeID: String) {
        do {
            guard var catalog = localState?.workspaceCatalog,
                  catalog.removeClassifierType(typeID) else {
                throw WebBridgeInputError.invalidChoice("Classifier group")
            }
            try coordinator?.updateWorkspaceCatalog(catalog)
            refreshLocalState()
            issue = nil
        } catch { issue = error.localizedDescription }
    }

}
