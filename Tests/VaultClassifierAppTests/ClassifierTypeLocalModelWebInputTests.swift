import XCTest
import VaultClassifierCore
@testable import VaultClassifierApp

@MainActor
final class ClassifierTypeLocalModelWebInputTests: XCTestCase {
    func testDisabledOverrideDoesNotParseHiddenOrEmptyFields() throws {
        let input = try VaultClassifierViewModel.parseClassifierTypeLocalModelWebInput([
            "typeID": "type",
            "overrideEnabled": false,
            "modelFileName": "selected.gguf",
            "confidenceBand2": "",
            "allowDecline": "not-a-bool",
        ])
        XCTAssertFalse(input.overrideEnabled)
        XCTAssertEqual(input.modelFileName, "selected.gguf")
        XCTAssertNil(input.overrides)
    }

    func testPartialOverrideParsesLenientlyAndLetsInitializerDropInvalidBand() throws {
        let input = try VaultClassifierViewModel.parseClassifierTypeLocalModelWebInput([
            "typeID": "type",
            "overrideEnabled": true,
            "modelFileName": "",
            "houseRules": "Type rule.",
            "confidenceBand2": "0.2",
            "confidenceBand3": "",
        ])
        XCTAssertEqual(input.overrides?.houseRules, "Type rule.")
        XCTAssertNil(input.modelFileName)
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

    func testDisabledResearchOverrideDoesNotParseHiddenOrEmptyFields() throws {
        let input = try VaultClassifierViewModel.parseClassifierTypeResearchWebInput([
            "typeID": "type",
            "overrideEnabled": false,
            "enabled": "not-a-bool",
            "requestsPerMinute": "",
        ])
        XCTAssertFalse(input.overrideEnabled)
        XCTAssertNil(input.settings)
    }

    func testResearchOverrideParsingIsLenientAndInitializerClampsValues() throws {
        let input = try VaultClassifierViewModel.parseClassifierTypeResearchWebInput([
            "typeID": "type",
            "overrideEnabled": true,
            "enabled": false,
            "llmProviderProfileID": " llm ",
            "requestsPerMinute": "999",
            "dailyTokenLimit": "not-a-number",
            "maxSubjectsPerVideo": "0",
            "cooldownHours": "900",
            "trigger": "all",
            "confidenceTriggerLevel": "9",
            "searchResultCount": "0",
            "snippetContextChars": "100",
            "knowledgeTTLDays": "not-a-number",
            "maxKnowledgePerVideo": "100",
        ])
        XCTAssertTrue(input.overrideEnabled)
        XCTAssertFalse(input.settings?.enabled ?? true)
        XCTAssertEqual(input.settings?.llmProviderProfileID, "llm")
        XCTAssertEqual(input.settings?.requestsPerMinute, ResearchSettings.maximumRequestsPerMinute)
        XCTAssertEqual(input.settings?.dailyTokenLimit, ResearchSettings().dailyTokenLimit)
        XCTAssertEqual(input.settings?.maxSubjectsPerVideo, 1)
        XCTAssertEqual(input.settings?.cooldownHours, 720)
        XCTAssertEqual(input.settings?.trigger, .all)
        XCTAssertEqual(input.settings?.confidenceTriggerLevel, 5)
        XCTAssertEqual(input.settings?.searchResultCount, 1)
        XCTAssertEqual(input.settings?.snippetContextChars, 512)
        XCTAssertEqual(input.settings?.knowledgeTTLDays, 0)
        XCTAssertEqual(input.settings?.maxKnowledgePerVideo, 32)
    }
}
