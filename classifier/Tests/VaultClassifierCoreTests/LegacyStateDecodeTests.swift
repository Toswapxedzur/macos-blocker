import Foundation
import XCTest
@testable import VaultClassifierCore

/// A state file written by ANY earlier build must still open. Removed features
/// leave keys behind in stored JSON; every decoder here is keyed, so an unknown
/// key is simply never read — there is no need for per-type "retired key" decode
/// blocks, and this fixture proves it. It carries every key this project has ever
/// retired, each at the place it used to live. (Scanned 2026-09-18: no real state
/// file on either of the owner's machines still holds any of them except
/// `policies` / `policyID`, retired the same day.)
final class LegacyStateDecodeTests: XCTestCase {
    func testStateCarryingEveryRetiredKeyStillLoadsAndNeverWritesThemBack() throws {
        let starter = WorkspaceCatalog.starter()
        var catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(starter)) as? [String: Any])
        // Catalog-level leftovers.
        catalog["creatorClassifications"] = [["creatorID": "youtube:channel:old", "tagIDs": ["a"]]]
        catalog["models"] = [["id": "retired-trainable-model"]]
        // A classifier type from the trainable-model / provider-assist era.
        let tree = starter.trees[0], dataset = starter.datasets[0]
        catalog["classifierTypes"] = [[
            "id": "type", "name": "Type", "treeID": tree.id, "treeRevision": tree.revision,
            "datasetID": dataset.id, "datasetRevision": dataset.revision, "applicablePlatformID": "youtube", "order": 0,
            "dataSourcePlatformIDs": ["youtube"], "localModelID": "retired-model",
            "selectedLLMProviderProfileID": "retired-provider", "llmAssistDraftConfiguration": ["retired": true],
            "llmAssistConfiguration": ["retired": true], "llmProfileIDs": ["retired-provider"],
            "platformLocked": true, "decisionPriority": "humanFirst",
            "localModelOverrides": ["minimumTags": 1, "expectedTags": 2],
        ]]
        // Dataset + binding leftovers.
        var datasets = try XCTUnwrap(catalog["datasets"] as? [[String: Any]])
        datasets[0]["records"] = [["id": "old-record"]]
        datasets[0]["creatorClassifications"] = [["creatorID": "x"]]
        catalog["datasets"] = datasets
        if var bindings = catalog["bindings"] as? [[String: Any]], !bindings.isEmpty {
            bindings[0]["activeModelID"] = "retired-model"
            bindings[0]["policyID"] = "clash-royale-focus"
            catalog["bindings"] = bindings
        }
        let state: [String: Any] = [
            "schemaVersion": 1,
            "settings": ["localLLM": ["maximumTags": 3, "minimumTags": 1, "expectedTags": 2]],
            "workspaceCatalog": catalog,
            // Root-level leftovers of the deterministic classifier, the audit feature and policy.
            "sequence": 41, "sourceProfiles": [["id": "p"]], "sourcePrior": ["k": 1], "personalModel": ["w": [1, 2]],
            "trainingCorpus": [["t": "x"]], "creatorClassifications": [["c": 1]], "cacheBackfill": ["done": true],
            "cache": ["a": "b"], "ledger": [["e": 1]], "auditState": ["enabled": false],
            "policies": [["id": "clash-royale-focus", "name": "Clash Royale focus", "includeAnyTagIDs": ["content.entities.clash-royale"]]],
        ]

        let decoded = try JSONDecoder().decode(LocalClassifierState.self, from: JSONSerialization.data(withJSONObject: state))
        XCTAssertEqual(decoded.schemaVersion, 2, "an older schema version is lifted, not rejected")
        XCTAssertEqual(decoded.settings.localLLM.strictness, .broadest, "max 3 / min 1 → the Broadest position")
        XCTAssertEqual(decoded.settings.localLLM.maximumTags, 3)
        XCTAssertEqual(decoded.settings.localLLM.minimumTags, 1)
        let type = try XCTUnwrap(decoded.workspaceCatalog.classifierTypes.first)
        XCTAssertEqual(type.applicablePlatformID, "youtube")
        XCTAssertEqual(type.localModelOverrides?.strictness, .broadest)
        XCTAssertNoThrow(try decoded.workspaceCatalog.validate())

        let rewritten = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)
        for retired in ["sourceProfiles", "personalModel", "trainingCorpus", "auditState", "cacheBackfill", "\"ledger\"", "\"policies\"",
                        "policyID", "activeModelID", "localModelID", "llmAssistConfiguration", "decisionPriority", "platformLocked",
                        "dataSourcePlatformIDs", "\"records\"", "\"models\"", "expectedTags",
                        "\"maximumTags\"", "\"minimumTags\"", "presetID", "researchOverrides", "\"modelFileName\""] {
            XCTAssertFalse(rewritten.contains(retired), "retired key was written back: \(retired)")
        }
    }

    func testBackupManifestFromAnOlderBuildStillLoads() throws {
        let legacy = #"{"createdAtMilliseconds":1700000000000,"packageChecksum":"abc","collectedEntryCount":3,"trainingExampleCount":9,"personalModelVersion":"v1"}"#
        let manifest = try JSONDecoder().decode(LocalModelBackupManifest.self, from: Data(legacy.utf8))
        XCTAssertEqual(manifest.collectedEntryCount, 3)
        XCTAssertEqual(manifest.videoClassificationCount, 0)
    }
}
