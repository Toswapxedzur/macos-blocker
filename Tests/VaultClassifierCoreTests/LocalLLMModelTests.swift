import XCTest
@testable import VaultClassifierCore

final class LocalLLMModelTests: XCTestCase {

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
            unknownTerms: ["HermitCraft"], knowledgeRefs: ["term:hermitcraft"],
            source: .modelKnowledge, modelVersion: "llama-3.2-3b/v1"
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

    func testKnowledgeKeyAndTitleMatching() {
        let term = KnowledgeEntry(kind: .term, subject: "HermitCraft", meaning: "A Minecraft SMP server.")
        XCTAssertEqual(term.id, "term:hermitcraft")
        XCTAssertTrue(term.matches(title: "My HERMITCRAFT season 9 base"))
        XCTAssertFalse(term.matches(title: "Cooking pasta"))

        let creator = KnowledgeEntry(kind: .creator, subject: "youtube:handle:xyz", meaning: "A political channel.")
        XCTAssertEqual(creator.id, "creator:youtube:handle:xyz")
        XCTAssertFalse(creator.matches(title: "anything"), "creators match by key, not title")
    }

    func testMatchedKnowledgeReturnsCreatorEntryPlusTitleTermMatches() {
        var catalog = WorkspaceCatalog()
        catalog.upsertKnowledgeEntry(KnowledgeEntry(kind: .term, subject: "HermitCraft", meaning: "A Minecraft SMP."))
        catalog.upsertKnowledgeEntry(KnowledgeEntry(kind: .term, subject: "Bedrock", meaning: "A Minecraft edition."))
        catalog.upsertKnowledgeEntry(KnowledgeEntry(kind: .creator, subject: "youtube:handle:c1", meaning: "A gaming channel."))

        let matched = catalog.matchedKnowledge(title: "HermitCraft finale", creatorID: "youtube:handle:c1")
        let ids = Set(matched.map(\.id))
        XCTAssertTrue(ids.contains("creator:youtube:handle:c1"))
        XCTAssertTrue(ids.contains("term:hermitcraft"))
        XCTAssertFalse(ids.contains("term:bedrock"))

        // Unknown creator + no term match -> nothing.
        XCTAssertTrue(catalog.matchedKnowledge(title: "unrelated title", creatorID: "youtube:handle:unknown").isEmpty)
    }

    func testUpsertKnowledgeEntryDedupsByKey() {
        var catalog = WorkspaceCatalog()
        catalog.upsertKnowledgeEntry(KnowledgeEntry(kind: .term, subject: "HermitCraft", meaning: "old"))
        catalog.upsertKnowledgeEntry(KnowledgeEntry(kind: .term, subject: "hermitcraft", meaning: "new"))
        XCTAssertEqual(catalog.knowledgeEntries.count, 1)
        XCTAssertEqual(catalog.knowledgeEntries.first?.meaning, "new")
    }

    // MARK: - Catalog Codable + validation + greenfield

    func testCatalogRoundTripsNewStores() throws {
        var catalog = WorkspaceCatalog()
        catalog.upsertVideoClassification(VideoClassification(
            classifierTypeID: "t", platformID: "youtube", entryID: "v1", creatorID: "c1",
            treeID: "tree", treeRevision: 1, tags: [ScoredTag(tagID: "games", confidence: 4)],
            source: .model, modelVersion: "v1"))
        catalog.upsertKnowledgeEntry(KnowledgeEntry(kind: .term, subject: "HermitCraft", meaning: "A Minecraft SMP."))
        catalog.correctionExamples.append(CorrectionExample(
            classifierTypeID: "t", platformID: "youtube", entryID: "v1", creatorID: "c1",
            title: "Some title", correctTagIDs: ["news"]))

        let data = try JSONEncoder().encode(catalog)
        let decoded = try JSONDecoder().decode(WorkspaceCatalog.self, from: data)
        XCTAssertEqual(decoded.videoClassifications, catalog.videoClassifications)
        XCTAssertEqual(decoded.knowledgeEntries, catalog.knowledgeEntries)
        XCTAssertEqual(decoded.correctionExamples, catalog.correctionExamples)
        XCTAssertEqual(decoded.creatorHistograms, catalog.creatorHistograms)
    }

    func testValidateLocalLLMStoresRejectsDuplicateIDs() {
        var catalog = WorkspaceCatalog()
        let a = VideoClassification(
            id: "dup", classifierTypeID: "t", platformID: "youtube", entryID: "v1", creatorID: "c1",
            treeID: "tree", treeRevision: 1, tags: [ScoredTag(tagID: "g", confidence: 3)],
            source: .model, modelVersion: "v1")
        var b = a
        b.entryID = "v2"
        catalog.videoClassifications = [a, b] // same id "dup"
        XCTAssertThrowsError(try catalog.validateLocalLLMStores())
    }

    func testStarterHasEmptyNewStores() {
        let starter = WorkspaceCatalog.starter()
        XCTAssertTrue(starter.videoClassifications.isEmpty)
        XCTAssertTrue(starter.knowledgeEntries.isEmpty)
        XCTAssertTrue(starter.correctionExamples.isEmpty)
        XCTAssertTrue(starter.creatorHistograms.isEmpty)
        XCTAssertNoThrow(try starter.validate())
    }
}
