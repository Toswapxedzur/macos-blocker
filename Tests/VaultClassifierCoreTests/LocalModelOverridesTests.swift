import XCTest
@testable import VaultClassifierCore

final class LocalModelOverridesTests: XCTestCase {
    func testInitializerClampsAndSortsThresholdsAndBoundsRules() {
        let value = LocalModelOverrides(
            houseRules: String(repeating: "x", count: 4_100),
            allowDecline: false,
            confidenceThresholds: [2, 0, 0.8, 0.2]
        )
        XCTAssertEqual(value.houseRules?.count, 4_000)
        XCTAssertEqual(value.allowDecline, false)
        XCTAssertEqual(value.confidenceThresholds, [0.001, 0.2, 0.8, 0.999])
        XCTAssertFalse(value.isEmpty)
    }

    func testWrongThresholdCountDropsOnlyThatOverride() {
        let value = LocalModelOverrides(houseRules: "rule", confidenceThresholds: [0.2, 0.4])
        XCTAssertEqual(value.houseRules, "rule")
        XCTAssertNil(value.confidenceThresholds)
    }

    func testCodableRoundTripAndEmptyState() throws {
        XCTAssertTrue(LocalModelOverrides().isEmpty)
        let value = LocalModelOverrides(houseRules: "", allowDecline: true, confidenceThresholds: [0.1, 0.3, 0.6, 0.9])
        let decoded = try JSONDecoder().decode(LocalModelOverrides.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(decoded, value)
        XCTAssertFalse(decoded.isEmpty, "an explicit empty rule string still overrides the global rules")
    }

    func testLocalSettingsResidencyCapClampsAndLegacyDecodeDefaults() throws {
        XCTAssertEqual(LocalLLMSettings(maxResidentModels: 0).maxResidentModels, 1)
        XCTAssertEqual(LocalLLMSettings(maxResidentModels: 99).maxResidentModels, 4)

        let legacy = Data(#"{"engineEnabled":true,"contextTokens":4096}"#.utf8)
        let decoded = try JSONDecoder().decode(LocalLLMSettings.self, from: legacy)
        XCTAssertEqual(decoded.maxResidentModels, 2)
        XCTAssertEqual(
            try JSONDecoder().decode(LocalLLMSettings.self, from: JSONEncoder().encode(decoded)),
            decoded
        )
    }

    func testClassifierSettingsResearchDefaultsOffAndPersists() throws {
        let legacy = Data(#"{"packageUpdateMode":"automatic"}"#.utf8)
        let legacySettings = try JSONDecoder().decode(ClassifierSettings.self, from: legacy)
        XCTAssertFalse(legacySettings.research.enabled)

        let value = ClassifierSettings(research: .init(
            enabled: true,
            llmProviderProfileID: "llm",
            llmModelIdentifier: "model",
            webSearchProviderProfileID: "search",
            requestsPerMinute: 9,
            dailyTokenLimit: 12_345,
            maxSubjectsPerVideo: 2
        ))
        let data = try JSONEncoder().encode(value)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"research\""))
        XCTAssertEqual(try JSONDecoder().decode(ClassifierSettings.self, from: data), value)
    }

    func testResearchSettingsGranularDefaultsDecodeFromLegacyJSON() throws {
        let legacy = Data(#"{"enabled":false,"requestsPerMinute":6,"dailyTokenLimit":10000,"maxSubjectsPerVideo":3}"#.utf8)
        let decoded = try JSONDecoder().decode(ResearchSettings.self, from: legacy)

        XCTAssertEqual(decoded.cooldownHours, 24)
        XCTAssertEqual(decoded.trigger, .declineOnly)
        XCTAssertEqual(decoded.confidenceTriggerLevel, 2)
        XCTAssertEqual(decoded.searchResultCount, 5)
        XCTAssertEqual(decoded.snippetContextChars, 16_000)
        XCTAssertEqual(decoded.knowledgeTTLDays, 0)
        XCTAssertEqual(decoded.maxKnowledgePerVideo, 8)
    }

    func testResearchSettingsGranularControlsClampAtBothBounds() {
        let low = ResearchSettings(
            cooldownHours: 0,
            confidenceTriggerLevel: 0,
            searchResultCount: 0,
            snippetContextChars: 1,
            knowledgeTTLDays: -1,
            maxKnowledgePerVideo: 0
        )
        XCTAssertEqual(low.cooldownHours, 1)
        XCTAssertEqual(low.confidenceTriggerLevel, 1)
        XCTAssertEqual(low.searchResultCount, 1)
        XCTAssertEqual(low.snippetContextChars, 512)
        XCTAssertEqual(low.knowledgeTTLDays, 0)
        XCTAssertEqual(low.maxKnowledgePerVideo, 1)

        let high = ResearchSettings(
            cooldownHours: 9_999,
            confidenceTriggerLevel: 9,
            searchResultCount: 9,
            snippetContextChars: 99_999,
            knowledgeTTLDays: 99_999,
            maxKnowledgePerVideo: 99
        )
        XCTAssertEqual(high.cooldownHours, 720)
        XCTAssertEqual(high.confidenceTriggerLevel, 5)
        XCTAssertEqual(high.searchResultCount, 5)
        XCTAssertEqual(high.snippetContextChars, 19_000)
        XCTAssertEqual(high.knowledgeTTLDays, 3_650)
        XCTAssertEqual(high.maxKnowledgePerVideo, 32)
    }
}
