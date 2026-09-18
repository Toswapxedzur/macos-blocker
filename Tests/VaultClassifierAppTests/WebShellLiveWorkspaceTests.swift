import Foundation
import XCTest
import VaultClassifierCore
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
        XCTAssertTrue(overrideBody.contains("thumbnailOcrEvidence"), "per-type thumbnail-OCR toggle missing")
        XCTAssertTrue(overrideBody.contains("maximumTags"), "per-type max-tags field missing")
    }

    func testShellGroupsGranularResearchControlsGloballyAndPerType() throws {
        let appURL = try XCTUnwrap(VaultClassifierWebShell.bundledWebAssetURL(named: "app", extension: "js"))
        let script = try String(contentsOf: appURL, encoding: .utf8)
        for field in [
            "cooldownHours", "urgencyFloor", "authorCount", "authorLevel", "authorWindowDays",
            "knowledgeTTLDays", "maxKnowledgePerVideo",
        ] {
            XCTAssertGreaterThanOrEqual(script.components(separatedBy: field).count - 1, 2)
        }
        for group in ["research.group.frequency", "research.group.trigger", "research.group.author", "research.group.knowledge"] {
            XCTAssertGreaterThanOrEqual(script.components(separatedBy: group).count - 1, 2)
        }
    }

    func testShellSurfacesResearchLaneStatusAndRetryAction() throws {
        let appURL = try XCTUnwrap(VaultClassifierWebShell.bundledWebAssetURL(named: "app", extension: "js"))
        let script = try String(contentsOf: appURL, encoding: .utf8)
        let stringsURL = try XCTUnwrap(VaultClassifierWebShell.bundledWebAssetURL(named: "strings", extension: "js"))
        let strings = try String(contentsOf: stringsURL, encoding: .utf8)
        // Research failures must be visible (queue/cooldown/last failure) and
        // recoverable (retry-now) from the settings panel; every key rendered
        // must exist in the catalog so no raw key can leak into the UI.
        for token in [
            "research.status.queue", "research.status.lastFailure", "research.status.noFailures",
            "research.status.retryNow", "data-action=\"retryFailedResearch\"", "data-research-status",
        ] {
            XCTAssertTrue(script.contains(token), "research status UI missing: \(token)")
        }
        for key in [
            "research.status.queue", "research.status.inFlight", "research.status.lastFailure",
            "research.status.lastFailure.due", "research.status.noFailures", "research.status.retryNow",
            "research.status.retryNowHint",
        ] + GroundedResearchFailureKind.allCases.map { "research.failure.\($0.rawValue)" } {
            XCTAssertTrue(strings.contains("\"\(key)\""), "strings.js missing \(key)")
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

    /// Research is provider-grounding only (Cut A): the shell must not offer a
    /// search mode, a web-search provider, or the raw-search tuning fields, must
    /// offer only grounding-capable providers, and must retire Serper/You.com.
    func testShellIsProviderGroundingOnlyGloballyAndPerType() throws {
        let appURL = try XCTUnwrap(VaultClassifierWebShell.bundledWebAssetURL(named: "app", extension: "js"))
        let stringsURL = try XCTUnwrap(VaultClassifierWebShell.bundledWebAssetURL(named: "strings", extension: "js"))
        let script = try String(contentsOf: appURL, encoding: .utf8)
        let strings = try String(contentsOf: stringsURL, encoding: .utf8)

        // Quoted, so an identifier like `typeResearchModelListID` is not a false hit.
        for retired in [
            "\"searchMode\"", "rawSearchProvider", "\"webSearchProviderProfileID\"", "data-search-provider-field",
            "\"searchResultCount\"", "\"snippetContextChars\"", "supportsRawWebSearch", "llm.providerGroup.search",
        ] {
            XCTAssertFalse(script.contains(retired), "\(retired) should be gone from the shell")
        }
        for retiredString in [
            "research.searchMode", "research.searchProvider", "research.searchResultCount",
            "research.snippetContextChars", "research.groundingBadge", "llm.providerGroup.search",
        ] {
            XCTAssertFalse(strings.contains("\"\(retiredString)"), "\(retiredString) string should be gone")
        }
        // Both research forms filter the provider list to grounding-capable profiles.
        XCTAssertGreaterThanOrEqual(script.components(separatedBy: "supportsNativeWebSearch").count - 1, 2)
        XCTAssertTrue(script.contains(".filter(isGroundingCapable)"))
        XCTAssertTrue(script.contains(".filter(typeIsGroundingCapable)"))
        // Existing search-only profiles are flagged retired, not silently inert.
        XCTAssertTrue(script.contains("retiredSearchProvider"))
        XCTAssertTrue(strings.contains("\"llm.retiredSearchProvider\""))
        // The data-flow disclosure describes the single grounding-capable provider.
        XCTAssertTrue(strings.contains("single grounding-capable provider"))
        XCTAssertFalse(strings.contains("raw-search mode"))
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
        XCTAssertTrue(strings.contains("videos the model is unsure about"))
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

    func testCreateGroupFlowGoesThroughPresetPicker() throws {
        let appURL = try XCTUnwrap(VaultClassifierWebShell.bundledWebAssetURL(named: "app", extension: "js"))
        let script = try String(contentsOf: appURL, encoding: .utf8)
        // Creating a group opens the preset dialog; there is no direct-create path.
        XCTAssertTrue(script.contains("createTypeModal"))
        XCTAssertTrue(script.contains("pendingCreateType"))
        XCTAssertTrue(script.contains("selectCreatePreset"))
        XCTAssertTrue(script.contains("confirmCreateType"))
        XCTAssertTrue(script.contains("cancelCreateType"))
        // The create action must carry a presetID (a group can only be made from a preset).
        let confirmStart = try XCTUnwrap(script.range(of: "action === \"confirmCreateType\""))
        let confirmBody = String(script[confirmStart.lowerBound...].prefix(1000))
        XCTAssertTrue(confirmBody.contains("presetID"), "confirmCreateType must send a presetID")
        XCTAssertTrue(confirmBody.contains("send(\"createClassifierType\""))
        // The old direct newType create (default name + first platform, no preset) is gone.
        XCTAssertFalse(script.contains("send(\"createClassifierType\", { name: t(\"navigation.newType\")"))
        // Drift indicator + preset badge are wired.
        XCTAssertTrue(script.contains("modifiedFromPreset"))
        XCTAssertTrue(script.contains("presetNameKey"))

        let stringsURL = try XCTUnwrap(VaultClassifierWebShell.bundledWebAssetURL(named: "strings", extension: "js"))
        let strings = try String(contentsOf: stringsURL, encoding: .utf8)
        for key in [
            "createType.title", "createType.presetLabel", "createType.create",
            "preset.gentle.name", "preset.balanced.name", "preset.strict.name",
            "preset.localOnly.name", "preset.modifiedFrom", "preset.basedOn",
        ] {
            XCTAssertTrue(strings.contains(key), "missing preset string: \(key)")
        }
    }
}
