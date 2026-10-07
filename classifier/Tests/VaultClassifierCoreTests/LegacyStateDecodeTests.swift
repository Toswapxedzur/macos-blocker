import Foundation
import XCTest
@testable import VaultClassifierCore

/// Compatible alpha state forms still open; future/unsupported schemas are refused. Removed features
/// leave keys behind in stored JSON; every decoder here is keyed, so an unknown
/// key is simply never read — there is no need for per-type "retired key" decode
/// blocks, and this fixture proves it. It carries every key this project has ever
/// retired, each at the place it used to live. (Scanned 2026-09-18: no real state
/// file on either of the owner's machines still holds any of them except
/// `policies` / `policyID`, retired the same day.)
final class LegacyStateDecodeTests: XCTestCase {
    func testCompatibleUnversionedAlphaPreservesCurrentSettings() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(LocalClassifierState())) as? [String: Any])
        json.removeValue(forKey: "schemaVersion")
        let decoded = try JSONDecoder().decode(LocalClassifierState.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.schemaVersion, LocalClassifierState.currentSchemaVersion)
        XCTAssertEqual(decoded.settings, LocalClassifierState().settings)
        XCTAssertEqual(decoded.workspaceCatalog, LocalClassifierState().workspaceCatalog)
    }

    func testUnsupportedSchemaDoesNotRewriteStoredBytes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.json")
        for version in [-1, LocalClassifierState.currentSchemaVersion + 1, 99] {
            let bytes = Data("{\"schemaVersion\":\(version),\"futureField\":{\"keep\":true}}".utf8)
            try bytes.write(to: url)
            XCTAssertThrowsError(try LocalStateFile(url: url).load()) { error in
                XCTAssertEqual(error as? LocalStateSchemaError, .unsupportedVersion(version))
            }
            LocalStateFile.flushAllPendingWrites()
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
    }

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
        XCTAssertEqual(decoded.workspaceCatalog.classifierTypes[0].localModel.strictness, .broadest, "max 3 / min 1 → the Broadest position")
        XCTAssertEqual(decoded.workspaceCatalog.classifierTypes[0].localModel.maximumTags, 3)
        XCTAssertEqual(decoded.workspaceCatalog.classifierTypes[0].localModel.minimumTags, 1)
        let type = try XCTUnwrap(decoded.workspaceCatalog.classifierTypes.first)
        XCTAssertEqual(type.applicablePlatformIDs, ["youtube"])
        XCTAssertEqual(type.localModel.strictness, .broadest)
        XCTAssertNoThrow(try decoded.workspaceCatalog.validate())

        let rewritten = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)
        for retired in ["sourceProfiles", "personalModel", "trainingCorpus", "auditState", "cacheBackfill", "\"ledger\"", "\"policies\"",
                        "policyID", "activeModelID", "localModelID", "llmAssistConfiguration", "decisionPriority", "platformLocked",
                        "dataSourcePlatformIDs", "\"records\"", "\"models\"", "expectedTags",
                        "\"maximumTags\"", "\"minimumTags\"", "presetID", "researchOverrides", "\"modelFileName\""] {
            XCTAssertFalse(rewritten.contains(retired), "retired key was written back: \(retired)")
        }
    }

    func testGlobalDialsReconcileOnceIntoIndependentGroups() throws {
        let base = WorkspaceCatalog.starter()
        let tree = base.trees[0], dataset = base.datasets[0]
        var catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(base)) as? [String: Any])
        func group(_ id: String) -> [String: Any] {
            ["id": id, "name": id, "treeID": tree.id, "treeRevision": tree.revision,
             "datasetID": dataset.id, "datasetRevision": dataset.revision]
        }
        var inherited = group("inherited")
        inherited["localModelOverrides"] = NSNull()
        var partial = group("partial")
        partial["localModelOverrides"] = ["speedQuality": "fast", "houseRules": "  "]
        var own = group("own")
        own["localModelOverrides"] = ["speedQuality": "balanced", "strictness": 1, "houseRules": "own rules"]
        var current = group("current")
        current["localModel"] = ["speedQuality": "balanced", "strictness": 3, "houseRules": ""]
        catalog["classifierTypes"] = [inherited, partial, own, current]
        let raw: [String: Any] = ["workspaceCatalog": catalog,
            "settings": ["localLLM": ["speedQuality": "best", "strictness": 5, "houseRules": "shared rules"]]]
        var decoded = try JSONDecoder().decode(LocalClassifierState.self, from: JSONSerialization.data(withJSONObject: raw))
        let groups = decoded.workspaceCatalog.classifierTypes
        XCTAssertEqual(groups[0].localModel, .init(speedQuality: .best, strictness: .broadest, houseRules: "shared rules"))
        XCTAssertEqual(groups[1].localModel, .init(speedQuality: .fast, strictness: .broadest, houseRules: "shared rules"))
        XCTAssertEqual(groups[2].localModel, .init(speedQuality: .balanced, strictness: .strictest, houseRules: "own rules"))
        XCTAssertEqual(groups[3].localModel, .init(), "already independent settings must not inherit retired defaults")
        decoded.workspaceCatalog.classifierTypes[0].localModel = .init(speedQuality: .fast)
        XCTAssertEqual(decoded.workspaceCatalog.classifierTypes[1].localModel, groups[1].localModel)
        let encoded = try JSONEncoder().encode(decoded)
        let json = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(json.contains("localLLM")); XCTAssertFalse(json.contains("localModelOverrides"))
        XCTAssertEqual(try JSONDecoder().decode(LocalClassifierState.self, from: encoded), decoded)
        let new = ClassifierTypeAsset(name: "new", treeID: tree.id, treeRevision: 1, datasetID: dataset.id, datasetRevision: 1)
        XCTAssertEqual(new.localModel, .init(), "new groups never copy another group's settings")
    }

    func testMalformedRetiredGlobalDialStateIsIgnoredSafely() throws {
        let base = WorkspaceCatalog.starter()
        var catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(base)) as? [String: Any])
        catalog["classifierTypes"] = [["id": "old", "name": "old", "treeID": base.trees[0].id,
            "treeRevision": 1, "datasetID": base.datasets[0].id, "datasetRevision": 1,
            "localModelOverrides": ["speedQuality": ["malformed": true]]]]
        let raw: [String: Any] = ["settings": ["localLLM": ["malformed"]], "workspaceCatalog": catalog]
        let decoded = try JSONDecoder().decode(LocalClassifierState.self, from: JSONSerialization.data(withJSONObject: raw))
        XCTAssertEqual(decoded.workspaceCatalog.classifierTypes[0].localModel, .init())
    }

    func testBackupManifestFromAnOlderBuildStillLoads() throws {
        let legacy = #"{"createdAtMilliseconds":1700000000000,"packageChecksum":"abc","collectedEntryCount":3,"trainingExampleCount":9,"personalModelVersion":"v1"}"#
        let manifest = try JSONDecoder().decode(LocalModelBackupManifest.self, from: Data(legacy.utf8))
        XCTAssertEqual(manifest.collectedEntryCount, 3)
        XCTAssertEqual(manifest.videoClassificationCount, 0)
    }
}
