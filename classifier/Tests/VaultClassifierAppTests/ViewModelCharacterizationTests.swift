import Foundation
import XCTest
import VaultClassifierCore
import VaultClassifierBridge
@testable import VaultClassifierApp

@MainActor
private final class RecordingHubConnection: SharedHubConnection {
    var onRequest: ((SharedHubClient.Request) -> SharedHubClient.Reply)?
    var onStateChange: (() -> Void)?
    var broadcasts: [(operation: String, body: Any)] = []
    func disconnect() {}
    func broadcast(operation: String, body: Any) { broadcasts.append((operation, body)) }
}

private actor UnexpectedRenameLLM: ClassificationEngine {
    nonisolated let modelVersion = "unexpected-rename/v1"
    private(set) var requests = 0
    func classify(_ request: LLMClassificationRequest) async throws -> LLMClassificationResult {
        requests += 1
        return .init(tags: [])
    }
}

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

    func testBrowserRefreshIncludesTaxonomyEditsButIgnoresCanvasMovement() {
        var original = LocalClassifierState()
        original.workspaceCatalog.trees = [.init(id: "tree", name: "Audit", nodes: [.init(id: "tag", name: "Games")])]
        XCTAssertFalse(VaultClassifierViewModel.browserStateChanged(from: original, to: original))
        var moved = original
        moved.workspaceCatalog.trees[0].nodes[0].positionX = 100
        moved.workspaceCatalog.trees[0].updatedAtMilliseconds += 1
        XCTAssertFalse(VaultClassifierViewModel.browserStateChanged(from: original, to: moved))
        for edit in ["rename", "reparent", "delete"] {
            var changed = original
            changed.workspaceCatalog.trees[0].revision += 1
            switch edit {
            case "rename": changed.workspaceCatalog.trees[0].nodes[0].name = "Renamed"
            case "reparent": changed.workspaceCatalog.trees[0].nodes[0].parentID = "parent"
            default: changed.workspaceCatalog.trees[0].nodes = []
            }
            XCTAssertTrue(VaultClassifierViewModel.browserStateChanged(from: original, to: changed), edit)
            XCTAssertTrue(VaultClassifierViewModel.browserStateChanged(from: changed, to: original), "reverse " + edit)
            XCTAssertEqual(changed.workspaceCatalog.videoClassifications, original.workspaceCatalog.videoClassifications)
        }
    }

    func testLiveRenameInvalidatesBrowserProjectionOnceWithoutReclassifying() async throws {
        let vm = try makeViewModel()
        let coordinator = try XCTUnwrap(vm.coordinator)
        var catalog = coordinator.snapshot().workspaceCatalog
        let tree = TagTreeAsset(id: "rename-tree", name: "Topics", nodes: [.init(id: "games", name: "Games")])
        catalog.trees.append(tree)
        let dataset = try XCTUnwrap(catalog.datasets.first)
        catalog.classifierTypes.append(.init(id: "rename-type", name: "YouTube", treeID: tree.id,
            treeRevision: tree.revision, datasetID: dataset.id, datasetRevision: dataset.revision,
            applicablePlatformIDs: ["youtube"]))
        catalog.videoClassifications.append(.init(classifierTypeID: "rename-type", platformID: "youtube",
            entryID: "youtube:video:rename00001", creatorID: "youtube:handle:@fixture", treeID: tree.id,
            treeRevision: tree.revision, tags: [.init(tagID: "games", confidence: 5)],
            source: .humanCorrected, modelVersion: "human"))
        try coordinator.updateWorkspaceCatalog(catalog)
        vm.refreshLocalState()
        let decisions = coordinator.snapshot().workspaceCatalog.videoClassifications
        let hub = RecordingHubConnection()
        vm.sharedHubClient = hub
        let engine = UnexpectedRenameLLM()
        coordinator.setClassificationEngine(engine)
        var renders = 0
        vm.onWebStateChange = { renders += 1 }

        func browserPull() throws -> NativeVideoTagsResponse {
            let request = NativeVideoTagsRequest(platformID: "youtube", entryID: "youtube:video:rename00001",
                creatorID: "youtube:handle:@fixture", title: "Games highlights")
            let reply = vm.handleSharedHubRequest(.init(sourcePeerID: "test-browser", requestID: "rename-request",
                operation: .videoTags, bodyData: try JSONEncoder().encode(request)))
            XCTAssertNil(reply.error)
            return try JSONDecoder().decode(NativeVideoTagsResponse.self,
                from: JSONSerialization.data(withJSONObject: XCTUnwrap(reply.body)))
        }
        XCTAssertEqual(try browserPull().tags.map(\.name), ["Games"])
        XCTAssertTrue(vm.performWebAction("renameTag", data: ["treeID": tree.id, "nodeID": "games", "name": "Renamed Games"]),
            "Preserve the dispatcher's existing presentation response.")
        XCTAssertNil(vm.issue)
        XCTAssertEqual(renders, 0, "The caller owns presentation; the mutation must not invoke it directly.")
        XCTAssertEqual(hub.broadcasts.map(\.operation), [SharedBrowserBridgeOperation.classifierStateUpdatedBroadcast])
        XCTAssertEqual((hub.broadcasts.first?.body as? [String: String])?.count, 0)
        let refreshed = try browserPull()
        XCTAssertEqual(refreshed.tags.map(\.name), ["Renamed Games"])
        XCTAssertFalse(refreshed.pending)
        XCTAssertEqual(coordinator.snapshot().workspaceCatalog.videoClassifications, decisions)
        XCTAssertEqual(vm.localState?.workspaceCatalog.videoClassifications, decisions)
        XCTAssertTrue(vm.inFlightVideoClassifications.isEmpty)
        let requests = await engine.requests
        XCTAssertEqual(requests, 0)

        vm.refreshLocalState()
        XCTAssertEqual(hub.broadcasts.count, 1, "A later ordinary refresh must not duplicate the invalidation.")
        LocalStateFile.flushAllPendingWrites()
        XCTAssertEqual(try makeViewModel().localState?.workspaceCatalog.videoClassifications, decisions)
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

    func testLocalRuntimeSettingsAreAbsent() throws {
        let vm = try makeViewModel()
        let settings = try XCTUnwrap(vm.webSnapshot()["settings"] as? [String: Any])
        XCTAssertNil(settings["localModels"])
    }

    func testUnknownActionSurfacesAnIssueAndAsksForARerender() throws {
        let vm = try makeViewModel()
        let before = vm.webSnapshot()
        XCTAssertTrue(vm.performWebAction("definitely-not-an-action", data: [:]))
        XCTAssertNotNil(vm.issue, "an unknown action surfaces an issue")
        let after = vm.webSnapshot()
        XCTAssertEqual(Set(before.keys), Set(after.keys))
    }


    func testGroupConfidencePersistsIndependentlyAndGlobalSaveIsRetired() throws {
        let vm = try makeViewModel()
        _ = vm.performWebAction("createClassifierType", data: ["name": "A", "platformIDs": ["youtube"]])
        _ = vm.performWebAction("createClassifierType", data: ["name": "B", "platformIDs": ["reddit"]])
        let groups = try XCTUnwrap(vm.localState?.workspaceCatalog.classifierTypes)
        XCTAssertEqual(groups.count, 2)
        _ = vm.performWebAction("saveClassifierTypeTagging", data: [
            "typeID": groups[0].id, "minimumConfidence": "5", "houseRules": "prefer specific tags"
        ])
        XCTAssertNil(vm.issue)
        XCTAssertEqual(vm.localState?.workspaceCatalog.classifierTypes[0].tagging.minimumConfidence, 5)
        XCTAssertEqual(vm.localState?.workspaceCatalog.classifierTypes[1].tagging, .init())
        let before = vm.localState
        _ = vm.performWebAction("saveTaggingSettings", data: ["minimumConfidence": "1"])
        XCTAssertNotNil(vm.issue)
        XCTAssertEqual(vm.localState, before)
    }

    /// The complete web-action vocabulary. Each is probed with EMPTY data: a
    /// routed action either succeeds or fails on a missing/invalid field, but
    /// never with the `default:` "unsupported action" error. A case dropped
    /// while moving methods between files shows up here as exactly that error.
    /// (All 38 are safe headless with empty data — the backup ones throw on the
    /// missing owner code / directory or on "locked" before touching the Keychain.)

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

    func testSaveTaggingSettingsRejectsMalformedInputWithoutMutation() throws {
        let vm = try makeViewModel()
        let before = vm.localState?.workspaceCatalog
        XCTAssertTrue(vm.performWebAction("saveTaggingSettings", data: ["maximumTags": "3"]), "the error path re-sends the snapshot")
        XCTAssertNotNil(vm.issue)
        XCTAssertEqual(vm.localState?.workspaceCatalog, before)
    }
}
