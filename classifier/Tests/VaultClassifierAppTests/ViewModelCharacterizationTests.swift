import Foundation
import XCTest
import VaultClassifierCore
@testable import VaultClassifierApp

/// Characterisation net for the God-object split (CLASSIFIER-INDEPENDENCE §7,
/// Phase 5). These pin the OBSERVABLE surface of `VaultClassifierViewModel`'s
/// untyped web RPC — the snapshot's shape and how actions route and mutate —
/// so moving its methods into per-concern extension files is provably
/// behaviour-preserving. Everything runs hermetically under a temp directory
/// (headless init: no hub, no engine, no Keychain, no migrations, no network).
@MainActor
final class ViewModelCharacterizationTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vault-vm-characterisation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        LocalStateFile.flushAllPendingWrites()
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeViewModel() throws -> VaultClassifierViewModel {
        try VaultClassifierViewModel(headlessVaultDirectory: directory)
    }

    // MARK: - Snapshot shape

    func testHeadlessViewModelStartsCleanOnTheStubEngine() throws {
        let vm = try makeViewModel()
        XCTAssertNil(vm.issue, "headless construction must not surface an error")
        XCTAssertNotNil(vm.localState)
        XCTAssertEqual(vm.llmEngineStatus, "disabled")
        XCTAssertEqual(vm.workspace, .tagTree)
    }

    func testWebSnapshotTopLevelShapeIsPinned() throws {
        let vm = try makeViewModel()
        let snapshot = vm.webSnapshot()
        // The exact top-level vocabulary the web shell consumes. A key vanishing
        // here during the split means a workspace silently lost its data.
        XCTAssertEqual(
            Set(snapshot.keys),
            ["workspace", "issue", "notices", "settings", "backup", "assets", "trash"]
        )
        XCTAssertTrue(JSONSerialization.isValidJSONObject(snapshot), "snapshot must be JSON-serialisable for the bridge")
        XCTAssertEqual(snapshot["workspace"] as? String, "tagTree")
        XCTAssertTrue(snapshot["issue"] is NSNull)
    }

    func testWebSnapshotLocalLLMSettingsShapeIsPinned() throws {
        let vm = try makeViewModel()
        let settings = try XCTUnwrap(vm.webSnapshot()["settings"] as? [String: Any])
        let llm = try XCTUnwrap(settings["localLLM"] as? [String: Any])
        XCTAssertEqual(
            Set(llm.keys),
            ["speedQuality", "strictness", "houseRules", "modelFileName", "systemRAMGB",
             "engineStatus", "availableModels", "modelLibrary"]
        )
        // Defaults: the Balanced tier, the Balanced position.
        XCTAssertEqual(llm["speedQuality"] as? String, "balanced")
        XCTAssertEqual(llm["strictness"] as? Int, 3)
        XCTAssertEqual(llm["modelFileName"] as? String, "Qwen2.5-7B-Instruct-Q4_K_M.gguf")
        XCTAssertEqual((llm["modelLibrary"] as? [[String: Any]])?.count, 3)
    }

    // MARK: - Action routing

    // Return-value contract: `true` means "re-send the snapshot" — including
    // after an error, because the error is surfaced through `issue` inside that
    // snapshot. Only a successful workspace switch returns `false` (no echo).
    func testUnknownActionSurfacesAnIssueAndAsksForARerender() throws {
        let vm = try makeViewModel()
        let before = vm.webSnapshot()
        XCTAssertTrue(vm.performWebAction("definitely-not-an-action", data: [:]))
        XCTAssertNotNil(vm.issue, "an unknown action surfaces an issue")
        let after = vm.webSnapshot()
        XCTAssertEqual(Set(before.keys), Set(after.keys))
    }

    func testWorkspaceActionSwitchesWithoutEchoingTheSnapshot() throws {
        let vm = try makeViewModel()
        // "workspace" deliberately returns false: the shell switches optimistically
        // and must not be sent the multi-megabyte state again for navigation.
        XCTAssertFalse(vm.performWebAction("workspace", data: ["workspace": "knowledge"]))
        XCTAssertEqual(vm.workspace, .knowledge)
        XCTAssertEqual(vm.webSnapshot()["workspace"] as? String, "knowledge")
        XCTAssertTrue(vm.performWebAction("workspace", data: ["workspace": "not-a-workspace"]), "the error path re-sends the snapshot")
        XCTAssertEqual(vm.workspace, .knowledge, "an invalid workspace is rejected, state unchanged")
        XCTAssertNotNil(vm.issue)
    }

    func testSaveLocalLLMSettingsRoundTripsThroughTheSnapshot() throws {
        let vm = try makeViewModel()
        let ok = vm.performWebAction("saveLocalLLMSettings", data: [
            "speedQuality": "fast", "strictness": "5", "houseRules": "prefer specific tags",
        ])
        XCTAssertTrue(ok)
        XCTAssertNil(vm.issue)
        let llm = try XCTUnwrap((vm.webSnapshot()["settings"] as? [String: Any])?["localLLM"] as? [String: Any])
        XCTAssertEqual(llm["speedQuality"] as? String, "fast")
        XCTAssertEqual(llm["strictness"] as? Int, 5)
        XCTAssertEqual(llm["houseRules"] as? String, "prefer specific tags")
        // And it persisted through the coordinator, not just the published mirror.
        XCTAssertEqual(vm.localState?.settings.localLLM.strictness, .broadest)
        XCTAssertEqual(vm.localState?.settings.localLLM.speedQuality, .fast)
        // Unknown positions are refused and surfaced.
        XCTAssertTrue(vm.performWebAction("saveLocalLLMSettings", data: ["speedQuality": "turbo", "strictness": "3", "houseRules": ""]))
        XCTAssertNotNil(vm.issue)
        XCTAssertEqual(vm.localState?.settings.localLLM.speedQuality, .fast, "a refused save changes nothing")
    }

    /// The complete web-action vocabulary. Each is probed with EMPTY data: a
    /// routed action either succeeds or fails on a missing/invalid field, but
    /// never with the `default:` "unsupported action" error. A case dropped
    /// while moving methods between files shows up here as exactly that error.
    /// (All 45 are safe headless with empty data — the backup ones throw on the
    /// missing owner code / directory or on "locked" before touching the Keychain.)
    func testEveryKnownWebActionIsRouted() throws {
        let actions = [
            "state", "workspace", "createTree", "addCollectionPlatform", "confirmDeleteCollectionPlatform",
            "restoreTrashedEntry", "permanentlyDeleteTrashedEntry", "setCollectionEnabled", "clearCollectionDiagnostics",
            "setActiveClassifierType", "createClassifierType", "reorderClassifierTypes", "configureClassifierType",
            "confirmDeleteClassifierType", "createProviderProfile", "testProviderProfile", "updateProviderConnection",
            "probeProviderModelCatalog", "confirmDeleteProviderProfile", "renameTree", "deleteTree", "rearrangeTree",
            "addTag", "moveTag", "renameTag", "updateTag", "connectTag", "disconnectTag", "deleteTag",
            "savePackageSettings", "saveLocalLLMSettings", "downloadModel", "cancelModelDownload", "deleteModelFile",
            "deleteKnowledgeEntry", "editKnowledgeEntry", "retryFailedResearch", "saveResearchSettings", "submitCorrection",
            "saveClassifierTypeLocalModel", "saveClassifierTypeResearch", "setBackupOwnerCode", "unlockBackup",
            "saveBackup", "backupNow",
        ]
        XCTAssertEqual(actions.count, 45)
        let unsupported = WebBridgeInputError.invalidChoice("action").localizedDescription
        for action in actions {
            let vm = try makeViewModel()
            _ = vm.performWebAction(action, data: [:])
            XCTAssertNotEqual(vm.issue, unsupported, "action '\(action)' fell through to default: — it is no longer routed")
        }
        let vm = try makeViewModel()
        _ = vm.performWebAction("nope", data: [:])
        XCTAssertEqual(vm.issue, unsupported, "the sentinel must still be what default: produces")
    }

    func testSaveLocalLLMSettingsRejectsMalformedInputWithoutMutation() throws {
        let vm = try makeViewModel()
        let before = vm.localState?.settings.localLLM
        XCTAssertTrue(vm.performWebAction("saveLocalLLMSettings", data: ["maximumTags": "3"]), "the error path re-sends the snapshot")
        XCTAssertNotNil(vm.issue)
        XCTAssertEqual(vm.localState?.settings.localLLM, before)
    }
}
