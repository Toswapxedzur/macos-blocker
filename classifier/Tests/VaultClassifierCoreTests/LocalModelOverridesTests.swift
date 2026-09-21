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
            requestsPerMinute: 9,
            dailyTokenLimit: 12_345,
            authorThreshold: .init(level: 3.5, count: 7, windowDays: 14)
        ))
        let data = try JSONEncoder().encode(value)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"research\""))
        XCTAssertEqual(try JSONDecoder().decode(ClassifierSettings.self, from: data), value)
    }

    func testResearchSettingsGranularDefaultsDecodeFromLegacyJSON() throws {
        let legacy = Data(#"{"enabled":false,"requestsPerMinute":6,"dailyTokenLimit":10000,"maxSubjectsPerVideo":3}"#.utf8)
        let decoded = try JSONDecoder().decode(ResearchSettings.self, from: legacy)

        XCTAssertEqual(decoded.cooldownHours, 24)
        XCTAssertEqual(decoded.authorThreshold, AuthorResearchThreshold())
        XCTAssertEqual(decoded.knowledgeTTLDays, 0)
        XCTAssertEqual(decoded.maxKnowledgePerVideo, 8)
    }

    /// Every per-video trigger key ever persisted (`trigger`, `confidenceTriggerLevel`,
    /// `urgencyFloor`) is retired with the trigger itself: old states still decode,
    /// the keys never re-encode, and a whole-number creator level reads as before.
    func testRetiredTriggerKeysDecodeAndNeverReencode() throws {
        let old = #"{"trigger":"all","confidenceTriggerLevel":5,"urgencyFloor":4,"maxSubjectsPerVideo":2,"authorThreshold":{"level":3,"count":5,"windowDays":30}}"#
        let migrated = try JSONDecoder().decode(ResearchSettings.self, from: Data(old.utf8))
        XCTAssertEqual(migrated.authorThreshold, AuthorResearchThreshold(level: 3, count: 5, windowDays: 30))
        let reencoded = String(decoding: try JSONEncoder().encode(migrated), as: UTF8.self)
        for retired in ["\"trigger\"", "confidenceTriggerLevel", "urgencyFloor", "maxSubjectsPerVideo"] {
            XCTAssertFalse(reencoded.contains(retired))
        }
    }

    /// The creator level is the research-frequency knob: half steps, 1…5, default
    /// 3.5 (3 is merely an average creator).
    func testCreatorLevelIsAHalfStepWithinBounds() {
        XCTAssertEqual(AuthorResearchThreshold().level, 3.5)
        XCTAssertEqual(AuthorResearchThreshold(level: 3.3).level, 3.5)
        XCTAssertEqual(AuthorResearchThreshold(level: 0).level, 1)
        XCTAssertEqual(AuthorResearchThreshold(level: 9).level, 5)
    }

    func testResearchSettingsGranularControlsClampAtBothBounds() {
        let low = ResearchSettings(
            cooldownHours: 0,
            knowledgeTTLDays: -1,
            maxKnowledgePerVideo: 0
        )
        XCTAssertEqual(low.cooldownHours, 1)
        XCTAssertEqual(low.knowledgeTTLDays, 0)
        XCTAssertEqual(low.maxKnowledgePerVideo, 1)

        let high = ResearchSettings(
            cooldownHours: 9_999,
            knowledgeTTLDays: 99_999,
            maxKnowledgePerVideo: 99
        )
        XCTAssertEqual(high.cooldownHours, 720)
        XCTAssertEqual(high.knowledgeTTLDays, 3_650)
        XCTAssertEqual(high.maxKnowledgePerVideo, 32)
    }
}
