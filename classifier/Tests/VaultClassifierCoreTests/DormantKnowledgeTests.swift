import Foundation
import XCTest
@testable import VaultClassifierCore

final class DormantKnowledgeTests: XCTestCase {
    private func oldDocument() throws -> Data {
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(LocalClassifierState())) as? [String: Any])
        root["schemaVersion"] = 7
        var metadata = try XCTUnwrap(root["storageMetadata"] as? [String: Any]); metadata["schemaVersion"] = 7; root["storageMetadata"] = metadata
        var settings = try XCTUnwrap(root["settings"] as? [String: Any])
        settings["research"] = ["enabled": true, "llmProviderProfileID": "legacy-profile"]
        settings["dictionaries"] = ["contributionEnabled": true, "contributionChoiceMade": false]
        root["settings"] = settings
        var catalog = try XCTUnwrap(root["workspaceCatalog"] as? [String: Any])
        catalog["knowledgeEntries"] = [["subject": "SENTINEL-DORMANT-TERM", "meaning": "A private saved definition"]]
        catalog["creatorKnowledge"] = [["subject": "youtube:channel:UClegacy", "meaning": "SENTINEL-DORMANT-CREATOR"]]
        catalog["researchAttempts"] = ["even malformed retired fields are preserved"]
        catalog["creatorResearchAccumulators"] = ["score": 9]
        root["workspaceCatalog"] = catalog
        root["credential-do-not-archive"] = "PRIVATE-CREDENTIAL-SENTINEL"
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    func testMigrationPreservesDormantDataPrivatelyAndDropsActiveKeys() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { LocalStateFile.flushAllPendingWrites(); try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("state.json"); try oldDocument().write(to: file)
        let stateFile = LocalStateFile(url: file)
        let state = try stateFile.load(); stateFile.flushSynchronously()
        XCTAssertEqual(state.schemaVersion, 9)
        let encoded = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        for retired in ["knowledgeEntries", "creatorKnowledge", "researchAttempts", "creatorResearchAccumulators", "\"research\"", "\"dictionaries\""] { XCTAssertFalse(encoded.contains(retired), retired) }
        let archives = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("dormant"), includingPropertiesForKeys: nil)
        XCTAssertEqual(archives.count, 1)
        let archived = String(decoding: try Data(contentsOf: XCTUnwrap(archives.first)), as: UTF8.self)
        XCTAssertTrue(archived.contains("SENTINEL-DORMANT-TERM")); XCTAssertTrue(archived.contains("SENTINEL-DORMANT-CREATOR"))
        XCTAssertFalse(archived.contains("PRIVATE-CREDENTIAL-SENTINEL"))
        #if os(macOS)
        let attributes = try FileManager.default.attributesOfItem(atPath: archives[0].path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        #endif
        // Reopening cannot activate or rehydrate archived definitions.
        XCTAssertEqual(try stateFile.load(), state)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("dormant").path).count, 1)
    }

    func testArchiveFailurePreservesOriginalState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { LocalStateFile.flushAllPendingWrites(); try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = try oldDocument(), file = root.appendingPathComponent("state.json")
        try original.write(to: file)
        try Data("blocked".utf8).write(to: root.appendingPathComponent("dormant"))
        XCTAssertThrowsError(try LocalStateFile(url: file).load())
        LocalStateFile.flushAllPendingWrites()
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testRetiredDefinitionsCannotEnterPromptsAndOldAutomaticCacheIsStale() throws {
        let state = try JSONDecoder().decode(LocalClassifierState.self, from: oldDocument())
        let tree = TagTreeAsset(id: "tree", name: "Topics", nodes: [.init(id: "games", name: "Games")])
        let group = ClassifierTypeAsset(id: "group", name: "Topics", treeID: tree.id, treeRevision: tree.revision,
            datasetID: "data", datasetRevision: 1, applicablePlatformIDs: ["youtube"])
        let pipeline = VideoClassificationPipeline(llm: UnconfiguredClassificationEngine())
        let parts = pipeline.primaryPromptParts(title: "SENTINEL-DORMANT-TERM video", entryID: "video", creatorID: "youtube:channel:UClegacy",
            platformID: "youtube", classifierType: group, tree: tree, catalog: state.workspaceCatalog)
        XCTAssertFalse(parts.dynamicSuffix.contains("A private saved definition")); XCTAssertFalse(parts.dynamicSuffix.contains("SENTINEL-DORMANT-CREATOR"))
        var row = VideoClassification(classifierTypeID: group.id, platformID: "youtube", entryID: "video", creatorID: "creator", treeID: tree.id,
            treeRevision: tree.revision, tags: [], source: .model, modelVersion: group.cloudModelVersion + "+p6")
        XCTAssertFalse(LocalClassifierCoordinator.isClassificationCurrent(row, forType: group, servingModelVersion: row.modelVersion))
        row.source = .humanCorrected
        XCTAssertTrue(LocalClassifierCoordinator.isClassificationCurrent(row, forType: group, servingModelVersion: row.modelVersion))
    }
}
