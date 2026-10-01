import XCTest
import VaultClassifierCore
@testable import VaultClassifierApp

@MainActor
final class ClassifierTypeLocalModelWebInputTests: XCTestCase {
    func testModelLibraryPayloadMarksDownloadedCatalogFileAndProgress() throws {
        let downloadedEntry = LocalModelCatalog.entry(for: .fast)
        let downloadingEntry = LocalModelCatalog.entry(for: .balanced)
        let payload = VaultClassifierViewModel.modelLibraryPayload(
            availableModelFiles: ["manual.gguf", downloadedEntry.ggufFileName],
            downloadFractions: [downloadingEntry.id: 0.4],
            systemRAMGB: 16
        )

        XCTAssertEqual(payload.count, 3, "one row per Speed↔Quality tier")
        let downloaded = try XCTUnwrap(payload.first { ($0["id"] as? String) == downloadedEntry.id })
        XCTAssertEqual((downloaded["state"] as? [String: Any])?["kind"] as? String, "downloaded")
        XCTAssertEqual(downloaded["tier"] as? String, "fast")
        let downloading = try XCTUnwrap(payload.first { ($0["id"] as? String) == downloadingEntry.id })
        XCTAssertEqual((downloading["state"] as? [String: Any])?["kind"] as? String, "downloading")
        XCTAssertEqual((downloading["state"] as? [String: Any])?["fraction"] as? Double, 0.4)
        XCTAssertEqual(downloading["tier"] as? String, "balanced")
        XCTAssertNil(downloaded["latencyBand"], "the unmeasured latency band was retired")
        XCTAssertEqual(payload.filter { ($0["recommended"] as? Bool) == true }.map { $0["tier"] as? String }, ["balanced"])
    }

    // MARK: - Per-type local model form

    func testBothDialPositionsAreRequiredAndEmptyRulesAreIndependent() throws {
        XCTAssertThrowsError(try VaultClassifierViewModel.parseClassifierTypeLocalModelWebInput([
            "typeID": "type", "speedQuality": "", "strictness": ""
        ]))
        XCTAssertThrowsError(try VaultClassifierViewModel.parseClassifierTypeLocalModelWebInput([
            "typeID": "type", "speedQuality": "fast"
        ]))
        let input = try VaultClassifierViewModel.parseClassifierTypeLocalModelWebInput([
            "typeID": "type", "speedQuality": "best", "strictness": "2", "houseRules": ""
        ])
        XCTAssertEqual(input.settings, LocalLLMSettings(speedQuality: .best, strictness: .strict))
    }

    func testUnknownPositionsAreRefused() {
        XCTAssertThrowsError(try VaultClassifierViewModel.parseClassifierTypeLocalModelWebInput([
            "typeID": "type", "speedQuality": "turbo",
        ]))
        XCTAssertThrowsError(try VaultClassifierViewModel.parseClassifierTypeLocalModelWebInput([
            "typeID": "type", "strictness": "9",
        ]))
        XCTAssertThrowsError(try VaultClassifierViewModel.parseClassifierTypeLocalModelWebInput([
            "typeID": "type", "strictness": "not-a-number",
        ]))
        XCTAssertThrowsError(try VaultClassifierViewModel.parseClassifierTypeLocalModelWebInput([
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
