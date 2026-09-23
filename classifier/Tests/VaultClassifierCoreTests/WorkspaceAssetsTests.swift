import Foundation
import XCTest
@testable import VaultClassifierCore

final class WorkspaceAssetsTests: XCTestCase {
    func testEveryRegisteredPlatformCanHaveACollectionBinding() throws {
        var catalog = WorkspaceCatalog.starter()
        for definition in CollectionPlatformRegistry.definitions {
            let binding = try catalog.ensurePlatformBinding(definition.id)
            XCTAssertEqual(binding.id, definition.id)
            XCTAssertTrue(binding.collectionEnabled)
        }
    }

    func testCreatorIdentityIndexMergesCollectedAliases() {
        let handle = "youtube:handle:@creator"
        let channel = "youtube:channel:UC123"
        let entry = CollectedPlatformEntry(
            id: "entry", platformID: "youtube", entryID: "youtube:video:1",
            creatorID: channel, sourceAliases: [handle], creatorName: "Creator",
            entryType: "video", title: "Video"
        )
        let index = CreatorIdentityIndex(entries: [entry])
        XCTAssertEqual(index.members(of: channel), Set([handle, channel]))
        XCTAssertEqual(index.canonical(of: channel), handle)
    }

    func testDatasetDiscardsRetiredCreatorClassifications() throws {
        let legacy = Data(#"{"id":"dataset","name":"Data","revision":2,"collectedEntries":[],"creatorClassifications":[{"id":"old"}]}"#.utf8)
        let dataset = try JSONDecoder().decode(ClassificationDataset.self, from: legacy)
        XCTAssertEqual(dataset.id, "dataset")
        XCTAssertTrue(dataset.collectedEntries.isEmpty)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(dataset), as: UTF8.self).contains("creatorClassifications"))
    }

    func testRetiredClassifierTypeFieldsAreNotReencoded() throws {
        let tree = WorkspaceCatalog.starter().trees[0]
        let dataset = WorkspaceCatalog.starter().datasets[0]
        let legacy: [String: Any] = [
            "id": "type", "name": "Type", "treeID": tree.id,
            "treeRevision": tree.revision, "datasetID": dataset.id,
            "datasetRevision": dataset.revision, "applicablePlatformID": "youtube",
            "localModelID": "retired-model",
            "selectedLLMProviderProfileID": "retired-provider",
            "llmAssistDraftConfiguration": ["retired": true],
            "llmAssistConfiguration": ["retired": true],
            "llmProfileIDs": ["retired-provider"],
            "platformLocked": true, "decisionPriority": "humanFirst", "order": 0,
        ]
        let type = try JSONDecoder().decode(ClassifierTypeAsset.self, from: JSONSerialization.data(withJSONObject: legacy))
        let encoded = String(decoding: try JSONEncoder().encode(type), as: UTF8.self)
        for retiredKey in [
            "localModelID", "selectedLLMProviderProfileID", "llmAssistDraftConfiguration",
            "llmAssistConfiguration", "llmProfileIDs", "platformLocked", "decisionPriority",
        ] {
            XCTAssertFalse(encoded.contains(retiredKey), "Retired key was re-encoded: \(retiredKey)")
        }
    }

    /// A platform belongs to at most one classifier type: the classify path runs
    /// every type whose applicablePlatformID matches, so two types on one platform
    /// double all engine work. validate() asserts it; reconcile repairs stale
    /// state by UNBINDING extras (never deleting), the binding's chosen type first.
    func testAPlatformBelongsToAtMostOneClassifierType() throws {
        var catalog = WorkspaceCatalog.starter()
        let binding = try catalog.ensurePlatformBinding("youtube")
        let tree = try XCTUnwrap(catalog.trees.first { $0.id == binding.treeID })
        let dataset = try XCTUnwrap(catalog.datasets.first { $0.id == binding.datasetID })
        let make = { (id: String) in
            ClassifierTypeAsset(
                id: id, name: id, treeID: tree.id, treeRevision: tree.revision,
                datasetID: dataset.id, datasetRevision: dataset.revision, applicablePlatformID: "youtube")
        }
        catalog.classifierTypes = [make("first"), make("second")]
        let bindingIndex = try XCTUnwrap(catalog.bindings.firstIndex { $0.id == "youtube" })

        XCTAssertThrowsError(try catalog.validate()) { error in
            XCTAssertEqual(error as? WorkspaceCatalogError, .duplicateApplicablePlatform("youtube"))
        }

        // The binding's chosen active type keeps the platform; the other is unbound, not deleted.
        var chosen = catalog
        chosen.bindings[bindingIndex].activeClassifierTypeID = "second"
        chosen.reconcileClassifierTypes()
        XCTAssertEqual(chosen.classifierTypes.map(\.id), ["first", "second"], "no type is deleted")
        XCTAssertNil(chosen.classifierTypes.first { $0.id == "first" }?.applicablePlatformID)
        XCTAssertEqual(chosen.classifierTypes.first { $0.id == "second" }?.applicablePlatformID, "youtube")
        XCTAssertEqual(chosen.bindings[bindingIndex].activeClassifierTypeID, "second")
        XCTAssertNoThrow(try chosen.validate())

        // With no chosen type the first claimant wins and becomes the sole, auto-selected type.
        var unchosen = catalog
        unchosen.reconcileClassifierTypes()
        XCTAssertEqual(unchosen.classifierTypes.first { $0.id == "first" }?.applicablePlatformID, "youtube")
        XCTAssertNil(unchosen.classifierTypes.first { $0.id == "second" }?.applicablePlatformID)
        XCTAssertEqual(unchosen.bindings[bindingIndex].activeClassifierTypeID, "first")
        XCTAssertNoThrow(try unchosen.validate())
    }

    func testClassifierTypeLocalModelOverridesLegacyAndRoundTrip() throws {
        let legacy = Data(#"{"id":"type","name":"Type","treeID":"tree","treeRevision":1,"datasetID":"dataset","datasetRevision":1,"applicablePlatformID":"youtube","order":0}"#.utf8)
        let decodedLegacy = try JSONDecoder().decode(ClassifierTypeAsset.self, from: legacy)
        XCTAssertNil(decodedLegacy.localModelOverrides)
        XCTAssertNil(decodedLegacy.modelFileName)
        XCTAssertNil(decodedLegacy.researchEnabled)

        let value = ClassifierTypeAsset(
            id: "type", name: "Type", treeID: "tree", treeRevision: 1,
            datasetID: "dataset", datasetRevision: 1, applicablePlatformID: "youtube",
            localModelOverrides: .init(houseRules: "Prefer documentaries.", speedQuality: .best, strictness: .strict),
            researchEnabled: false
        )
        let roundTrip = try JSONDecoder().decode(ClassifierTypeAsset.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(roundTrip.localModelOverrides, value.localModelOverrides)
        XCTAssertEqual(roundTrip.modelFileName, "Qwen2.5-14B-Instruct-Q4_K_M.gguf")
        XCTAssertEqual(roundTrip.researchEnabled, false)
    }

    /// A type written before the dials (per-type model file, full research profile,
    /// preset provenance) keeps its tier and research switch; the rest is dropped.
    func testPreDialClassifierTypeDecodesToDialPositions() throws {
        let old = #"{"id":"type","name":"Type","treeID":"tree","treeRevision":1,"datasetID":"dataset","datasetRevision":1,"applicablePlatformID":"youtube","order":0,"modelFileName":"Qwen2.5-3B-Instruct-Q4_K_M.gguf","localModelOverrides":{"allowDecline":false,"maximumTags":1},"researchOverrides":{"enabled":false,"requestsPerMinute":6,"dailyTokenLimit":5000,"cooldownHours":24},"presetID":"gentle"}"#
        let decoded = try JSONDecoder().decode(ClassifierTypeAsset.self, from: Data(old.utf8))
        XCTAssertEqual(decoded.localModelOverrides, LocalModelOverrides(speedQuality: .fast, strictness: .strictest))
        XCTAssertEqual(decoded.modelFileName, "Qwen2.5-3B-Instruct-Q4_K_M.gguf")
        XCTAssertEqual(decoded.researchEnabled, false)
        let reencoded = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)
        for retired in ["presetID", "researchOverrides", "\"modelFileName\"", "allowDecline", "maximumTags"] {
            XCTAssertFalse(reencoded.contains(retired), "retired key written back: \(retired)")
        }
    }

    func testCatalogAndBindingDiscardRetiredTrainableModelFields() throws {
        let legacyCatalog = Data(#"{"models":[{"id":"retired-model","name":"Retired"}]}"#.utf8)
        let catalog = try JSONDecoder().decode(WorkspaceCatalog.self, from: legacyCatalog)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(catalog), as: UTF8.self).contains(#""models""#))

        let legacyBinding = Data(#"{"id":"youtube","name":"YouTube","treeID":"tree","datasetID":"dataset","activeModelID":"retired-model"}"#.utf8)
        let binding = try JSONDecoder().decode(PlatformBinding.self, from: legacyBinding)
        XCTAssertNil(binding.activeClassifierTypeID)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(binding), as: UTF8.self).contains("activeModelID"))
    }

    func testWorkspaceCatalogRetainsPerVideoLLMStores() throws {
        var catalog = WorkspaceCatalog.starter()
        let tree = catalog.trees[0]
        catalog.videoClassifications = [.init(
            classifierTypeID: "type", platformID: "youtube",
            entryID: "youtube:video:1", creatorID: "youtube:channel:creator",
            treeID: tree.id, treeRevision: tree.revision,
            tags: [.init(tagID: "tag", confidence: 5)],
            source: .model, modelVersion: "test"
        )]
        catalog.knowledgeEntries = [.init(kind: .term, subject: "subject", meaning: "meaning")]
        let decoded = try JSONDecoder().decode(WorkspaceCatalog.self, from: JSONEncoder().encode(catalog))
        XCTAssertEqual(decoded.videoClassifications, catalog.videoClassifications)
        XCTAssertEqual(decoded.knowledgeEntries, catalog.knowledgeEntries)
    }
}
