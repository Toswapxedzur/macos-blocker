import Foundation
import XCTest
@testable import VaultClassifierCore
import VaultClassifierBridge

final class VaultClassifierCoreTests: XCTestCase {
    func testBundledSeedLoadsAndTagTreeBuildsInferenceTaxonomy() throws {
        let seed = try SeedPackageLoader.bundled()
        XCTAssertFalse(seed.package.taxonomy.isEmpty)
        let tree = TagTreeAsset(name: "Test", nodes: [.init(id: "tag", name: "Tag")])
        XCTAssertEqual(try tree.inferenceTaxonomy().nodes.keys.sorted(), ["tag"])
    }

    func testRetiredClassifierStateFieldsDecodeAndAreNeverEncoded() throws {
        let base = try JSONSerialization.jsonObject(with: JSONEncoder().encode(LocalClassifierState())) as! [String: Any]
        var legacy = base
        legacy["cache"] = [["key": "old"]]
        legacy["ledger"] = [["id": "old"]]
        legacy["cacheBackfill"] = ["isStarted": true]
        legacy["personalModel"] = ["weights": [1, 2, 3]]
        legacy["trainingCorpus"] = ["examples": [["id": "old"]]]
        legacy["sourceProfiles"] = ["creator": ["tag": 1]]
        legacy["sourcePrior"] = ["weight": 0.3]
        legacy["creatorClassifications"] = [["id": "old"]]
        let decoded = try JSONDecoder().decode(
            LocalClassifierState.self,
            from: JSONSerialization.data(withJSONObject: legacy)
        )
        let encoded = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)
        for retired in ["cache", "ledger", "cacheBackfill", "personalModel", "trainingCorpus", "sourceProfiles", "sourcePrior", "creatorClassifications"] {
            XCTAssertFalse(encoded.contains("\"\(retired)\""))
        }
    }

    func testSharedBridgeExposesOnlyLiveOperations() {
        XCTAssertEqual(
            Set(SharedBrowserBridgeOperation.allCases.map(\.rawValue)),
            Set(["bridge-info", "collection-info", "diagnostic", "collect", "video-tags", "video-tags-batch", "classifier-taxonomy", "submit-correction", "dev-log", "activity-record", "activity-settings"])
        )
    }

    func testVideoTagRequestAndResponseRemainBounded() throws {
        let request = NativeVideoTagsRequest(
            platformID: "youtube",
            entryID: "youtube:video:abc",
            creatorID: "youtube:channel:creator",
            title: "A video"
        )
        XCTAssertNoThrow(try request.validate())
        XCTAssertThrowsError(try NativeVideoTagsRequest(
            platformID: "youtube",
            entryID: "reddit:post:abc",
            creatorID: "youtube:channel:creator",
            title: "A video"
        ).validate())

        let valid = NativeVideoTag(id: "tag", name: "Tag", lightColorHex: "#DBE5F3", darkColorHex: "#253E62")
        let invalid = NativeVideoTag(id: "bad", name: "Bad", lightColorHex: "", darkColorHex: "")
        let response = NativeVideoTagsResponse(platformID: "youtube", entryID: "youtube:video:abc", tags: Array(repeating: valid, count: 20) + [invalid])
        XCTAssertEqual(response.tags.count, 16)
        XCTAssertFalse(response.tags.contains(where: { $0.id == "bad" }))
    }

    func testCollectionDeduplicatesWithoutChangingDatasetRevision() {
        var dataset = ClassificationDataset(name: "Collected")
        let originalRevision = dataset.revision
        let first = CollectedPlatformEntry(
            id: "one", platformID: "youtube", entryID: "youtube:video:1",
            creatorID: "youtube:handle:@creator", creatorName: "Creator",
            entryType: "video", title: "Title", firstObservedAtMilliseconds: 1,
            lastObservedAtMilliseconds: 1, observationCount: 1
        )
        var refreshed = first
        refreshed.id = "two"
        refreshed.lastObservedAtMilliseconds = 2
        refreshed.observationCount = 2
        XCTAssertTrue(dataset.upsertCollectedEntry(first))
        XCTAssertFalse(dataset.upsertCollectedEntry(refreshed))
        XCTAssertEqual(dataset.collectedEntries.count, 1)
        XCTAssertEqual(dataset.collectedEntries[0].observationCount, 3)
        XCTAssertEqual(dataset.revision, originalRevision)
    }
}
