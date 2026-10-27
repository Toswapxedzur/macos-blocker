import XCTest
@testable import VaultClassifierCore

final class ClassificationRecordsTests: XCTestCase {

    // MARK: - ScoredTag

    func testScoredTagClampsConfidenceIntoRange() {
        XCTAssertEqual(ScoredTag(tagID: "a", confidence: 9).confidence, 5)
        XCTAssertEqual(ScoredTag(tagID: "a", confidence: 0).confidence, 1)
        XCTAssertEqual(ScoredTag(tagID: "a", confidence: 3).confidence, 3)
    }

    func testScoredTagDecodeClampsOutOfRange() throws {
        let json = Data(#"{"tagID":"a","confidence":42}"#.utf8)
        let decoded = try JSONDecoder().decode(ScoredTag.self, from: json)
        XCTAssertEqual(decoded.confidence, 5)
    }

    // MARK: - VideoClassification round-trip

    func testVideoClassificationCodableRoundTrip() throws {
        let original = VideoClassification(
            classifierTypeID: "type", platformID: "youtube", entryID: "youtube:video:v1",
            creatorID: "youtube:handle:c1", treeID: "tree", treeRevision: 1,
            tags: [ScoredTag(tagID: "games", confidence: 5), ScoredTag(tagID: "politics", confidence: 3)],
            source: .model, modelVersion: "cloud/v1"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(VideoClassification.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - Upsert + derived histogram

    func testUpsertVideoClassificationReplacesByIdentityAndUpdatesHistogram() {
        var catalog = WorkspaceCatalog()
        let base = VideoClassification(
            classifierTypeID: "t", platformID: "youtube", entryID: "v1",
            creatorID: "c1", treeID: "tree", treeRevision: 1,
            tags: [ScoredTag(tagID: "games", confidence: 5)],
            source: .model, modelVersion: "v1"
        )
        catalog.upsertVideoClassification(base)
        XCTAssertEqual(catalog.videoClassifications.count, 1)

        // Same type+platform+entry replaces rather than appends.
        var revised = base
        revised.tags = [ScoredTag(tagID: "games", confidence: 2)]
        catalog.upsertVideoClassification(revised)
        XCTAssertEqual(catalog.videoClassifications.count, 1)

        let histogram = catalog.creatorHistogram(classifierTypeID: "t", platformID: "youtube", creatorID: "c1")
        XCTAssertNotNil(histogram)
        XCTAssertEqual(histogram?.videoCount, 1)
        XCTAssertEqual(histogram?.stats["games"]?.averageConfidence, 2)
    }

    func testCreatorHistogramAveragesConfidenceAcrossAllVideos() {
        var catalog = WorkspaceCatalog()
        catalog.upsertVideoClassification(VideoClassification(
            classifierTypeID: "t", platformID: "youtube", entryID: "v1", creatorID: "c1",
            treeID: "tree", treeRevision: 1, tags: [ScoredTag(tagID: "games", confidence: 5)],
            source: .model, modelVersion: "v1"))
        catalog.upsertVideoClassification(VideoClassification(
            classifierTypeID: "t", platformID: "youtube", entryID: "v2", creatorID: "c1",
            treeID: "tree", treeRevision: 1,
            tags: [ScoredTag(tagID: "games", confidence: 3), ScoredTag(tagID: "politics", confidence: 4)],
            source: .model, modelVersion: "v1"))

        let histogram = catalog.creatorHistogram(classifierTypeID: "t", platformID: "youtube", creatorID: "c1")
        XCTAssertEqual(histogram?.videoCount, 2)
        XCTAssertEqual(histogram?.stats["games"]?.averageConfidence, 4)   // (5+3)/2
        XCTAssertEqual(histogram?.stats["politics"]?.averageConfidence, 4) // 4/1
        // Equal averages break ties by tagID ascending.
        XCTAssertEqual(histogram?.averagedTags().map(\.tagID), ["games", "politics"])
    }

    func testRebuildAllHistogramsMatchesIncremental() {
        var incremental = WorkspaceCatalog()
        let videos = (0..<6).map { i in
            VideoClassification(
                classifierTypeID: "t", platformID: "youtube", entryID: "v\(i)",
                creatorID: i % 2 == 0 ? "cA" : "cB", treeID: "tree", treeRevision: 1,
                tags: [ScoredTag(tagID: "games", confidence: (i % 5) + 1)],
                source: .model, modelVersion: "v1")
        }
        for video in videos { incremental.upsertVideoClassification(video) }

        var bulk = WorkspaceCatalog(videoClassifications: videos)
        bulk.rebuildAllCreatorHistograms()

        XCTAssertEqual(
            incremental.creatorHistograms.sorted { $0.id < $1.id },
            bulk.creatorHistograms.sorted { $0.id < $1.id },
            "incremental upsert and bulk rebuild must agree"
        )
    }

    // MARK: - Knowledge map



    /// Research term extraction can emit junk subjects — single letters,
    /// abbreviations, bare numbers, corrupt text. Under raw substring matching a
    /// term named "e" hit essentially every title and injected its whole meaning
    /// into every prompt (measured live: ~570 tokens/video, the entire tagging
    /// slowdown). Such subjects are never stored and never match; real subjects
    /// match as whole words (CJK, which has no word boundaries, as substrings).







    // MARK: - Catalog Codable + validation + greenfield


    func testValidateLocalLLMStoresRejectsDuplicateIDs() {
        var catalog = WorkspaceCatalog()
        let a = VideoClassification(
            id: "dup", classifierTypeID: "t", platformID: "youtube", entryID: "v1", creatorID: "c1",
            treeID: "tree", treeRevision: 1, tags: [ScoredTag(tagID: "g", confidence: 3)],
            source: .model, modelVersion: "v1")
        var b = a
        b.entryID = "v2"
        catalog.videoClassifications = [a, b] // same id "dup"
        XCTAssertThrowsError(try catalog.validateClassificationStores())
    }


    // MARK: - Creator research score

    private let day: Int64 = 24 * 60 * 60 * 1_000

    /// A video that could not be tagged adds 1; a shaky tag a fraction; a sure tag
    /// nothing (and never subtracts).


    /// The score is always fading. Three untaggable videos in one sitting (minutes
    /// apart) still fire at 3 thanks to the small tolerance; spread a day apart they
    /// reach only ~2.86, so the fourth fires.

    /// The score halves every half-life, so a creator who is only occasionally hard
    /// to classify never builds up: one untaggable video a month stays near 1.

    /// A creator who already has a description is looked up once: never scored again.


    /// Rows written by the retired sample-list rule decode as an empty score (they
    /// are transient); the rule itself is a constant (3 / 14 days) with clamped inputs.
}
