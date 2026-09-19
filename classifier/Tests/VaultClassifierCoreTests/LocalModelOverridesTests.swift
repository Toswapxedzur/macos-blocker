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
            urgencyFloor: 4,
            authorThreshold: .init(level: 4, count: 7, windowDays: 14)
        ))
        let data = try JSONEncoder().encode(value)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"research\""))
        XCTAssertEqual(try JSONDecoder().decode(ClassifierSettings.self, from: data), value)
    }

    func testResearchSettingsGranularDefaultsDecodeFromLegacyJSON() throws {
        let legacy = Data(#"{"enabled":false,"requestsPerMinute":6,"dailyTokenLimit":10000,"maxSubjectsPerVideo":3}"#.utf8)
        let decoded = try JSONDecoder().decode(ResearchSettings.self, from: legacy)

        XCTAssertEqual(decoded.cooldownHours, 24)
        XCTAssertEqual(decoded.urgencyFloor, 5, "no legacy trigger = the old declines-only default")
        XCTAssertEqual(decoded.authorThreshold, AuthorResearchThreshold())
        XCTAssertEqual(decoded.knowledgeTTLDays, 0)
        XCTAssertEqual(decoded.maxKnowledgePerVideo, 8)
    }

    /// Pre-redesign states carried `trigger` + `confidenceTriggerLevel`; they must
    /// migrate to the equivalent urgency floor, and the retired keys never re-encode.
    func testLegacyTriggerMigratesToEquivalentUrgencyFloor() throws {
        func floor(_ json: String) throws -> Int {
            try JSONDecoder().decode(ResearchSettings.self, from: Data(json.utf8)).urgencyFloor
        }
        XCTAssertEqual(try floor(#"{"trigger":"declineOnly","confidenceTriggerLevel":4}"#), 5)
        XCTAssertEqual(try floor(#"{"trigger":"correctionsOnly"}"#), 5)
        XCTAssertEqual(try floor(#"{"trigger":"declineAndLowConfidence"}"#), 4)            // level 2 → 6−2
        XCTAssertEqual(try floor(#"{"trigger":"all","confidenceTriggerLevel":3}"#), 3)      // 6−3
        XCTAssertEqual(try floor(#"{"trigger":"all","confidenceTriggerLevel":5}"#), 1)
        // An explicit new value always wins over the legacy keys.
        XCTAssertEqual(try floor(#"{"trigger":"all","confidenceTriggerLevel":5,"urgencyFloor":4}"#), 4)

        let migrated = try JSONDecoder().decode(ResearchSettings.self, from: Data(#"{"trigger":"all","maxSubjectsPerVideo":2}"#.utf8))
        let reencoded = String(decoding: try JSONEncoder().encode(migrated), as: UTF8.self)
        for retired in ["\"trigger\"", "confidenceTriggerLevel", "maxSubjectsPerVideo"] {
            XCTAssertFalse(reencoded.contains(retired))
        }
    }

    func testResearchSettingsGranularControlsClampAtBothBounds() {
        let low = ResearchSettings(
            cooldownHours: 0,
            urgencyFloor: 0,
            knowledgeTTLDays: -1,
            maxKnowledgePerVideo: 0
        )
        XCTAssertEqual(low.cooldownHours, 1)
        XCTAssertEqual(low.urgencyFloor, 1)
        XCTAssertEqual(low.knowledgeTTLDays, 0)
        XCTAssertEqual(low.maxKnowledgePerVideo, 1)

        let high = ResearchSettings(
            cooldownHours: 9_999,
            urgencyFloor: 9,
            knowledgeTTLDays: 99_999,
            maxKnowledgePerVideo: 99
        )
        XCTAssertEqual(high.cooldownHours, 720)
        XCTAssertEqual(high.urgencyFloor, 5)
        XCTAssertEqual(high.knowledgeTTLDays, 3_650)
        XCTAssertEqual(high.maxKnowledgePerVideo, 32)
    }
}
