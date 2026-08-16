import XCTest
import VaultClassifierCore
@testable import VaultClassifierApp

@MainActor
final class ClassifierTypeLocalModelWebInputTests: XCTestCase {
    func testDisabledOverrideDoesNotParseHiddenOrEmptyFields() throws {
        let input = try VaultClassifierViewModel.parseClassifierTypeLocalModelWebInput([
            "typeID": "type",
            "overrideEnabled": false,
            "confidenceBand2": "",
            "allowDecline": "not-a-bool",
        ])
        XCTAssertFalse(input.overrideEnabled)
        XCTAssertNil(input.overrides)
    }

    func testPartialOverrideParsesLenientlyAndLetsInitializerDropInvalidBand() throws {
        let input = try VaultClassifierViewModel.parseClassifierTypeLocalModelWebInput([
            "typeID": "type",
            "overrideEnabled": true,
            "houseRules": "Type rule.",
            "confidenceBand2": "0.2",
            "confidenceBand3": "",
        ])
        XCTAssertEqual(input.overrides?.houseRules, "Type rule.")
        XCTAssertNil(input.overrides?.confidenceThresholds)
        XCTAssertNil(input.overrides?.allowDecline)
    }

    func testDeletingProviderNullsResearchReferencesWithoutReenablingOrDisabling() {
        let settings = ResearchSettings(
            enabled: true,
            llmProviderProfileID: "llm",
            llmModelIdentifier: "model",
            webSearchProviderProfileID: "search"
        )

        let withoutLLM = VaultClassifierViewModel.researchSettings(
            settings,
            removingProviderID: "llm"
        )
        XCTAssertTrue(withoutLLM.enabled)
        XCTAssertNil(withoutLLM.llmProviderProfileID)
        XCTAssertNil(withoutLLM.llmModelIdentifier)
        XCTAssertEqual(withoutLLM.webSearchProviderProfileID, "search")

        let withoutSearch = VaultClassifierViewModel.researchSettings(
            settings,
            removingProviderID: "search"
        )
        XCTAssertNil(withoutSearch.webSearchProviderProfileID)
        XCTAssertEqual(withoutSearch.llmProviderProfileID, "llm")
        XCTAssertEqual(withoutSearch.llmModelIdentifier, "model")
    }
}
