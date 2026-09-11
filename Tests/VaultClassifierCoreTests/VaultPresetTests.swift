import XCTest
@testable import VaultClassifierCore

final class VaultPresetTests: XCTestCase {
    func testDefaultAndCases() {
        XCTAssertEqual(VaultPreset.default, .balanced)
        XCTAssertEqual(Set(VaultPreset.allCases), [.gentle, .balanced, .strict, .localOnly])
    }

    func testResolveRoundTrips() {
        for preset in VaultPreset.allCases {
            XCTAssertEqual(VaultPreset.resolve(preset.rawValue), preset)
        }
        XCTAssertNil(VaultPreset.resolve(nil))
        XCTAssertNil(VaultPreset.resolve(""))
        XCTAssertNil(VaultPreset.resolve("nonsense"))
    }

    func testLocalModelOverridesDeclineBehavior() {
        // Strict commits to a tag; every other preset declines freely.
        XCTAssertEqual(VaultPreset.strict.localModelOverrides.allowDecline, false)
        for preset in [VaultPreset.gentle, .balanced, .localOnly] {
            XCTAssertEqual(preset.localModelOverrides.allowDecline, true)
        }
        // Thumbnail OCR evidence is on for all presets.
        for preset in VaultPreset.allCases {
            XCTAssertEqual(preset.localModelOverrides.thumbnailOcrEvidence, true)
        }
    }

    func testResearchOverridesProfiles() {
        XCTAssertTrue(VaultPreset.gentle.researchOverrides().enabled)
        XCTAssertEqual(VaultPreset.gentle.researchOverrides().trigger, .declineOnly)

        XCTAssertTrue(VaultPreset.balanced.researchOverrides().enabled)
        XCTAssertEqual(VaultPreset.balanced.researchOverrides().trigger, .declineAndLowConfidence)

        XCTAssertTrue(VaultPreset.strict.researchOverrides().enabled)
        XCTAssertEqual(VaultPreset.strict.researchOverrides().cooldownHours, 12)
        XCTAssertEqual(VaultPreset.strict.researchOverrides().dailyTokenLimit, 20_000)

        // Local-only never reaches the network.
        XCTAssertFalse(VaultPreset.localOnly.researchOverrides().enabled)
    }

    func testConfidenceFloorOrdering() {
        // Stricter presets block on lower confidence (lower floor = more blocking).
        XCTAssertGreaterThan(VaultPreset.gentle.confidenceFloor, VaultPreset.balanced.confidenceFloor)
        XCTAssertGreaterThan(VaultPreset.balanced.confidenceFloor, VaultPreset.strict.confidenceFloor)
    }

    func testMatchesDetectsDrift() {
        let preset = VaultPreset.balanced
        // Freshly-written preset values match.
        XCTAssertTrue(preset.matches(
            localModelOverrides: preset.localModelOverrides,
            researchOverrides: preset.researchOverrides()
        ))
        // A divergent research budget is drift.
        var drifted = preset.researchOverrides()
        drifted.dailyTokenLimit = 999
        XCTAssertFalse(preset.matches(
            localModelOverrides: preset.localModelOverrides,
            researchOverrides: drifted
        ))
        // A divergent decline setting is drift.
        XCTAssertFalse(preset.matches(
            localModelOverrides: LocalModelOverrides(allowDecline: false, thumbnailOcrEvidence: true),
            researchOverrides: preset.researchOverrides()
        ))
        // Model file and provider IDs are user choices, not drift.
        var withProvider = preset.researchOverrides()
        withProvider.llmProviderProfileID = "some-profile"
        XCTAssertTrue(preset.matches(
            localModelOverrides: preset.localModelOverrides,
            researchOverrides: withProvider
        ))
    }

    func testModelFileNameOnlyWhenDownloaded() {
        let ram = 64
        guard let recommended = LocalModelCatalog.recommended(systemRAMGB: ram) else {
            return XCTFail("expected a recommended model for \(ram)GB")
        }
        // Not downloaded → nil (never point a type at a missing model).
        XCTAssertNil(VaultPreset.balanced.modelFileName(systemRAMGB: ram, availableModelFiles: []))
        // Downloaded → the recommended file.
        XCTAssertEqual(
            VaultPreset.balanced.modelFileName(systemRAMGB: ram, availableModelFiles: [recommended.ggufFileName]),
            recommended.ggufFileName
        )
    }
}
