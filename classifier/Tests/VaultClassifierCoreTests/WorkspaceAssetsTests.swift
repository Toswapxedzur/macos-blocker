import Foundation
import XCTest
@testable import VaultClassifierCore

final class WorkspaceAssetsTests: XCTestCase {
    func testEveryRegisteredPlatformCanHaveACollectionBinding() throws {
        var catalog = WorkspaceCatalog.starter()
        for definition in CollectionPlatformRegistry.definitions {
            let binding = try catalog.ensurePlatformBinding(definition.id)
            XCTAssertEqual(binding.id, definition.id)
            // Recorded by default only where something classifies (owner 2026-09-30).
            XCTAssertEqual(binding.collectionEnabled, definition.supportsLocalModel)
            XCTAssertEqual(binding.collectionKeepDays, -1, "follows the Keep for all platforms")
        }
    }

    func testOnlyYouTubeBilibiliRedditAndXClassify() {
        XCTAssertEqual(
            Set(CollectionPlatformRegistry.definitions.filter(\.supportsLocalModel).map(\.id)),
            ["youtube", "bilibili", "reddit", "twitter"]
        )
    }

    func testBindingsSavedBeforeTheKeepRecordOnlyWhereSomethingClassifies() throws {
        let old = #"[{"id":"twitch","name":"Twitch","treeID":"t","datasetID":"d","collectionEnabled":true},{"id":"youtube","name":"YouTube","treeID":"t","datasetID":"d","collectionEnabled":true},{"id":"reddit","name":"Reddit","treeID":"t","datasetID":"d","collectionEnabled":false,"collectionKeepDays":30}]"#
        let bindings = try JSONDecoder().decode([PlatformBinding].self, from: Data(old.utf8))
        XCTAssertEqual(bindings.map(\.collectionEnabled), [false, true, false])
        XCTAssertEqual(bindings.map(\.collectionKeepDays), [-1, -1, 30])
    }

    func testPruneKeepsEachPlatformsDays() throws {
        var catalog = WorkspaceCatalog.starter()
        let day: Int64 = 86_400_000
        let now: Int64 = 1_000 * day
        func entry(_ id: String, _ platform: String, daysAgo: Int64) -> CollectedPlatformEntry {
            CollectedPlatformEntry(id: id, platformID: platform, entryID: "\(platform):post:\(id)", creatorID: "\(platform):account:a", creatorName: "A", entryType: "post", title: "T", firstObservedAtMilliseconds: now - daysAgo * day, lastObservedAtMilliseconds: now - daysAgo * day)
        }
        catalog.collectionKeepDays = 180
        let redditIndex = try XCTUnwrap(catalog.bindings.firstIndex(where: { $0.id == "reddit" }))
        catalog.bindings[redditIndex].collectionKeepDays = 7
        catalog.datasets[0].collectedEntries = [
            entry("y1", "youtube", daysAgo: 100), entry("y2", "youtube", daysAgo: 200),
            entry("r1", "reddit", daysAgo: 3), entry("r2", "reddit", daysAgo: 10),
        ]
        XCTAssertTrue(catalog.pruneCollectedEntries(nowMilliseconds: now))
        XCTAssertEqual(catalog.datasets[0].collectedEntries.map(\.id), ["y1", "r1"])
        catalog.collectionKeepDays = 0
        catalog.datasets[0].collectedEntries.append(entry("y3", "youtube", daysAgo: 5000))
        XCTAssertFalse(catalog.pruneCollectedEntries(nowMilliseconds: now), "0 = forever")
    }

    func testCollectedEntriesAreSavedPerPlatformAndDayAndLoadBack() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("collected-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = LocalStateFile(url: directory.appendingPathComponent("state.json"))
        var state = LocalClassifierState()
        state.workspaceCatalog.datasets[0].collectedEntries = [
            CollectedPlatformEntry(id: "a", platformID: "youtube", entryID: "youtube:video:a", creatorID: "youtube:handle:@a", creatorName: "A", entryType: "video", title: "A", firstObservedAtMilliseconds: 0, lastObservedAtMilliseconds: 0),
            CollectedPlatformEntry(id: "b", platformID: "reddit", entryID: "reddit:post:b", creatorID: "reddit:subreddit:b", creatorName: "r/b", entryType: "post", title: "B", firstObservedAtMilliseconds: 86_400_000, lastObservedAtMilliseconds: 86_400_000),
        ]
        try file.save(state)
        file.flushSynchronously()
        let stateJSON = try String(contentsOf: directory.appendingPathComponent("state.json"), encoding: .utf8)
        XCTAssertFalse(stateJSON.contains("youtube:video:a"), "entries are not inside the state file")
        let datasetDirectory = directory.appendingPathComponent("collected/local-dataset")
        XCTAssertTrue(FileManager.default.fileExists(atPath: datasetDirectory.appendingPathComponent("youtube/1970-01-01.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: datasetDirectory.appendingPathComponent("reddit/1970-01-02.json").path))
        let loaded = try LocalStateFile(url: directory.appendingPathComponent("state.json")).load()
        XCTAssertEqual(Set(loaded.workspaceCatalog.datasets[0].collectedEntries.map(\.id)), ["a", "b"])
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
    /// every type whose applicablePlatformIDs hold it, so two types on one platform
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
                datasetID: dataset.id, datasetRevision: dataset.revision, applicablePlatformIDs: ["youtube"])
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
        XCTAssertEqual(chosen.classifierTypes.first { $0.id == "first" }?.applicablePlatformIDs, [])
        XCTAssertEqual(chosen.classifierTypes.first { $0.id == "second" }?.applicablePlatformIDs, ["youtube"])
        XCTAssertEqual(chosen.bindings[bindingIndex].activeClassifierTypeID, "second")
        XCTAssertNoThrow(try chosen.validate())

        // With no chosen type the first claimant wins and becomes the sole, auto-selected type.
        var unchosen = catalog
        unchosen.reconcileClassifierTypes()
        XCTAssertEqual(unchosen.classifierTypes.first { $0.id == "first" }?.applicablePlatformIDs, ["youtube"])
        XCTAssertEqual(unchosen.classifierTypes.first { $0.id == "second" }?.applicablePlatformIDs, [])
        XCTAssertEqual(unchosen.bindings[bindingIndex].activeClassifierTypeID, "first")
        XCTAssertNoThrow(try unchosen.validate())
    }

    /// One type may take several platforms (owner 2026-09-30), each still held
    /// by at most one type: a second type claiming one of them loses only that one.
    func testOneTypeHoldsSeveralPlatformsEachOnlyOnce() throws {
        var catalog = WorkspaceCatalog.starter()
        let youtube = try catalog.ensurePlatformBinding("youtube")
        _ = try catalog.ensurePlatformBinding("bilibili")
        let tree = try XCTUnwrap(catalog.trees.first { $0.id == youtube.treeID })
        let dataset = try XCTUnwrap(catalog.datasets.first { $0.id == youtube.datasetID })
        let make = { (id: String, platforms: [String]) in
            ClassifierTypeAsset(
                id: id, name: id, treeID: tree.id, treeRevision: tree.revision,
                datasetID: dataset.id, datasetRevision: dataset.revision, applicablePlatformIDs: platforms)
        }
        catalog.classifierTypes = [make("both", ["youtube", "bilibili"])]
        XCTAssertNoThrow(try catalog.validate(), "one type on two platforms is valid")
        catalog.reconcileClassifierTypes()
        XCTAssertEqual(catalog.classifierTypes.first?.applicablePlatformIDs, ["youtube", "bilibili"])
        XCTAssertEqual(catalog.bindings.first { $0.id == "youtube" }?.activeClassifierTypeID, "both")
        XCTAssertEqual(catalog.bindings.first { $0.id == "bilibili" }?.activeClassifierTypeID, "both")

        catalog.classifierTypes.append(make("late", ["bilibili"]))
        XCTAssertThrowsError(try catalog.validate()) { error in
            XCTAssertEqual(error as? WorkspaceCatalogError, .duplicateApplicablePlatform("bilibili"))
        }
        catalog.reconcileClassifierTypes()
        XCTAssertEqual(catalog.classifierTypes.first { $0.id == "both" }?.applicablePlatformIDs, ["youtube", "bilibili"],
                       "the binding's chosen type keeps its platforms")
        XCTAssertEqual(catalog.classifierTypes.first { $0.id == "late" }?.applicablePlatformIDs, [])
        XCTAssertNoThrow(try catalog.validate())
    }

    /// A stored catalog from before a platform was retired (TikTok, 2026-09-24)
    /// still loads: the retired binding goes, a type aimed at it stays, unbound.
    /// Before this, validate() refused the whole state and the classifier never
    /// started (nor joined the hub).
    func testARetiredPlatformNeverStopsTheCatalogLoading() throws {
        var catalog = WorkspaceCatalog.starter()
        let binding = try catalog.ensurePlatformBinding("youtube")
        let tree = try XCTUnwrap(catalog.trees.first { $0.id == binding.treeID })
        let dataset = try XCTUnwrap(catalog.datasets.first { $0.id == binding.datasetID })
        catalog.bindings.append(PlatformBinding(id: "tiktok", name: "TikTok", treeID: tree.id, datasetID: dataset.id, activeClassifierTypeID: "old"))
        catalog.classifierTypes = [ClassifierTypeAsset(
            id: "old", name: "TikTok tags", treeID: tree.id, treeRevision: tree.revision,
            datasetID: dataset.id, datasetRevision: dataset.revision, applicablePlatformIDs: ["tiktok"])]
        XCTAssertThrowsError(try catalog.validate())

        catalog.reconcileClassifierTypes()
        XCTAssertNoThrow(try catalog.validate())
        XCTAssertFalse(catalog.bindings.contains { $0.id == "tiktok" })
        XCTAssertEqual(catalog.classifierTypes.map(\.id), ["old"], "the type is kept")
        XCTAssertEqual(catalog.classifierTypes.first?.applicablePlatformIDs, [], "…unbound")
    }

    func testClassifierTypeLocalModelOverridesLegacyAndRoundTrip() throws {
        let legacy = Data(#"{"id":"type","name":"Type","treeID":"tree","treeRevision":1,"datasetID":"dataset","datasetRevision":1,"applicablePlatformID":"youtube","order":0}"#.utf8)
        let decodedLegacy = try JSONDecoder().decode(ClassifierTypeAsset.self, from: legacy)
        XCTAssertEqual(decodedLegacy.localModel, LocalLLMSettings())
        XCTAssertEqual(decodedLegacy.modelFileName, SpeedQualityDial.balanced.ggufFileName)
        XCTAssertNil(decodedLegacy.researchEnabled)

        let value = ClassifierTypeAsset(
            id: "type", name: "Type", treeID: "tree", treeRevision: 1,
            datasetID: "dataset", datasetRevision: 1, applicablePlatformIDs: ["youtube"],
            localModel: .init(speedQuality: .best, strictness: .strict, houseRules: "Prefer documentaries."),
            researchEnabled: false
        )
        let roundTrip = try JSONDecoder().decode(ClassifierTypeAsset.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(roundTrip.localModel, value.localModel)
        XCTAssertEqual(roundTrip.modelFileName, "Qwen2.5-14B-Instruct-Q4_K_M.gguf")
        XCTAssertEqual(roundTrip.researchEnabled, false)
    }

    /// A type written before the dials (per-type model file, full research profile,
    /// preset provenance) keeps its tier and research switch; the rest is dropped.
    func testPreDialClassifierTypeDecodesToDialPositions() throws {
        let old = #"{"id":"type","name":"Type","treeID":"tree","treeRevision":1,"datasetID":"dataset","datasetRevision":1,"applicablePlatformID":"youtube","order":0,"modelFileName":"Qwen2.5-3B-Instruct-Q4_K_M.gguf","localModelOverrides":{"allowDecline":false,"maximumTags":1},"researchOverrides":{"enabled":false,"requestsPerMinute":6,"dailyTokenLimit":5000,"cooldownHours":24},"presetID":"gentle"}"#
        let decoded = try JSONDecoder().decode(ClassifierTypeAsset.self, from: Data(old.utf8))
        XCTAssertEqual(decoded.localModel, LocalLLMSettings(), "retired overrides reconcile only while decoding the complete state")
        XCTAssertEqual(decoded.modelFileName, SpeedQualityDial.balanced.ggufFileName)
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
