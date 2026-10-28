import XCTest
import VaultClassifierCore
@testable import VaultClassifierApp

@MainActor
final class ClassifierTypeTaggingWebInputTests: XCTestCase {
    func testConfidenceLevelsAndInstructions() throws {
        for level in 1...5 {
            let input = try VaultClassifierViewModel.parseClassifierTypeTaggingWebInput([
                "typeID": "type", "minimumConfidence": String(level), "houseRules": "Keep my vocabulary"
            ])
            XCTAssertEqual(input.settings, TaggingSettings(minimumConfidence: level, houseRules: "Keep my vocabulary"))
        }
    }

    func testMissingOrInvalidConfidenceIsRejected() {
        for value: Any in ["", "0", "6", "1.5", "strong", 2.5, true, NSNull()] {
            XCTAssertThrowsError(try VaultClassifierViewModel.parseClassifierTypeTaggingWebInput([
                "typeID": "type", "minimumConfidence": value
            ]))
        }
        XCTAssertThrowsError(try VaultClassifierViewModel.parseClassifierTypeTaggingWebInput(["typeID": "type"]))
        XCTAssertThrowsError(try VaultClassifierViewModel.parseClassifierTypeTaggingWebInput(["typeID": "", "minimumConfidence": "4"]))
    }
}
