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

    func testNativeKnowledgePagesSearchTheEntireCatalogWithoutSendingItInSnapshots() async throws {
        let vm = try makeViewModel()
        vm.localState?.workspaceCatalog.knowledgeEntries = (0..<10000).map { KnowledgeEntry(kind: .term, subject: "Term \($0)", meaning: "Description \($0)", updatedAtMilliseconds: Int64($0)) }
        let assets = try XCTUnwrap(vm.webSnapshot(includeCollections: false)["assets"] as? [String: Any])
        let knowledge = try XCTUnwrap(assets["knowledge"] as? [String: Any])
        XCTAssertTrue((knowledge["terms"] as? [[String: Any]])?.isEmpty == true)
        XCTAssertEqual((knowledge["counts"] as? [String: Int])?["term"], 10000)
        let request: [String: Any] = ["requestID": "test", "kind": "term", "platformID": "", "query": "Term 9999", "offset": 0, "limit": 12]
        let answer = await vm.knowledgePage(request)
        let script = try XCTUnwrap(answer)
        let encoded = try XCTUnwrap(script.components(separatedBy: "atob('").last?.components(separatedBy: "')").first)
        let packet = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(Data(base64Encoded: encoded))) as? [String: Any])
        let rows = try XCTUnwrap(packet["items"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?["subject"] as? String, "Term 9999")
        XCTAssertEqual(packet["total"] as? Int, 1)
        var invalid = request; invalid["limit"] = 100000
        let refused = await vm.knowledgePage(invalid); XCTAssertNil(refused)
    }

    // MARK: - Snapshot shape

    func testPersonalDictionaryRoundTripAndInvalidImportFeedbackStayInSettings() throws {
        let vm = try makeViewModel()
        _ = vm.performWebAction("addKnowledgeTerm", data: ["subject": "Audit term", "meaning": "A personal description."])
        _ = vm.performWebAction("exportPersonalDictionary", data: [:])
        let exported = try XCTUnwrap(vm.personalDictionaryJSON)
        let before = vm.localState?.workspaceCatalog.knowledgeEntries
        vm.dictionaryNotice = "Dictionary updated. Personal definitions are preserved."
        _ = vm.performWebAction("importPersonalDictionary", data: ["json": "{"])
        XCTAssertNil(vm.issue, "Settings must show the error next to the transfer controls.")
        XCTAssertNotNil(vm.dictionaryNotice)
        XCTAssertNotEqual(vm.dictionaryNotice, "Dictionary updated. Personal definitions are preserved.")
        XCTAssertEqual(vm.localState?.workspaceCatalog.knowledgeEntries, before)
        XCTAssertEqual(vm.personalDictionaryJSON, exported)
        _ = vm.performWebAction("importPersonalDictionary", data: ["json": exported])
        XCTAssertNil(vm.issue)
        XCTAssertEqual(vm.dictionaryNotice, "Personal definitions imported.")
        XCTAssertNil(vm.personalDictionaryJSON)
        XCTAssertEqual(vm.localState?.workspaceCatalog.knowledgeEntries.map(\.subject), ["Audit term"])
        _ = vm.performWebAction("exportPersonalDictionary", data: [:])
        XCTAssertNil(vm.dictionaryNotice)
        XCTAssertNotNil(vm.personalDictionaryJSON)
    }

    func testClassifierOwnsPersistedGroupPauseAndGlobalActivation() throws {
        let vm = try makeViewModel()
        XCTAssertEqual(vm.localState?.settings.classificationEnabled, true)
        _ = vm.performWebAction("createClassifierType", data: ["name": "A", "platformIDs": ["youtube"]])
        let group = try XCTUnwrap(vm.localState?.workspaceCatalog.classifierTypes.first)
        XCTAssertFalse(group.isPaused)
        XCTAssertEqual(vm.coordinator?.enabledClassificationPlatformIDs(), ["youtube"])
        _ = vm.performWebAction("setClassifierTypePaused", data: ["typeID": group.id, "paused": true])
        XCTAssertNil(vm.issue)
        _ = vm.performWebAction("saveClassificationSettings", data: ["classificationEnabled": false])
        XCTAssertNil(vm.issue)
        _ = vm.performWebAction("saveResearchSettings", data: ["enabled": false])
        let reloaded = try makeViewModel()
        XCTAssertEqual(reloaded.localState?.settings.classificationEnabled, false)
        XCTAssertEqual(reloaded.localState?.workspaceCatalog.classifierTypes.first?.isPaused, true)
        _ = reloaded.performWebAction("setClassifierTypePaused", data: ["typeID": group.id, "paused": false])
        XCTAssertTrue(reloaded.coordinator?.enabledClassificationPlatformIDs().isEmpty == true)
        _ = reloaded.performWebAction("saveClassificationSettings", data: ["classificationEnabled": true])
        XCTAssertEqual(reloaded.coordinator?.enabledClassificationPlatformIDs(), ["youtube"])
    }

    func testSharedSettingsWritesPreserveOtherFeaturesAndRejectRetiredPolicy() throws {
        let vm = try makeViewModel()
        try vm.saveDictionarySettings(mode: "full", cacheSize: 27, contributionEnabled: false, choiceMade: true)
        vm.saveClassificationSettings(enabled: false)
        let dictionaries = try XCTUnwrap(vm.localState?.settings.dictionaries)
        vm.saveResearchSettings(.init(enabled: false))
        XCTAssertNil(vm.issue)
        XCTAssertEqual(vm.localState?.settings.dictionaries, dictionaries)
        XCTAssertEqual(vm.localState?.settings.classificationEnabled, false)
        vm.createProviderProfile(typeRaw: "openAI")
        let profile = try XCTUnwrap(vm.localState?.workspaceCatalog.providerProfiles.first)
        vm.saveResearchSettings(.init(enabled: false, llmProviderProfileID: profile.id))
        vm.deleteProviderProfile(profileID: profile.id)
        XCTAssertNil(vm.issue)
        XCTAssertEqual(vm.localState?.settings.dictionaries, dictionaries)
        XCTAssertEqual(vm.localState?.settings.classificationEnabled, false)
        XCTAssertNil(ClassifierWebActionCatalog.descriptor(named: "savePackageSettings"))
        let before = vm.localState
        _ = vm.performWebAction("savePackageSettings", data: ["packageUpdateMode": "automatic"])
        XCTAssertNotNil(vm.issue)
        XCTAssertEqual(vm.localState, before)
        let reopened = try makeViewModel()
        XCTAssertEqual(reopened.localState?.settings.dictionaries, dictionaries)
        XCTAssertEqual(reopened.localState?.settings.classificationEnabled, false)
    }

    func testHeadlessViewModelStartsCleanOnTheStubEngine() throws {
        let vm = try makeViewModel()
        XCTAssertNil(vm.issue, "headless construction must not surface an error")
        XCTAssertNotNil(vm.localState)
        XCTAssertEqual(vm.workspace, .browserBridge)
    }

    func testWebSnapshotTopLevelShapeIsPinned() throws {
        let vm = try makeViewModel()
        let snapshot = vm.webSnapshot()
        // The exact top-level vocabulary the web shell consumes. A key vanishing
        // here during the split means a workspace silently lost its data.
        XCTAssertEqual(
            Set(snapshot.keys),
            ["workspace", "issue", "notices", "settings", "backup", "assets"]
        )
        XCTAssertTrue(JSONSerialization.isValidJSONObject(snapshot), "snapshot must be JSON-serialisable for the bridge")
        XCTAssertEqual(snapshot["workspace"] as? String, "browserBridge")
        XCTAssertTrue(snapshot["issue"] is NSNull)
    }

    func testSharedModelCatalogHasNoGlobalDials() throws {
        let vm = try makeViewModel()
        let settings = try XCTUnwrap(vm.webSnapshot()["settings"] as? [String: Any])
        XCTAssertNil(settings["localLLM"])
        let library = try XCTUnwrap(settings["localModels"] as? [String: Any])
        XCTAssertEqual(Set(library.keys), ["systemRAMGB", "modelLibrary"])
        XCTAssertEqual((library["modelLibrary"] as? [[String: Any]])?.count, 3)
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
        // "workspace" returns false: the shell switches optimistically and must
        // not be sent the multi-megabyte state again for navigation — except
        // into Knowledge, whose creator suggestions ride along only while open.
        XCTAssertFalse(vm.performWebAction("workspace", data: ["workspace": "browserBridge"]))
        XCTAssertEqual(vm.workspace, .browserBridge)
        XCTAssertTrue(vm.performWebAction("workspace", data: ["workspace": "knowledge"]))
        XCTAssertEqual(vm.workspace, .knowledge)
        XCTAssertEqual(vm.webSnapshot()["workspace"] as? String, "knowledge")
        XCTAssertTrue(vm.performWebAction("workspace", data: ["workspace": "llmAssist"]), "retired API-key workspace is rejected safely")
        XCTAssertEqual(vm.workspace, .knowledge)
        XCTAssertTrue(vm.performWebAction("workspace", data: ["workspace": "not-a-workspace"]), "the error path re-sends the snapshot")
        XCTAssertEqual(vm.workspace, .knowledge, "an invalid workspace is rejected, state unchanged")
        XCTAssertNotNil(vm.issue)
    }

    func testGroupDialsPersistIndependentlyAndGlobalSaveIsRetired() throws {
        let vm = try makeViewModel()
        _ = vm.performWebAction("createClassifierType", data: ["name": "A", "platformIDs": ["youtube"]])
        _ = vm.performWebAction("createClassifierType", data: ["name": "B", "platformIDs": ["reddit"]])
        let groups = try XCTUnwrap(vm.localState?.workspaceCatalog.classifierTypes)
        XCTAssertEqual(groups.count, 2)
        _ = vm.performWebAction("saveClassifierTypeLocalModel", data: [
            "typeID": groups[0].id, "speedQuality": "fast", "strictness": "5", "houseRules": "prefer specific tags"
        ])
        XCTAssertNil(vm.issue)
        XCTAssertEqual(vm.localState?.workspaceCatalog.classifierTypes[0].localModel.speedQuality, .fast)
        XCTAssertEqual(vm.localState?.workspaceCatalog.classifierTypes[1].localModel, .init())
        let before = vm.localState
        _ = vm.performWebAction("saveLocalLLMSettings", data: ["speedQuality": "best", "strictness": "1"])
        XCTAssertNotNil(vm.issue)
        XCTAssertEqual(vm.localState, before)
    }

    /// The complete web-action vocabulary. Each is probed with EMPTY data: a
    /// routed action either succeeds or fails on a missing/invalid field, but
    /// never with the `default:` "unsupported action" error. A case dropped
    /// while moving methods between files shows up here as exactly that error.
    /// (All 38 are safe headless with empty data — the backup ones throw on the
    /// missing owner code / directory or on "locked" before touching the Keychain.)
    func testEveryKnownWebActionIsRouted() throws {
        let actions = [
            "state", "workspace", "clearCollectedData", "setCollectionEnabled", "setCollectionKeep", "createClassifierType", "reorderClassifierTypes", "configureClassifierType",
            "confirmDeleteClassifierType", "createProviderProfile", "testProviderProfile", "updateProviderConnection",
            "probeProviderModelCatalog", "confirmDeleteProviderProfile", "rearrangeTree",
            "addTag", "moveTag", "renameTag", "updateTag", "connectTag", "disconnectTag", "deleteTag",
            "downloadModel", "cancelModelDownload", "deleteModelFile",
            "deleteKnowledgeEntry", "addKnowledgeCreator", "editKnowledgeEntry", "retryFailedResearch", "saveResearchSettings", "saveClassifierTypeLocalModel", "saveClassifierTypeResearch", "setBackupOwnerCode", "unlockBackup",
            "saveBackup", "backupNow",
        ]
        XCTAssertEqual(actions.count, 36)
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

    func testConfirmedGroupDeletionPersistsAndRetiredRecoveryActionsAreRejected() throws {
        let vm = try makeViewModel()
        XCTAssertTrue(vm.performWebAction("createClassifierType", data: ["name": "Delete me", "platformIDs": ["youtube"]]))
        XCTAssertNil(vm.issue)
        let group = try XCTUnwrap(vm.localState?.workspaceCatalog.classifierTypes.first)
        XCTAssertTrue(vm.performWebAction("confirmDeleteClassifierType", data: ["typeID": group.id]))
        XCTAssertNil(vm.issue)
        XCTAssertTrue(vm.localState?.workspaceCatalog.classifierTypes.isEmpty == true)
        XCTAssertFalse(vm.localState?.workspaceCatalog.trees.contains { $0.id == group.treeID } == true)
        LocalStateFile.flushAllPendingWrites()
        let reloaded = try makeViewModel()
        XCTAssertTrue(reloaded.localState?.workspaceCatalog.classifierTypes.isEmpty == true)
        XCTAssertNil(reloaded.webSnapshot()["trash"])
        for action in ["restoreTrashedEntry", "permanentlyDeleteTrashedEntry"] {
            XCTAssertFalse(ClassifierWebActionCatalog.actions.contains { $0.name == action })
            XCTAssertTrue(reloaded.performWebAction(action, data: ["id": "old"]))
            XCTAssertEqual(reloaded.issue, WebBridgeInputError.invalidChoice("action").localizedDescription)
        }
    }

    func testSaveLocalLLMSettingsRejectsMalformedInputWithoutMutation() throws {
        let vm = try makeViewModel()
        let before = vm.localState?.workspaceCatalog
        XCTAssertTrue(vm.performWebAction("saveLocalLLMSettings", data: ["maximumTags": "3"]), "the error path re-sends the snapshot")
        XCTAssertNotNil(vm.issue)
        XCTAssertEqual(vm.localState?.workspaceCatalog, before)
    }
}
