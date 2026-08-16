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
            "platformLocked": true, "decisionPriority": "humanFirst", "order": 0,
        ]
        let type = try JSONDecoder().decode(ClassifierTypeAsset.self, from: JSONSerialization.data(withJSONObject: legacy))
        let encoded = String(decoding: try JSONEncoder().encode(type), as: UTF8.self)
        XCTAssertFalse(encoded.contains("platformLocked"))
        XCTAssertFalse(encoded.contains("decisionPriority"))
    }

    func testClassifierTypeLocalModelOverridesLegacyAndRoundTrip() throws {
        let legacy = Data(#"{"id":"type","name":"Type","treeID":"tree","treeRevision":1,"datasetID":"dataset","datasetRevision":1,"applicablePlatformID":"youtube","order":0}"#.utf8)
        let decodedLegacy = try JSONDecoder().decode(ClassifierTypeAsset.self, from: legacy)
        XCTAssertNil(decodedLegacy.localModelOverrides)

        let value = ClassifierTypeAsset(
            id: "type", name: "Type", treeID: "tree", treeRevision: 1,
            datasetID: "dataset", datasetRevision: 1, applicablePlatformID: "youtube",
            localModelOverrides: .init(
                houseRules: "Prefer documentaries.",
                allowDecline: false,
                confidenceThresholds: [0.1, 0.3, 0.6, 0.9]
            )
        )
        let roundTrip = try JSONDecoder().decode(ClassifierTypeAsset.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(roundTrip.localModelOverrides, value.localModelOverrides)
    }

    func testLLMAssistConfigurationDiscardsRetiredActivationFlag() throws {
        let legacy = Data(#"{"providerProfileID":"provider","modelIdentifier":"model","isActive":true}"#.utf8)
        let configuration = try JSONDecoder().decode(LLMAssistConfiguration.self, from: legacy)
        XCTAssertEqual(configuration.providerProfileID, "provider")
        XCTAssertEqual(configuration.modelIdentifier, "model")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(configuration), as: UTF8.self).contains("isActive"))
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
