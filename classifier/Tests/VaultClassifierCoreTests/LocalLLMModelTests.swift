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
            knowledgeRefs: ["term:hermitcraft"],
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

    func testMatchedKnowledgeReturnsOnlyTitleTermMatchesAndCreatorLivesApart() {
        var catalog = WorkspaceCatalog()
        catalog.upsertKnowledgeEntry(KnowledgeEntry(kind: .term, subject: "HermitCraft", meaning: "A Minecraft SMP."))
        catalog.upsertKnowledgeEntry(KnowledgeEntry(kind: .term, subject: "Bedrock", meaning: "A Minecraft edition."))
        catalog.upsertKnowledgeEntry(KnowledgeEntry(kind: .creator, subject: "youtube:handle:c1", meaning: "A gaming channel."))

        // Creator entries are routed to the separate creator map, not the term map.
        XCTAssertTrue(catalog.knowledgeEntries.allSatisfy { $0.kind == .term })
        XCTAssertEqual(catalog.creatorKnowledge.map(\.id), ["creator:youtube:handle:c1"])
        XCTAssertEqual(catalog.creatorKnowledgeEntry(for: "youtube:handle:c1")?.meaning, "A gaming channel.")

        // matchedKnowledge is term-only now; the creator description is a
        // separate low-confidence fallback, never injected into the primary decode.
        let matched = catalog.matchedKnowledge(title: "HermitCraft finale", creatorID: "youtube:handle:c1")
        let ids = Set(matched.map(\.id))
        XCTAssertFalse(ids.contains("creator:youtube:handle:c1"))
        XCTAssertTrue(ids.contains("term:hermitcraft"))
        XCTAssertFalse(ids.contains("term:bedrock"))

        // Unknown creator + no term match -> nothing.
        XCTAssertTrue(catalog.matchedKnowledge(title: "unrelated title", creatorID: "youtube:handle:unknown").isEmpty)
    }

    /// Research term extraction can emit junk subjects — single letters,
    /// abbreviations, bare numbers, corrupt text. Under raw substring matching a
    /// term named "e" hit essentially every title and injected its whole meaning
    /// into every prompt (measured live: ~570 tokens/video, the entire tagging
    /// slowdown). Such subjects are never stored and never match; real subjects
    /// match as whole words (CJK, which has no word boundaries, as substrings).
    func testTermSubjectsMustBeSpecificAndMatchWholeWords() {
        for junk in ["e", "T", "tE", "CE", "ml", "0", "2200", "832,000", ",", "12345678901234567890123456789", "\u{FFFD}劉", "新"] {
            XCTAssertFalse(KnowledgeEntry.isSpecificTermSubject(junk), "junk subject accepted: \(junk)")
            let entry = KnowledgeEntry(kind: .term, subject: junk, meaning: "Meaning")
            XCTAssertFalse(entry.matches(title: "The best 2200 e-bikes: T, CE and ML explained"), "junk subject matched: \(junk)")
            var catalog = WorkspaceCatalog()
            catalog.upsertKnowledgeEntry(entry)
            XCTAssertTrue(catalog.knowledgeEntries.isEmpty, "junk subject was stored: \(junk)")
        }
        for real in ["url", "KIA", "ГЛИ", "Clash Royale", "友宜", "太監"] {
            XCTAssertTrue(KnowledgeEntry.isSpecificTermSubject(real), "real subject rejected: \(real)")
        }

        // Whole words only: "her" is not inside "hero" or "HERMITCRAFT".
        let her = KnowledgeEntry(kind: .term, subject: "her", meaning: "A pronoun.")
        XCTAssertTrue(her.matches(title: "Her story, told by her"))
        XCTAssertFalse(her.matches(title: "My HERMITCRAFT base and a hero"))
        let clash = KnowledgeEntry(kind: .term, subject: "Clash Royale", meaning: "A mobile game.")
        XCTAssertTrue(clash.matches(title: "clash royale: best deck"))
        XCTAssertFalse(clash.matches(title: "clash royalex deck"))

        // CJK: no word boundaries, so two characters match as a substring.
        let cjk = KnowledgeEntry(kind: .term, subject: "友宜", meaning: "侯友宜")
        XCTAssertTrue(cjk.matches(title: "侯友宜宣布參選"))
        XCTAssertFalse(cjk.matches(title: "unrelated"))
    }

    func testMatchedKnowledgeIsTermOnlyAndBounded() {
        var catalog = WorkspaceCatalog()
        let creatorID = "youtube:handle:c1"
        catalog.upsertKnowledgeEntry(.init(kind: .creator, subject: creatorID, meaning: "Creator context"))
        let subjects = (1...12).map { "Entity" + String(repeating: "x", count: $0) }
        for (index, subject) in subjects.enumerated() {
            catalog.upsertKnowledgeEntry(.init(
                kind: .term,
                subject: subject,
                meaning: "Meaning \(index)",
                updatedAtMilliseconds: Int64(index)
            ))
        }

        let matched = catalog.matchedKnowledge(
            title: subjects.joined(separator: " "),
            creatorID: creatorID
        )
        // Only terms are returned, bounded, longest-subject first — the creator
        // is retrievable apart via creatorKnowledgeEntry.
        XCTAssertEqual(matched.count, WorkspaceCatalog.maximumMatchedKnowledgeEntries)
        XCTAssertTrue(matched.allSatisfy { $0.kind == .term })
        XCTAssertEqual(matched.first?.subject, subjects.last)
        XCTAssertNotNil(catalog.creatorKnowledgeEntry(for: creatorID))
    }

    func testMatchedKnowledgeHonorsPerRequestLimitAndTTL() {
        var catalog = WorkspaceCatalog()
        let day: Int64 = 24 * 60 * 60 * 1_000
        catalog.upsertKnowledgeEntry(.init(
            kind: .creator,
            subject: "creator",
            meaning: "stale",
            updatedAtMilliseconds: day
        ))
        catalog.upsertKnowledgeEntry(.init(
            kind: .term,
            subject: "Current",
            meaning: "fresh",
            updatedAtMilliseconds: 10 * day
        ))
        catalog.upsertKnowledgeEntry(.init(
            kind: .term,
            subject: "Second",
            meaning: "fresh too",
            updatedAtMilliseconds: 10 * day
        ))

        let matched = catalog.matchedKnowledge(
            title: "Current Second",
            creatorID: "creator",
            limit: 1,
            ttlDays: 2,
            nowMilliseconds: 10 * day
        )
        XCTAssertEqual(matched.map(\.subject), ["Current"])
    }

    func testCreatorKnowledgeIsKeyedForeverRegardlessOfTTL() {
        let day: Int64 = 24 * 60 * 60 * 1_000
        let ancientCreator = KnowledgeEntry(
            kind: .creator, subject: "c1", meaning: "desc", updatedAtMilliseconds: day
        )
        let ancientTerm = KnowledgeEntry(
            kind: .term, subject: "Thing", meaning: "desc", updatedAtMilliseconds: day
        )
        // Even with a short TTL and a far-future clock, the creator stays active;
        // the term expires.
        XCTAssertTrue(ancientCreator.isActive(ttlDays: 1, nowMilliseconds: 1_000 * day))
        XCTAssertFalse(ancientTerm.isActive(ttlDays: 1, nowMilliseconds: 1_000 * day))
    }

    func testLegacyCombinedKnowledgeMigratesCreatorsIntoSeparateMap() throws {
        // A pre-split state stored terms and creators together under knowledgeEntries.
        let legacy = Data(#"""
        {"knowledgeEntries":[
          {"id":"creator:youtube:handle:c1","kind":"creator","subject":"youtube:handle:c1","meaning":"A gaming channel.","contextTagHints":[],"sourceURLs":[],"createdAtMilliseconds":1,"updatedAtMilliseconds":1},
          {"id":"term:hermitcraft","kind":"term","subject":"HermitCraft","meaning":"A Minecraft SMP.","contextTagHints":[],"sourceURLs":[],"createdAtMilliseconds":1,"updatedAtMilliseconds":1}
        ]}
        """#.utf8)
        let decoded = try JSONDecoder().decode(WorkspaceCatalog.self, from: legacy)
        XCTAssertEqual(decoded.knowledgeEntries.map(\.id), ["term:hermitcraft"])
        XCTAssertEqual(decoded.creatorKnowledge.map(\.id), ["creator:youtube:handle:c1"])
        XCTAssertEqual(decoded.creatorKnowledgeEntry(for: "youtube:handle:c1")?.meaning, "A gaming channel.")
    }

    func testCreatorAndTermKnowledgeRoundTripInSeparateMaps() throws {
        var catalog = WorkspaceCatalog()
        catalog.upsertKnowledgeEntry(KnowledgeEntry(kind: .term, subject: "HermitCraft", meaning: "SMP"))
        catalog.upsertKnowledgeEntry(KnowledgeEntry(kind: .creator, subject: "c1", meaning: "A gaming channel."))
        let decoded = try JSONDecoder().decode(WorkspaceCatalog.self, from: JSONEncoder().encode(catalog))
        XCTAssertEqual(decoded.knowledgeEntries, catalog.knowledgeEntries)
        XCTAssertEqual(decoded.creatorKnowledge, catalog.creatorKnowledge)
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

    // MARK: - Author research accumulator (§8)

    func testAuthorAccumulatorFiresAtThresholdWithMeanThenResets() {
        var catalog = WorkspaceCatalog()
        let threshold = AuthorResearchThreshold(level: 3, count: 5, windowDays: 30)
        let now: Int64 = 1_000_000_000_000
        // Four uncertain (urgency 4) videos — count not yet met.
        for i in 0..<4 {
            XCTAssertNil(catalog.recordCreatorResearchUrgency(
                classifierTypeID: "t", creatorID: "c", urgency: 4, threshold: threshold, nowMilliseconds: now + Int64(i)))
        }
        // Fifth crosses count; mean 4 ≥ level 3 → fires with the rounded mean, resets.
        XCTAssertEqual(catalog.recordCreatorResearchUrgency(
            classifierTypeID: "t", creatorID: "c", urgency: 4, threshold: threshold, nowMilliseconds: now + 5), 4)
        // After the reset the accumulator is empty, so the next sample does not refire.
        XCTAssertNil(catalog.recordCreatorResearchUrgency(
            classifierTypeID: "t", creatorID: "c", urgency: 4, threshold: threshold, nowMilliseconds: now + 6))
    }

    func testAuthorAccumulatorDoesNotFireWhenMeanBelowLevel() {
        var catalog = WorkspaceCatalog()
        let threshold = AuthorResearchThreshold(level: 3, count: 3, windowDays: 30)
        let now: Int64 = 1_000_000_000_000
        // A confidently-classified creator (urgency 1) never crosses even at count.
        for i in 0..<6 {
            XCTAssertNil(catalog.recordCreatorResearchUrgency(
                classifierTypeID: "t", creatorID: "c", urgency: 1, threshold: threshold, nowMilliseconds: now + Int64(i)))
        }
    }

    func testAuthorAccumulatorPrunesSamplesOutsideWindow() {
        var catalog = WorkspaceCatalog()
        let threshold = AuthorResearchThreshold(level: 3, count: 3, windowDays: 1)
        let day: Int64 = 24 * 60 * 60 * 1_000
        let base: Int64 = 10 * day
        // Two samples two days ago — older than the 1-day window.
        XCTAssertNil(catalog.recordCreatorResearchUrgency(classifierTypeID: "t", creatorID: "c", urgency: 5, threshold: threshold, nowMilliseconds: base - 2 * day))
        XCTAssertNil(catalog.recordCreatorResearchUrgency(classifierTypeID: "t", creatorID: "c", urgency: 5, threshold: threshold, nowMilliseconds: base - 2 * day + 1))
        // Three recent samples: the stale two prune out, so only these three count.
        XCTAssertNil(catalog.recordCreatorResearchUrgency(classifierTypeID: "t", creatorID: "c", urgency: 5, threshold: threshold, nowMilliseconds: base))
        XCTAssertNil(catalog.recordCreatorResearchUrgency(classifierTypeID: "t", creatorID: "c", urgency: 5, threshold: threshold, nowMilliseconds: base + 1))
        XCTAssertEqual(catalog.recordCreatorResearchUrgency(classifierTypeID: "t", creatorID: "c", urgency: 5, threshold: threshold, nowMilliseconds: base + 2), 5)
    }

    func testAuthorAccumulatorIsPerTypeAndCreatorAndSurvivesCodableRoundTrip() throws {
        var catalog = WorkspaceCatalog()
        let threshold = AuthorResearchThreshold(level: 3, count: 3, windowDays: 30)
        let now: Int64 = 2_000_000_000_000
        _ = catalog.recordCreatorResearchUrgency(classifierTypeID: "t1", creatorID: "c", urgency: 4, threshold: threshold, nowMilliseconds: now)
        _ = catalog.recordCreatorResearchUrgency(classifierTypeID: "t2", creatorID: "c", urgency: 4, threshold: threshold, nowMilliseconds: now)
        XCTAssertEqual(catalog.creatorResearchAccumulators.count, 2)   // keyed per type+creator
        let decoded = try JSONDecoder().decode(WorkspaceCatalog.self, from: JSONEncoder().encode(catalog))
        XCTAssertEqual(decoded.creatorResearchAccumulators.count, 2)   // persisted
    }
}
