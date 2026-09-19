import XCTest
import VaultClassifierCore
@testable import VaultClassifierApp

@MainActor
final class ClassifierTypeLocalModelWebInputTests: XCTestCase {
    func testModelLibraryPayloadMarksDownloadedCatalogFileAndProgress() throws {
        let downloadedEntry = try XCTUnwrap(LocalModelCatalog.curated.first)
        let downloadingEntry = try XCTUnwrap(LocalModelCatalog.curated.dropFirst().first)
        let payload = VaultClassifierViewModel.modelLibraryPayload(
            availableModelFiles: ["manual.gguf", downloadedEntry.ggufFileName],
            downloadFractions: [downloadingEntry.id: 0.4],
            systemRAMGB: 16
        )

        let downloaded = try XCTUnwrap(payload.first { ($0["id"] as? String) == downloadedEntry.id })
        XCTAssertEqual((downloaded["state"] as? [String: Any])?["kind"] as? String, "downloaded")
        let downloading = try XCTUnwrap(payload.first { ($0["id"] as? String) == downloadingEntry.id })
        XCTAssertEqual((downloading["state"] as? [String: Any])?["kind"] as? String, "downloading")
        XCTAssertEqual((downloading["state"] as? [String: Any])?["fraction"] as? Double, 0.4)
        XCTAssertTrue(downloaded["latencyBand"] is NSNull)
        XCTAssertTrue(downloading["latencyBand"] is NSNull)
        XCTAssertEqual(payload.filter { ($0["recommended"] as? Bool) == true }.count, 1)
    }

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
        XCTAssertNil(input.overrides?.maximumTags)
    }

    func testPerTypeMaximumTagsParsesAndClampsElseInherits() throws {
        func parse(_ value: String) throws -> LocalModelOverrides? {
            try VaultClassifierViewModel.parseClassifierTypeLocalModelWebInput([
                "typeID": "type", "overrideEnabled": true, "maximumTags": value,
            ]).overrides
        }
        XCTAssertEqual(try parse("3")?.maximumTags, 3)
        XCTAssertEqual(try parse("99")?.maximumTags, 16)   // clamped high
        XCTAssertEqual(try parse("0")?.maximumTags, 1)     // clamped low
        // Blank / unparseable → nil = inherit the global cap; with nothing else
        // set the whole override collapses to nil.
        XCTAssertNil(try parse("  "))
        XCTAssertNil(try parse("not-a-number"))
    }

    func testEffectiveMaximumTagsPrefersOverrideElseGlobal() {
        XCTAssertEqual(LocalModelOverrides(maximumTags: 2).effectiveMaximumTags(global: 5), 2)
        XCTAssertEqual(LocalModelOverrides().effectiveMaximumTags(global: 5), 5)
        XCTAssertEqual(LocalModelOverrides(maximumTags: 99).maximumTags, 16)
        XCTAssertEqual(LocalModelOverrides(maximumTags: 0).maximumTags, 1)
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
            "cooldownHours": "900",
            "urgencyFloor": "9",
            "authorLevel": "0",
            "authorCount": "not-a-number",
            "authorWindowDays": "99999",
            "knowledgeTTLDays": "not-a-number",
            "maxKnowledgePerVideo": "100",
        ])
        XCTAssertTrue(input.overrideEnabled)
        XCTAssertFalse(input.settings?.enabled ?? true)
        XCTAssertEqual(input.settings?.llmProviderProfileID, "llm")
        XCTAssertEqual(input.settings?.requestsPerMinute, ResearchSettings.maximumRequestsPerMinute)
        XCTAssertEqual(input.settings?.dailyTokenLimit, ResearchSettings().dailyTokenLimit)
        XCTAssertEqual(input.settings?.cooldownHours, 720)
        XCTAssertEqual(input.settings?.urgencyFloor, 5)
        XCTAssertEqual(input.settings?.authorThreshold.level, 1)
        XCTAssertEqual(input.settings?.authorThreshold.count, AuthorResearchThreshold.defaultCount)
        XCTAssertEqual(input.settings?.authorThreshold.windowDays, AuthorResearchThreshold.maximumWindowDays)
        XCTAssertEqual(input.settings?.knowledgeTTLDays, 0)
        XCTAssertEqual(input.settings?.maxKnowledgePerVideo, 32)
    }
}
