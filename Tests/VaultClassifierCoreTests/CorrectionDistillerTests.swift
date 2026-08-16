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

    func testDistillationIsBoundedAndPreservesManualRulesWhenReplaced() {
        let corrections = (0..<10).map {
            correction("\($0)", tagIDs: $0.isMultiple(of: 2) ? ["game"] : ["news"], at: Int64($0))
        }
        let learned = CorrectionDistiller.distill(corrections: corrections, tree: tree, limit: 180)
        XCTAssertFalse(learned.isEmpty)
        XCTAssertLessThanOrEqual(learned.count, 180)
        XCTAssertTrue(learned.contains("Gaming") || learned.contains("News"))

        let combined = CorrectionDistiller.combinedHouseRules(
            manualHouseRules: "Never infer from a thumbnail.",
            learnedRules: learned,
            correctionCount: corrections.count
        )
        XCTAssertTrue(combined?.contains("Never infer from a thumbnail.") == true)
        XCTAssertEqual(CorrectionDistiller.distilledCorrectionCount(in: combined), 10)

        let replaced = CorrectionDistiller.combinedHouseRules(
            manualHouseRules: combined,
            learnedRules: "- New learned rule.",
            correctionCount: 15
        )
        XCTAssertEqual(replaced?.components(separatedBy: CorrectionDistiller.startMarker).count, 2)
        XCTAssertTrue(replaced?.contains("Never infer from a thumbnail.") == true)
        XCTAssertTrue(replaced?.contains("New learned rule") == true)
        XCTAssertFalse(replaced?.contains("Episode") == true)
    }
}
