import Foundation
import XCTest
import VaultClassifierCore
@testable import VaultClassifierApp

final class WebShellLiveWorkspaceTests: XCTestCase {
    func testBundledShellContainsOnlyLiveWorkspacesAndActions() throws {
        let appURL = try XCTUnwrap(VaultClassifierBundledAssets.url(named: "app", extension: "js"))
        let script = try String(contentsOf: appURL, encoding: .utf8)

        for liveWorkspace in ["browserBridge"] {
            XCTAssertTrue(script.contains(liveWorkspace))
        }
        for retired in [
            "llmAssist", "llmAssistWorkspace",
            "recordCreatorClassification", "classifyWithLLM", "markCorrection",
            "clearCorrection", "storeTraining", "retrain", "activityWorkspace",
            "inspectWorkspace", "trainingWorkspace", "localModelWorkspace",
            "model-panel", "llmAssistConfiguration", "createLocalModel",
            "configureLocalModel", "selectLLMProvider",
            // The History page (owner 2026-09-30): collection lives in a type's Options.
            "classificationData", "loadCreatorEntries", "receiveCreatorEntries",
            "submitCorrection", "setActiveClassifierType", "addCollectionPlatform",
            "confirmDeleteCollectionPlatform", "clearCollectionDiagnostics",
        ] {
            XCTAssertFalse(script.contains(retired), "Retired web action or workspace remains: \(retired)")
        }
    }

    /// Each group contains independent dials and house rules.

    /// Research is on/off + provider; every budget, cooldown, trigger and knowledge
    /// field is a constant and must be gone from both forms.



    func testProviderWorkspaceDisclosesLocalOnlyCredentialStorage() throws {
        let appURL = try XCTUnwrap(VaultClassifierBundledAssets.url(named: "app", extension: "js"))
        let stringsURL = try XCTUnwrap(VaultClassifierBundledAssets.url(named: "strings", extension: "js"))
        let script = try String(contentsOf: appURL, encoding: .utf8)
        let strings = try String(contentsOf: stringsURL, encoding: .utf8)

        // The direct key field keeps the storage/billing disclosure in its Info.
        XCTAssertTrue(script.contains("llm.localOnlyDisclosure"))
        XCTAssertTrue(script.contains("connections.apiBilling"))
        XCTAssertTrue(script.contains("data-tagging-key-fields"))
        XCTAssertFalse(script.contains("provider-local-only"))
        // The copy distinguishes local storage from authentication requests sent to the provider.
        XCTAssertTrue(strings.contains("stored in this app’s support folder on this device"))
        XCTAssertTrue(strings.contains("Keys are sent to the configured provider to authenticate requests"))
        XCTAssertTrue(strings.contains("not in the system Keychain"))
    }

    /// Research is provider-grounding only (Cut A): the shell must not offer a
    /// search mode, a web-search provider, or the raw-search tuning fields, must
    /// offer only grounding-capable providers, and must retire Serper/You.com.




    func testRetiredLocalRuntimeHasNoProductionControls() throws {
        let url = try XCTUnwrap(VaultClassifierBundledAssets.url(named: "app", extension: "js"))
        let script = try String(contentsOf: url, encoding: .utf8)
        for retired in ["speedQualityCards", "downloadModel", "cancelModelDownload", "deleteModelFile", "localModelResidentNote"] {
            XCTAssertFalse(script.contains(retired), "Retired Local control remains: \(retired)")
        }
        XCTAssertTrue(script.contains("CONFIDENCE_CHOICES"))
        XCTAssertTrue(script.contains("cloud.chooseModel"))
    }

    func testCreateGroupFlowAsksOnlyForPlatformAndName() throws {
        let appURL = try XCTUnwrap(VaultClassifierBundledAssets.url(named: "app", extension: "js"))
        let script = try String(contentsOf: appURL, encoding: .utf8)
        // Creating a group opens the dialog; there is no direct-create path.
        XCTAssertTrue(script.contains("createTypeModal"))
        XCTAssertTrue(script.contains("pendingCreateType"))
        XCTAssertTrue(script.contains("confirmCreateType"))
        XCTAssertTrue(script.contains("cancelCreateType"))
        let confirmStart = try XCTUnwrap(script.range(of: "action === \"confirmCreateType\""))
        let confirmBody = String(script[confirmStart.lowerBound...].prefix(1000))
        XCTAssertTrue(confirmBody.contains("send(\"createClassifierType\", { name, platformIDs })"))
        XCTAssertFalse(script.contains("send(\"createClassifierType\", { name: t(\"navigation.newType\")"))
        // Presets are gone: no picker, no provenance badge.
        for retired in ["preset", "selectCreatePreset", "modifiedFromPreset", "presetNameKey"] {
            XCTAssertFalse(script.lowercased().contains(retired.lowercased()), "preset remnant in the shell: \(retired)")
        }

        let stringsURL = try XCTUnwrap(VaultClassifierBundledAssets.url(named: "strings", extension: "js"))
        let strings = try String(contentsOf: stringsURL, encoding: .utf8)
        for key in ["createType.title", "createType.platformLabel", "createType.nameLabel", "createType.create"] {
            XCTAssertTrue(strings.contains(key), "missing create string: \(key)")
        }
        XCTAssertFalse(strings.contains("\"preset."))
    }
}
