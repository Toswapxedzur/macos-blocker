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
}
