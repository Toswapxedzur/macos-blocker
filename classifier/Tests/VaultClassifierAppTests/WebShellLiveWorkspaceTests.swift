import Foundation
import XCTest
import VaultClassifierCore
@testable import VaultClassifierApp

final class WebShellLiveWorkspaceTests: XCTestCase {
    func testBundledShellContainsOnlyLiveWorkspacesAndActions() throws {
        let appURL = try XCTUnwrap(VaultClassifierBundledAssets.url(named: "app", extension: "js"))
        let script = try String(contentsOf: appURL, encoding: .utf8)

        for liveWorkspace in ["browserBridge", "knowledge"] {
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
    func testShellPerTypeFormHoldsDialsHouseRulesAndOptionalTagCounts() throws {
        let appURL = try XCTUnwrap(VaultClassifierBundledAssets.url(named: "app", extension: "js"))
        let script = try String(contentsOf: appURL, encoding: .utf8)
        XCTAssertTrue(script.contains("saveClassifierTypeLocalModel"))
        XCTAssertTrue(script.contains("classifier-local-model-form-"))
        XCTAssertTrue(script.contains("localModelResidentNote"))
        let sectionStart = try XCTUnwrap(script.range(of: "const localModel = classifierType.localModel"))
        let sectionEnd = try XCTUnwrap(script.range(of: "const researchFormID", range: sectionStart.upperBound..<script.endIndex))
        let section = String(script[sectionStart.lowerBound..<sectionEnd.lowerBound])
        for field in ["localModel.speedQuality", "localModel.strictness", "\"houseRules\"", "speedQualityCards(", "strictnessOptions("] {
            XCTAssertTrue(section.contains(field), "per-type field missing: \(field)")
        }
        for retired in ["saveLocalLLMSettings", "followGlobal", "allowDecline", "confidenceBand", "modelFileName", "thumbnailOcrEvidence", "toggleLocalModelAdvanced"] {
            XCTAssertFalse(script.contains(retired), "retired control still in the shell: \(retired)")
        }
    }

    /// Research is on/off + provider; every budget, cooldown, trigger and knowledge
    /// field is a constant and must be gone from both forms.
    func testShellResearchFormIsOnOffPlusProvider() throws {
        let appURL = try XCTUnwrap(VaultClassifierBundledAssets.url(named: "app", extension: "js"))
        let script = try String(contentsOf: appURL, encoding: .utf8)
        let stringsURL = try XCTUnwrap(VaultClassifierBundledAssets.url(named: "strings", extension: "js"))
        let strings = try String(contentsOf: stringsURL, encoding: .utf8)
        for retired in [
            "requestsPerMinute", "dailyTokenLimit\"", "cooldownHours", "creatorScoreThreshold", "creatorScoreHalfLifeDays",
            "knowledgeTTLDays", "maxKnowledgePerVideo", "research.group.frequency", "research.group.author", "research.group.knowledge",
        ] {
            XCTAssertFalse(script.contains(retired), "retired research control still in the shell: \(retired)")
        }
        XCTAssertTrue(script.contains("research.constantsNote"))
        XCTAssertTrue(strings.contains("\"research.constantsNote\""))
        XCTAssertTrue(strings.contains("score reaches 3; the score halves every 14 days"))
    }

    func testShellSurfacesResearchLaneStatusAndRetryAction() throws {
        let appURL = try XCTUnwrap(VaultClassifierBundledAssets.url(named: "app", extension: "js"))
        let script = try String(contentsOf: appURL, encoding: .utf8)
        let stringsURL = try XCTUnwrap(VaultClassifierBundledAssets.url(named: "strings", extension: "js"))
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
        let appURL = try XCTUnwrap(VaultClassifierBundledAssets.url(named: "app", extension: "js"))
        let stringsURL = try XCTUnwrap(VaultClassifierBundledAssets.url(named: "strings", extension: "js"))
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
        XCTAssertTrue(strings.contains("Content sources"))
        XCTAssertTrue(strings.contains("Known terms"))
    }

    func testProviderWorkspaceDisclosesLocalOnlyCredentialStorage() throws {
        let appURL = try XCTUnwrap(VaultClassifierBundledAssets.url(named: "app", extension: "js"))
        let stringsURL = try XCTUnwrap(VaultClassifierBundledAssets.url(named: "strings", extension: "js"))
        let script = try String(contentsOf: appURL, encoding: .utf8)
        let strings = try String(contentsOf: stringsURL, encoding: .utf8)

        // The API-keys workspace renders the local-only disclosure.
        XCTAssertTrue(script.contains("llm.localOnlyDisclosure"))
        XCTAssertTrue(script.contains("provider-local-only"))
        // The copy distinguishes local storage from authentication requests sent to the provider.
        XCTAssertTrue(strings.contains("stored in this app’s support folder on this device"))
        XCTAssertTrue(strings.contains("Keys are sent to the configured provider to authenticate requests"))
        XCTAssertTrue(strings.contains("not in the system Keychain"))
    }

    /// Research is provider-grounding only (Cut A): the shell must not offer a
    /// search mode, a web-search provider, or the raw-search tuning fields, must
    /// offer only grounding-capable providers, and must retire Serper/You.com.
    func testShellIsProviderGroundingOnlyGloballyAndPerType() throws {
        let appURL = try XCTUnwrap(VaultClassifierBundledAssets.url(named: "app", extension: "js"))
        let stringsURL = try XCTUnwrap(VaultClassifierBundledAssets.url(named: "strings", extension: "js"))
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
        // The research form filters the provider list to grounding-capable profiles.
        XCTAssertTrue(script.contains("supportsNativeWebSearch"))
        XCTAssertTrue(script.contains(".filter(isGroundingCapable)"))
        // Existing search-only profiles are flagged retired, not silently inert.
        XCTAssertTrue(script.contains("retiredSearchProvider"))
        XCTAssertTrue(strings.contains("\"llm.retiredSearchProvider\""))
        // The data-flow disclosure describes the your selected provider, which searches the web.
        XCTAssertTrue(strings.contains("your selected provider, which searches the web"))
        XCTAssertFalse(strings.contains("raw-search mode"))
    }

    func testShellDisclosesOptInResearchDataFlow() throws {
        let appURL = try XCTUnwrap(VaultClassifierBundledAssets.url(named: "app", extension: "js"))
        let stringsURL = try XCTUnwrap(VaultClassifierBundledAssets.url(named: "strings", extension: "js"))
        let script = try String(contentsOf: appURL, encoding: .utf8)
        let strings = try String(contentsOf: stringsURL, encoding: .utf8)

        XCTAssertTrue(script.contains("saveResearchSettings"))
        XCTAssertTrue(script.contains("research.consent"))
        XCTAssertTrue(script.contains("supportsGenerateText"))
        XCTAssertTrue(strings.contains("These research requests do not include content titles, summaries, body text, or private source IDs"))
        XCTAssertTrue(strings.contains("a term you added without a description"))
        XCTAssertFalse(strings.contains("second on-device constrained decode"), "the automatic term decode is gone")
        XCTAssertTrue(script.contains("addKnowledgeTerm"))
        XCTAssertFalse(strings.contains("Everything runs on this device; nothing leaves it"))
    }

    func testShellContainsPerTypeResearchOverridesAndGlobalMasterGateCopy() throws {
        let appURL = try XCTUnwrap(VaultClassifierBundledAssets.url(named: "app", extension: "js"))
        let stringsURL = try XCTUnwrap(VaultClassifierBundledAssets.url(named: "strings", extension: "js"))
        let script = try String(contentsOf: appURL, encoding: .utf8)
        let strings = try String(contentsOf: stringsURL, encoding: .utf8)

        XCTAssertTrue(script.contains("saveClassifierTypeResearch"))
        XCTAssertTrue(script.contains("classifier-research-form-"))
        XCTAssertTrue(script.contains("\"researchMode\""))
        for mode in ["bridge.researchMode.inherit", "bridge.researchMode.on", "bridge.researchMode.off"] {
            XCTAssertTrue(script.contains(mode)); XCTAssertTrue(strings.contains("\"\(mode)\""))
        }
        XCTAssertFalse(script.contains("classifierType.researchOverrides"), "the per-type research profile payload is gone")
        XCTAssertTrue(strings.contains("Research consent in Settings applies to every group"))
    }

    func testSettingsModelLibraryExposesUserInitiatedDownloadControls() throws {
        let appURL = try XCTUnwrap(VaultClassifierBundledAssets.url(named: "app", extension: "js"))
        let stringsURL = try XCTUnwrap(VaultClassifierBundledAssets.url(named: "strings", extension: "js"))
        let script = try String(contentsOf: appURL, encoding: .utf8)
        let strings = try String(contentsOf: stringsURL, encoding: .utf8)

        // The Speed↔Quality cards carry each tier's download controls.
        XCTAssertTrue(script.contains("speedQualityCards"))
        XCTAssertTrue(script.contains("strictnessOptions"))
        XCTAssertTrue(script.contains("downloadModel"))
        XCTAssertTrue(script.contains("cancelModelDownload"))
        XCTAssertTrue(script.contains("deleteModelFile"))
        XCTAssertTrue(script.contains("role=\"progressbar\""))
        for tier in ["fast", "balanced", "best"] {
            XCTAssertTrue(strings.contains("\"localModel.tier.\(tier).name\""))
            XCTAssertTrue(strings.contains("\"localModel.tier.\(tier).desc\""))
        }
        for position in 1...5 {
            XCTAssertTrue(strings.contains("\"localModel.strictness.\(position).name\""))
            XCTAssertTrue(strings.contains("\"localModel.strictness.\(position).desc\""))
        }
        XCTAssertTrue(strings.contains("Model files download from Hugging Face when you choose Download."))
        XCTAssertFalse(strings.contains("LATENCY NOT MEASURED"))
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
