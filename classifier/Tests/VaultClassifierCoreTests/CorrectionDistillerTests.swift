import XCTest
@testable import VaultClassifierCore

final class CorrectionDistillerTests: XCTestCase {
    private let tree = TagTreeAsset(name: "Topics", nodes: [
        .init(id: "game", name: "Gaming"),
        .init(id: "news", name: "News"),
    ])

    private func correction(_ entryID: String, tagIDs: [String], at time: Int64) -> CorrectionExample {
        .init(
            classifierTypeID: "type",
            platformID: "youtube",
            entryID: entryID,
            creatorID: "creator",
            title: "Episode \(entryID)",
            correctTagIDs: tagIDs,
            note: "User preference",
            createdAtMilliseconds: time
        )
    }

    func testCatalogCorrectionWriterDeduplicatesByIdentityAndBoundsStore() {
        var catalog = WorkspaceCatalog()
        catalog.appendCorrectionExample(correction("same", tagIDs: ["game"], at: 1))
        let stableID = catalog.correctionExamples[0].id
        catalog.appendCorrectionExample(correction("same", tagIDs: ["news"], at: 2))
        XCTAssertEqual(catalog.correctionExamples.count, 1)
        XCTAssertEqual(catalog.correctionExamples[0].id, stableID)
        XCTAssertEqual(catalog.correctionExamples[0].correctTagIDs, ["news"])

        for index in 0...WorkspaceCatalog.maximumCorrectionExamples {
            catalog.appendCorrectionExample(correction("entry-\(index)", tagIDs: ["game"], at: Int64(index + 3)))
        }
        XCTAssertEqual(catalog.correctionExamples.count, WorkspaceCatalog.maximumCorrectionExamples)
        XCTAssertEqual(catalog.correctionExamples.first?.entryID, "entry-\(WorkspaceCatalog.maximumCorrectionExamples)")
    }

    func testLegacyLearnedBlockIsStrippedAndManualRulesSurvive() {
        let stored = "Prefer specific tags.\n\n[Learned preferences; 5 corrections]\n4. If the video contains information about Samsung products, tag it with Sports.\n[/Learned preferences]\nNever tag ads."
        XCTAssertTrue(CorrectionDistiller.containsLearnedPreferences(stored))
        let manual = CorrectionDistiller.manualRules(from: stored)
        XCTAssertFalse(manual.contains("Samsung"))
        XCTAssertTrue(manual.contains("Prefer specific tags.") && manual.contains("Never tag ads."))
        // An unterminated block (the real stored one was cut off mid-sentence) loses everything after the marker.
        XCTAssertEqual(CorrectionDistiller.manualRules(from: "Keep me.\n[Learned preferences; 3 corrections]\n1. junk"), "Keep me.")
        XCTAssertEqual(CorrectionDistiller.manualRules(from: nil), "")
        XCTAssertFalse(CorrectionDistiller.containsLearnedPreferences("just my own rules"))
    }
}
