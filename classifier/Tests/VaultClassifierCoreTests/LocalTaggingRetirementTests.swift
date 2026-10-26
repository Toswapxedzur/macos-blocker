import Foundation
import XCTest
@testable import VaultClassifierCore

final class LocalTaggingRetirementTests: XCTestCase {
    func testSchemaFourRetiresLocalGroupsAndPreservesCloudSettingsAndRows() throws {
        var state = LocalClassifierState()
        let dataset = state.workspaceCatalog.datasets[0]
        let localTree = TagTreeAsset(id: "local-tree", name: "Old", nodes: [.init(id: "old", name: "Old")])
        let cloudTree = TagTreeAsset(id: "cloud-tree", name: "Topics", nodes: [.init(id: "games", name: "Games")])
        state.workspaceCatalog.trees += [localTree, cloudTree]
        state.workspaceCatalog.classifierTypes = [localTree, cloudTree].map { tree in
            .init(id: tree.id, name: tree.name, treeID: tree.id, treeRevision: 1,
                  datasetID: dataset.id, datasetRevision: dataset.revision, applicablePlatformIDs: ["youtube"],
                  tagging: .init(strictness: .strict, houseRules: "Keep my rules", maximumTagsOverride: 2),
                  chatGPT: .init(accountID: "account", model: "selected"))
        }
        state.workspaceCatalog.videoClassifications = [localTree, cloudTree].map { tree in
            .init(classifierTypeID: tree.id, platformID: "youtube", entryID: "entry", creatorID: "creator",
                  treeID: tree.id, treeRevision: 1, tags: [], source: .humanCorrected, modelVersion: "saved")
        }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        object["schemaVersion"] = 4
        var catalog = try XCTUnwrap(object["workspaceCatalog"] as? [String: Any])
        var groups = try XCTUnwrap(catalog["classifierTypes"] as? [[String: Any]])
        groups[0]["classificationProvider"] = "local"
        groups[0]["localModel"] = ["speedQuality": ["broken": true]]
        groups[0].removeValue(forKey: "tagging")
        // Schema 4 cloud groups stored neutral controls under the old key.
        groups[1]["localModel"] = groups[1].removeValue(forKey: "tagging")
        catalog["classifierTypes"] = groups; object["workspaceCatalog"] = catalog
        let migrated = try JSONDecoder().decode(LocalClassifierState.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(migrated.schemaVersion, 5)
        XCTAssertEqual(migrated.workspaceCatalog.classifierTypes, [state.workspaceCatalog.classifierTypes[1]])
        XCTAssertEqual(migrated.workspaceCatalog.videoClassifications, [state.workspaceCatalog.videoClassifications[1]])
        XCTAssertFalse(migrated.workspaceCatalog.trees.contains { $0.id == localTree.id })
        XCTAssertEqual(migrated.workspaceCatalog.datasets, state.workspaceCatalog.datasets)
        let encoded = try JSONEncoder().encode(migrated)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("localModel"))
        XCTAssertEqual(try JSONDecoder().decode(LocalClassifierState.self, from: encoded), migrated)
        // Pre-provider groups also retire; malformed retired runtime fields do not crash.
        groups[0].removeValue(forKey: "classificationProvider")
        catalog["classifierTypes"] = groups; object["workspaceCatalog"] = catalog
        let unversionedProvider = try JSONDecoder().decode(LocalClassifierState.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(unversionedProvider.workspaceCatalog.classifierTypes.count, 1)
    }

    func testUnconfiguredEngineCannotFabricateTags() async throws {
        let engine = UnconfiguredClassificationEngine()
        do {
            _ = try await engine.classify(.init(staticPrefix: "", dynamicSuffix: "Games", allowedTagNames: ["Games"], maximumTags: 3))
            XCTFail("An unconfigured provider must leave new items unresolved")
        } catch { XCTAssertEqual(error as? CloudClassificationError, .notConfigured) }
    }
}
