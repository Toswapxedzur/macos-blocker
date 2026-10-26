import XCTest
import VaultClassifierCore
@testable import VaultClassifierApp

@MainActor
final class ClassifierTypeTaggingWebInputTests: XCTestCase {
    func testTagBoundInputsRejectInvalidPairsAndAllowIndependentBlankDefaults() throws {
        let base: [String: Any] = ["typeID": "type", "speedQuality": "balanced", "strictness": "5"]
        func parse(_ values: [String: Any]) throws -> TaggingSettings {
            try VaultClassifierViewModel.parseClassifierTypeTaggingWebInput(base.merging(values) { _, new in new }).settings
        }
        XCTAssertEqual(try parse(["minimumTagsOverride": "", "maximumTagsOverride": NSNull()]).tagBounds,
                       TagBounds(minimum: 1, maximum: 3))
        XCTAssertEqual(try parse(["minimumTagsOverride": "0", "maximumTagsOverride": "2"]).tagBounds,
                       TagBounds(minimum: 0, maximum: 2))
        XCTAssertEqual(try parse(["minimumTagsOverride": 2, "maximumTagsOverride": 3]).tagBounds,
                       TagBounds(minimum: 2, maximum: 3))
        for invalid: [String: Any] in [
            ["minimumTagsOverride": "2", "maximumTagsOverride": "1"],
            ["strictness": "1", "minimumTagsOverride": "2", "maximumTagsOverride": ""],
            ["minimumTagsOverride": "-1"], ["maximumTagsOverride": "0"],
            ["maximumTagsOverride": "4"], ["minimumTagsOverride": "1.5"],
            ["maximumTagsOverride": 1.5], ["minimumTagsOverride": true],
            ["maximumTagsOverride": "oops"]
        ] { XCTAssertThrowsError(try parse(invalid), "invalid tag counts must not become defaults: \(invalid)") }
    }

    func testStrictnessIsRequiredAndEmptyRulesAreIndependent() throws {
        XCTAssertThrowsError(try VaultClassifierViewModel.parseClassifierTypeTaggingWebInput([
            "typeID": "type", "speedQuality": "", "strictness": ""
        ]))
        XCTAssertThrowsError(try VaultClassifierViewModel.parseClassifierTypeTaggingWebInput([
            "typeID": "type", "speedQuality": "fast"
        ]))
        let input = try VaultClassifierViewModel.parseClassifierTypeTaggingWebInput([
            "typeID": "type", "speedQuality": "best", "strictness": "2", "houseRules": ""
        ])
        XCTAssertEqual(input.settings, TaggingSettings(strictness: .strict))
    }

    func testUnknownPositionsAreRefused() {
        XCTAssertThrowsError(try VaultClassifierViewModel.parseClassifierTypeTaggingWebInput([
            "typeID": "type", "speedQuality": "turbo",
        ]))
        XCTAssertThrowsError(try VaultClassifierViewModel.parseClassifierTypeTaggingWebInput([
            "typeID": "type", "strictness": "9",
        ]))
        XCTAssertThrowsError(try VaultClassifierViewModel.parseClassifierTypeTaggingWebInput([
            "typeID": "type", "strictness": "not-a-number",
        ]))
        XCTAssertThrowsError(try VaultClassifierViewModel.parseClassifierTypeTaggingWebInput([
            "typeID": "", "strictness": "3",
        ]))
    }

    // MARK: - Per-type research switch

    func testResearchModeParsesInheritOnOff() throws {
        XCTAssertNil(try VaultClassifierViewModel.parseClassifierTypeResearchWebInput(["typeID": "type", "researchMode": "inherit"]).researchEnabled)
        XCTAssertNil(try VaultClassifierViewModel.parseClassifierTypeResearchWebInput(["typeID": "type"]).researchEnabled)
        XCTAssertEqual(try VaultClassifierViewModel.parseClassifierTypeResearchWebInput(["typeID": "type", "researchMode": "on"]).researchEnabled, true)
        XCTAssertEqual(try VaultClassifierViewModel.parseClassifierTypeResearchWebInput(["typeID": "type", "researchMode": "off"]).researchEnabled, false)
        XCTAssertThrowsError(try VaultClassifierViewModel.parseClassifierTypeResearchWebInput(["typeID": "type", "researchMode": "maybe"]))
    }

    func testDeletingProviderNullsResearchReferencesWithoutReenablingOrDisabling() {
        let settings = ResearchSettings(
            enabled: true,
            llmProviderProfileID: "llm",
            llmModelIdentifier: "model"
        )

        let withoutLLM = VaultClassifierViewModel.researchSettings(
            settings,
            removingProviderID: "llm"
        )
        XCTAssertTrue(withoutLLM.enabled)
        XCTAssertNil(withoutLLM.llmProviderProfileID)
        XCTAssertNil(withoutLLM.llmModelIdentifier)

        let withoutOther = VaultClassifierViewModel.researchSettings(
            settings,
            removingProviderID: "some-other-profile"
        )
        XCTAssertEqual(withoutOther.llmProviderProfileID, "llm")
        XCTAssertEqual(withoutOther.llmModelIdentifier, "model")
    }
}
