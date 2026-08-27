import Foundation
import XCTest
@testable import VaultClassifierApp

final class WebShellLiveWorkspaceTests: XCTestCase {
    func testBundledShellContainsOnlyLiveWorkspacesAndActions() throws {
        let appURL = try XCTUnwrap(VaultClassifierWebShell.bundledWebAssetURL(named: "app", extension: "js"))
        let script = try String(contentsOf: appURL, encoding: .utf8)

        for liveWorkspace in ["tagTree", "llmAssist", "browserBridge", "classificationData"] {
            XCTAssertTrue(script.contains(liveWorkspace))
        }
        for retired in [
            "recordCreatorClassification", "classifyWithLLM", "markCorrection",
            "clearCorrection", "storeTraining", "retrain", "activityWorkspace",
            "inspectWorkspace", "trainingWorkspace", "localModelWorkspace",
            "model-panel", "llmAssistConfiguration", "createLocalModel",
            "configureLocalModel", "selectLLMProvider",
        ] {
            XCTAssertFalse(script.contains(retired), "Retired web action or workspace remains: \(retired)")
        }
    }

    func testPolicyEditorExposesContentBlockKnobs() throws {
        let appURL = try XCTUnwrap(VaultClassifierWebShell.bundledWebAssetURL(named: "app", extension: "js"))
        let script = try String(contentsOf: appURL, encoding: .utf8)
        // The two user-tunable content-block knobs must reach the policy form,
        // with data-field keys matching the savePolicy hub action.
        XCTAssertTrue(script.contains("\"confidenceFloor\""), "confidence floor control missing from policy editor")
        XCTAssertTrue(script.contains("\"untaggedAction\""), "untagged-action control missing from policy editor")

        let stringsURL = try XCTUnwrap(VaultClassifierWebShell.bundledWebAssetURL(named: "strings", extension: "js"))
        let strings = try String(contentsOf: stringsURL, encoding: .utf8)
        for key in ["policies.confidenceFloor", "policies.untaggedAction", "policies.floor5"] {
            XCTAssertTrue(strings.contains(key), "missing policy string: \(key)")
        }
    }

    func testShellRetainsVideoCollectionLazyLoadChannel() throws {
        let appURL = try XCTUnwrap(VaultClassifierWebShell.bundledWebAssetURL(named: "app", extension: "js"))
        let script = try String(contentsOf: appURL, encoding: .utf8)
        XCTAssertTrue(script.contains("loadCreatorEntries"))
        XCTAssertTrue(script.contains("receiveCreatorEntries"))
        XCTAssertTrue(script.contains("classificationDataWorkspace"))
    }

    func testShellContainsOnlyEffectivePerTypeLocalModelOverrides() throws {
        let appURL = try XCTUnwrap(VaultClassifierWebShell.bundledWebAssetURL(named: "app", extension: "js"))
        let script = try String(contentsOf: appURL, encoding: .utf8)
        XCTAssertTrue(script.contains("saveClassifierTypeLocalModel"))
        XCTAssertTrue(script.contains("toggleLocalModelAdvanced"))
        XCTAssertTrue(script.contains("classifier-local-model-form-"))
        XCTAssertTrue(script.contains("modelFileName"))
        XCTAssertTrue(script.contains("localModelResidentNote"))
        let overrideStart = try XCTUnwrap(script.range(of: "const localModelOverrideBody"))
        let overrideEnd = try XCTUnwrap(script.range(of: "const localModelOverrideSection", range: overrideStart.upperBound..<script.endIndex))
        let overrideBody = String(script[overrideStart.lowerBound..<overrideEnd.lowerBound])
        XCTAssertTrue(overrideBody.contains("houseRules"))
        XCTAssertTrue(overrideBody.contains("allowDecline"))
        XCTAssertTrue(overrideBody.contains("confidenceBand"))
        XCTAssertFalse(overrideBody.contains("maximumTags"))
    }

    func testShellGroupsGranularResearchControlsGloballyAndPerType() throws {
        let appURL = try XCTUnwrap(VaultClassifierWebShell.bundledWebAssetURL(named: "app", extension: "js"))
        let script = try String(contentsOf: appURL, encoding: .utf8)
        for field in [
            "cooldownHours", "confidenceTriggerLevel", "searchResultCount",
            "snippetContextChars", "knowledgeTTLDays", "maxKnowledgePerVideo",
        ] {
            XCTAssertGreaterThanOrEqual(script.components(separatedBy: field).count - 1, 2)
        }
        for group in ["research.group.frequency", "research.group.trigger", "research.group.search"] {
            XCTAssertGreaterThanOrEqual(script.components(separatedBy: group).count - 1, 2)
        }
    }

    func testKnowledgeWorkspaceExposesCreatorAndTermManagement() throws {
        let appURL = try XCTUnwrap(VaultClassifierWebShell.bundledWebAssetURL(named: "app", extension: "js"))
        let stringsURL = try XCTUnwrap(VaultClassifierWebShell.bundledWebAssetURL(named: "strings", extension: "js"))
        let script = try String(contentsOf: appURL, encoding: .utf8)
        let strings = try String(contentsOf: stringsURL, encoding: .utf8)

        // A dedicated Knowledge workspace, reachable from the sidebar.
        XCTAssertTrue(script.contains("knowledgeWorkspace"))
        XCTAssertTrue(script.contains("navButton(\"knowledge\""))
        XCTAssertTrue(script.contains("case \"knowledge\":"))
        // The client-side nav allowlist must accept it, or the click is a no-op.
        let allowlist = try XCTUnwrap(script.range(of: "const workspaceNames = new Set(["))
        let lineEnd = try XCTUnwrap(script.range(of: "]", range: allowlist.upperBound..<script.endIndex))
        XCTAssertTrue(
            script[allowlist.upperBound..<lineEnd.lowerBound].contains("\"knowledge\""),
            "knowledge must be in workspaceNames or the sidebar button does nothing"
        )
        // Both maps rendered, each entry editable and deletable.
        XCTAssertTrue(script.contains("knowledge.creators"))
        XCTAssertTrue(script.contains("knowledge.terms"))
        XCTAssertTrue(script.contains("editKnowledgeEntry"))
        XCTAssertTrue(script.contains("deleteKnowledgeEntry"))
        // Strings for the workspace.
        XCTAssertTrue(strings.contains("Known creators"))
        XCTAssertTrue(strings.contains("Known terms"))
    }

    func testProviderWorkspaceDisclosesLocalOnlyCredentialStorage() throws {
        let appURL = try XCTUnwrap(VaultClassifierWebShell.bundledWebAssetURL(named: "app", extension: "js"))
        let stringsURL = try XCTUnwrap(VaultClassifierWebShell.bundledWebAssetURL(named: "strings", extension: "js"))
        let script = try String(contentsOf: appURL, encoding: .utf8)
        let strings = try String(contentsOf: stringsURL, encoding: .utf8)

        // The API-keys workspace renders the local-only disclosure.
        XCTAssertTrue(script.contains("llm.localOnlyDisclosure"))
        XCTAssertTrue(script.contains("provider-local-only"))
        // The copy explicitly states keys stay on this Mac and are never uploaded.
        XCTAssertTrue(strings.contains("stored locally on this Mac"))
        XCTAssertTrue(strings.contains("never upload your keys"))
        XCTAssertTrue(strings.contains("never in the system keychain"))
    }

    func testShellExposesResearchSearchModeSelectorGloballyAndPerType() throws {
        let appURL = try XCTUnwrap(VaultClassifierWebShell.bundledWebAssetURL(named: "app", extension: "js"))
        let stringsURL = try XCTUnwrap(VaultClassifierWebShell.bundledWebAssetURL(named: "strings", extension: "js"))
        let script = try String(contentsOf: appURL, encoding: .utf8)
        let strings = try String(contentsOf: stringsURL, encoding: .utf8)

        // The search-mode selector, the two modes, and the grounding badge are
        // rendered in both the global settings panel and the per-type override
        // body (each token should appear at least twice — once per surface).
        for token in [
            "\"searchMode\"", "research.searchMode.raw", "research.searchMode.grounding",
            "research.groundingBadge", "data-search-provider-field",
        ] {
            XCTAssertGreaterThanOrEqual(
                script.components(separatedBy: token).count - 1, 2,
                "Expected \(token) in both global and per-type research UI"
            )
        }
        // The live change handler that hides the raw-search provider in grounding mode.
        XCTAssertTrue(script.contains("[data-field=\"searchMode\"]"))
        XCTAssertTrue(script.contains("providerGrounding"))
        // Only grounding-capable providers are marked, using the native-search capability.
        XCTAssertTrue(script.contains("supportsNativeWebSearch"))

        // Strings for the selector and the mode labels exist.
        for key in [
            "\"research.searchMode\"", "\"research.searchMode.raw\"",
            "\"research.searchMode.grounding\"", "\"research.groundingBadge\"",
        ] {
            XCTAssertTrue(strings.contains(key), "Missing string \(key)")
        }
        // The disclosure copy now covers provider-grounding mode explicitly.
        XCTAssertTrue(strings.contains("provider-grounding mode the sanitized subject is sent to a single grounding-capable provider"))
    }

    func testShellDisclosesOptInResearchDataFlow() throws {
        let appURL = try XCTUnwrap(VaultClassifierWebShell.bundledWebAssetURL(named: "app", extension: "js"))
        let stringsURL = try XCTUnwrap(VaultClassifierWebShell.bundledWebAssetURL(named: "strings", extension: "js"))
        let script = try String(contentsOf: appURL, encoding: .utf8)
        let strings = try String(contentsOf: stringsURL, encoding: .utf8)

        XCTAssertTrue(script.contains("saveResearchSettings"))
        XCTAssertTrue(script.contains("research.consent"))
        XCTAssertTrue(script.contains("supportsGenerateText"))
        XCTAssertTrue(strings.contains("Raw video titles, summaries, body text, and private creator IDs are never sent"))
        XCTAssertTrue(strings.contains("selected trigger policy"))
        XCTAssertFalse(strings.contains("Everything runs on this Mac; nothing leaves it"))
    }

    func testShellContainsPerTypeResearchOverridesAndGlobalMasterGateCopy() throws {
        let appURL = try XCTUnwrap(VaultClassifierWebShell.bundledWebAssetURL(named: "app", extension: "js"))
        let stringsURL = try XCTUnwrap(VaultClassifierWebShell.bundledWebAssetURL(named: "strings", extension: "js"))
        let script = try String(contentsOf: appURL, encoding: .utf8)
        let strings = try String(contentsOf: stringsURL, encoding: .utf8)

        XCTAssertTrue(script.contains("saveClassifierTypeResearch"))
        XCTAssertTrue(script.contains("toggleResearchAdvanced"))
        XCTAssertTrue(script.contains("classifier-research-form-"))
        XCTAssertTrue(script.contains("researchOverrides"))
        XCTAssertTrue(strings.contains("global Research consent in Settings is the master gate"))
    }

    func testSettingsModelLibraryExposesUserInitiatedDownloadControls() throws {
        let appURL = try XCTUnwrap(VaultClassifierWebShell.bundledWebAssetURL(named: "app", extension: "js"))
        let stringsURL = try XCTUnwrap(VaultClassifierWebShell.bundledWebAssetURL(named: "strings", extension: "js"))
        let script = try String(contentsOf: appURL, encoding: .utf8)
        let strings = try String(contentsOf: stringsURL, encoding: .utf8)

        XCTAssertTrue(script.contains("modelLibraryContent"))
        XCTAssertTrue(script.contains("downloadModel"))
        XCTAssertTrue(script.contains("cancelModelDownload"))
        XCTAssertTrue(script.contains("deleteModelFile"))
        XCTAssertTrue(script.contains("role=\"progressbar\""))
        XCTAssertTrue(script.contains("localModelOptions"))
        XCTAssertTrue(script.contains("localModel.modelMissing"))
        XCTAssertTrue(strings.contains("Models download from Hugging Face only when you press Download."))
        XCTAssertTrue(strings.contains("LATENCY NOT MEASURED"))
        XCTAssertTrue(strings.contains("missing — re-download"))
    }

    func testCollectionEntriesExposeCorrectionEditorWithoutANewHubOperation() throws {
        let appURL = try XCTUnwrap(VaultClassifierWebShell.bundledWebAssetURL(named: "app", extension: "js"))
        let script = try String(contentsOf: appURL, encoding: .utf8)
        XCTAssertTrue(script.contains("submitCorrection"))
        XCTAssertTrue(script.contains("correctTagIDs"))
        XCTAssertTrue(script.contains("correctionForms"))
        XCTAssertFalse(script.contains("correction-tags-updated"))
        XCTAssertFalse(script.contains("research-tags-updated"))
    }
}
