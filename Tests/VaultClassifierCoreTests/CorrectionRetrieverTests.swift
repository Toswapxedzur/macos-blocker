import XCTest
@testable import VaultClassifierCore

final class CorrectionRetrieverTests: XCTestCase {
    private func tree() -> TagTreeAsset {
        TagTreeAsset(name: "Topics", nodes: [
            .init(id: "tech", name: "Tech"),
            .init(id: "games", name: "Games"),
            .init(id: "music", name: "Music"),
        ])
    }

    private func correction(
        id: String, entryID: String = "e", creatorID: String, title: String,
        tagIDs: [String], note: String? = nil, at ms: Int64 = 1_000
    ) -> CorrectionExample {
        CorrectionExample(
            id: id, classifierTypeID: "type", platformID: "youtube",
            entryID: entryID, creatorID: creatorID, title: title,
            correctTagIDs: tagIDs, note: note, createdAtMilliseconds: ms
        )
    }

    func testRanksLexicallySimilarTitlesHighest() {
        let corrections = [
            correction(id: "1", creatorID: "cB", title: "Lofi beats to study", tagIDs: ["music"]),
            correction(id: "2", creatorID: "cC", title: "Galaxy S24 Ultra review", tagIDs: ["tech"]),
            correction(id: "3", creatorID: "cD", title: "iPhone 16 Pro camera review", tagIDs: ["tech"]),
        ]
        let result = CorrectionRetriever.retrieve(
            title: "Galaxy S24 camera review",
            creatorID: "cA", excludingEntryID: nil,
            from: corrections, tree: tree(), limit: 2
        )
        XCTAssertEqual(result.count, 2)
        // Both surviving exemplars share tokens with the query; the unrelated
        // "Lofi beats" correction shares none and is excluded.
        XCTAssertEqual(result.map(\.title).sorted(), ["Galaxy S24 Ultra review", "iPhone 16 Pro camera review"])
        XCTAssertFalse(result.contains { $0.title.contains("Lofi") })
        // The best lexical match ranks first.
        XCTAssertEqual(result.first?.title, "Galaxy S24 Ultra review")
        XCTAssertEqual(result.first?.tagNames, ["Tech"])
    }

    func testSameCreatorIsAlwaysEligibleAndOutranksLexicalOnly() {
        let corrections = [
            // Same creator, zero token overlap — still eligible and dominant.
            correction(id: "1", creatorID: "cA", title: "Completely unrelated words", tagIDs: ["games"]),
            // Different creator, strong overlap.
            correction(id: "2", creatorID: "cZ", title: "Space marine campaign playthrough", tagIDs: ["games"]),
        ]
        let result = CorrectionRetriever.retrieve(
            title: "Space marine campaign review",
            creatorID: "cA", excludingEntryID: nil,
            from: corrections, tree: tree(), limit: 5
        )
        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result[0].sameCreator, "same-creator correction ranks first")
        XCTAssertEqual(result[0].title, "Completely unrelated words")
    }

    func testExcludesTheVideosOwnCorrectionAndRespectsLimit() {
        let corrections = (0..<10).map {
            correction(id: "\($0)", entryID: "e\($0)", creatorID: "cA", title: "Games episode \($0)", tagIDs: ["games"], at: Int64(1_000 + $0))
        }
        let result = CorrectionRetriever.retrieve(
            title: "Games episode finale",
            creatorID: "cA", excludingEntryID: "e7",
            from: corrections, tree: tree(), limit: 3
        )
        XCTAssertEqual(result.count, 3, "limit is respected")
        XCTAssertFalse(result.contains { $0.title == "Games episode 7" }, "the video's own correction is excluded")
    }

    func testNoTagCorrectionSurvivesButDroppedTagDoesNot() {
        let corrections = [
            // Deliberate "no tag" decision — a valid exemplar.
            correction(id: "1", creatorID: "cA", title: "Random vlog moment", tagIDs: []),
            // Tags that no longer exist in the tree — not a usable exemplar.
            correction(id: "2", creatorID: "cA", title: "Old taxonomy clip", tagIDs: ["deleted-tag"]),
        ]
        let result = CorrectionRetriever.retrieve(
            title: "Some clip",
            creatorID: "cA", excludingEntryID: nil,
            from: corrections, tree: tree(), limit: 5
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].title, "Random vlog moment")
        XCTAssertTrue(result[0].tagNames.isEmpty, "no-tag decision preserved")
    }

    func testEmptyWhenNothingRelevantAndNoCreatorMatch() {
        let corrections = [
            correction(id: "1", creatorID: "cB", title: "Lofi beats to study", tagIDs: ["music"]),
        ]
        let result = CorrectionRetriever.retrieve(
            title: "Formula 1 race highlights",
            creatorID: "cA", excludingEntryID: nil,
            from: corrections, tree: tree(), limit: 5
        )
        XCTAssertTrue(result.isEmpty, "no lexical overlap and no creator match → no exemplars")
    }

    func testStopwordsAndShortTokensDoNotManufactureSimilarity() {
        // The only shared tokens are stopwords / 1-char noise — not a match.
        let corrections = [
            correction(id: "1", creatorID: "cB", title: "How to a the of", tagIDs: ["tech"]),
        ]
        let result = CorrectionRetriever.retrieve(
            title: "How to the a of",
            creatorID: "cA", excludingEntryID: nil,
            from: corrections, tree: tree(), limit: 5
        )
        XCTAssertTrue(result.isEmpty, "stopword-only overlap is not similarity")
    }
}
