import AppKit
import Foundation
import VaultClassifierCore
import VaultClassifierBridge
import VaultClassifierLLM

// Collection platforms, classifier types (create/reorder/configure/activate/delete via preset), the trash, collection diagnostics and the native confirmation sheet they share.
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

    func addCollectionPlatform(platformID: String) {
        do {
            guard let definition = CollectionPlatformRegistry.definition(for: platformID),
                  var catalog = localState?.workspaceCatalog else {
                throw WebBridgeInputError.invalidChoice("collection platform")
            }
            guard !catalog.bindings.contains(where: { $0.id == definition.id }) else {
                throw WebBridgeInputError.invalidChoice("collection platform already exists")
            }
            _ = try catalog.ensurePlatformBinding(definition.id)
            try coordinator?.updateWorkspaceCatalog(catalog)
            refreshLocalState()
            issue = nil
        } catch { issue = error.localizedDescription }
    }

    func deleteCollectionPlatform(platformID: String) {
        do {
            guard var catalog = localState?.workspaceCatalog,
                  catalog.trashCollectionPlatform(platformID) != nil else {
                throw WebBridgeInputError.invalidChoice("collection platform")
            }
            try coordinator?.updateWorkspaceCatalog(catalog)
            refreshLocalState()
            issue = nil
        } catch { issue = error.localizedDescription }
    }

    func confirmCollectionPlatformDeletion(platformID: String) {
        guard let catalog = localState?.workspaceCatalog,
              let binding = catalog.bindings.first(where: { $0.id == platformID }) else {
            issue = WebBridgeInputError.invalidChoice("collection platform").localizedDescription
            return
        }
        let dataset = catalog.datasets.first(where: { $0.id == binding.datasetID })
        let entries = dataset?.collectedEntries.filter { $0.platformID == platformID }.count ?? 0
        presentNativeConfirmation(
            title: "Delete \(binding.name)?",
            message: "This stops collection and removes \(entries) retained entries for this platform. Shared trees and classification data remain.",
            confirmTitle: "Delete platform"
        ) { [weak self] in
            self?.deleteCollectionPlatform(platformID: platformID)
        }
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

    func clearCollectionDiagnostics() {
        collectionDiagnostics?.clear()
        onWebStateChange?()
    }

    /// Creates a classifier type (a "group") for one platform. It starts with an
    /// empty tree of its own and follows the global dials, house rules and
    /// research switch until the person gives it positions of its own.
    func createClassifierType(name: String, platformID: String) {
        do {
            let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty,
                  cleaned.count <= ClassifierTypeAsset.maximumNameLength,
                  CollectionPlatformRegistry.definition(for: platformID) != nil,
                  var catalog = localState?.workspaceCatalog else {
                throw WebBridgeInputError.invalidChoice("classifier type")
            }
            // Every platform is collectable by default; make sure its binding (the
            // shared dataset + collection toggle) exists before binding the type.
            let binding = try catalog.ensurePlatformBinding(platformID)
            guard let dataset = catalog.datasets.first(where: { $0.id == binding.datasetID }) else {
                throw WebBridgeInputError.invalidChoice("classifier type")
            }
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
                applicablePlatformID: platformID,
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
        applicablePlatformID: String
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
            guard CollectionPlatformRegistry.definition(for: applicablePlatformID) != nil else {
                throw WebBridgeInputError.invalidChoice("classifier type")
            }
            // A platform belongs to at most one classifier type. Refuse the
            // assignment outright — updateWorkspaceCatalog reconciles before it
            // validates, which would otherwise silently unbind one of the two —
            // so the owner sees exactly why it was not applied.
            if catalog.classifierTypes.contains(where: { $0.id != typeID && $0.applicablePlatformID == applicablePlatformID }) {
                throw WorkspaceCatalogError.duplicateApplicablePlatform(applicablePlatformID)
            }
            let selectedBinding = try catalog.ensurePlatformBinding(applicablePlatformID)
            guard
                  // A type owns its own tree; the binding only supplies the shared
                  // dataset and the platform.
                  let tree = catalog.trees.first(where: { $0.id == existingClassifierType.treeID }),
                  let dataset = catalog.datasets.first(where: { $0.id == selectedBinding.datasetID }) else {
                throw WebBridgeInputError.invalidChoice("classifier type")
            }
            catalog.classifierTypes[typeIndex] = .init(
                id: catalog.classifierTypes[typeIndex].id,
                name: cleanedName,
                treeID: tree.id,
                treeRevision: tree.revision,
                datasetID: dataset.id,
                datasetRevision: dataset.revision,
                applicablePlatformID: selectedBinding.id,
                localModelOverrides: existingClassifierType.localModelOverrides,
                researchEnabled: existingClassifierType.researchEnabled,
                order: catalog.classifierTypes[typeIndex].order
            )
            try coordinator?.updateWorkspaceCatalog(catalog)
            refreshLocalState()
            issue = nil
        } catch { issue = error.localizedDescription }
    }

    func setActiveClassifierType(platformID: String, classifierTypeID: String?) {
        do {
            guard var catalog = localState?.workspaceCatalog,
                  let bindingIndex = catalog.bindings.firstIndex(where: { $0.id == platformID }),
                  let tree = catalog.trees.first(where: { $0.id == catalog.bindings[bindingIndex].treeID }),
                  let dataset = catalog.datasets.first(where: { $0.id == catalog.bindings[bindingIndex].datasetID }) else {
                throw WebBridgeInputError.invalidChoice("classifier type")
            }
            let normalizedTypeID = classifierTypeID?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let normalizedTypeID, !normalizedTypeID.isEmpty else {
                catalog.bindings[bindingIndex].activeClassifierTypeID = nil
                try coordinator?.updateWorkspaceCatalog(catalog)
                refreshLocalState()
                issue = nil
                return
            }
            guard let classifierType = catalog.classifierTypes.first(where: { $0.id == normalizedTypeID }),
                  classifierType.treeID == tree.id,
                  classifierType.treeRevision == tree.revision,
                  classifierType.datasetID == dataset.id,
                  classifierType.datasetRevision == dataset.revision,
                  classifierType.applicablePlatformID == platformID else {
                throw WebBridgeInputError.invalidChoice("classifier type")
            }
            catalog.bindings[bindingIndex].activeClassifierTypeID = normalizedTypeID
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

    func confirmClassifierTypeDeletion(typeID: String) {
        guard localState?.workspaceCatalog.classifierTypes.contains(where: { $0.id == typeID }) == true else {
            issue = WebBridgeInputError.invalidChoice("classifier type").localizedDescription
            return
        }
        presentNativeConfirmation(
            title: "Delete classifier type?",
            message: "This removes this local decision configuration. Other data and provider profiles are retained.",
            confirmTitle: "Delete classifier type"
        ) { [weak self] in
            self?.deleteClassifierType(typeID: typeID)
        }
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
