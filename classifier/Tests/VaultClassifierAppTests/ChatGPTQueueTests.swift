import Foundation
import XCTest
import VaultClassifierCore
import VaultClassifierBridge
@testable import VaultClassifierApp

private actor CloudQueueEngine: BatchClassificationEngine {
    nonisolated let modelVersion: String
    let entered: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var prompts: [String] = []
    init(version: String, entered: XCTestExpectation) { modelVersion = version; self.entered = entered }
    func classify(_ request: LLMClassificationRequest) async throws -> LLMClassificationResult { try await classifyBatch([request])[0] }
    func classifyBatch(_ requests: [LLMClassificationRequest]) async throws -> [LLMClassificationResult] {
        prompts += requests.map(\.dynamicSuffix)
        if prompts.count == 1 {
            await withCheckedContinuation { continuation = $0; entered.fulfill() }
        }
        return requests.map { .init(tags: [.init(name: $0.dynamicSuffix.contains("New evidence") ? "New" : "Old", confidence: 5)]) }
    }
    func release() { continuation?.resume(); continuation = nil }
}

private struct CloudQueueResolver: CloudClassificationEngineResolving {
    let engine: CloudQueueEngine
    func resolveCloudEngine(for type: ClassifierTypeAsset) async throws -> any ClassificationEngine { engine }
}

@MainActor
private final class CloudQueueHub: SharedHubConnection {
    var onRequest: ((SharedHubClient.Request) -> SharedHubClient.Reply)?
    var onStateChange: (() -> Void)?
    var broadcasts: [[String: Any]] = []
    func disconnect() {}
    func broadcast(operation: String, body: Any) {
        if operation == SharedBrowserBridgeOperation.videoTagsUpdatedBroadcast, let body = body as? [String: Any] { broadcasts.append(body) }
    }
}

@MainActor
final class ChatGPTQueueTests: XCTestCase {
    func testChangedInFlightEvidenceRunsOnceMoreAndOnlyBroadcastsLatestResult() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-queue-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { LocalStateFile.flushAllPendingWrites(); try? FileManager.default.removeItem(at: directory) }
        let vm = try VaultClassifierViewModel(headlessVaultDirectory: directory)
        let coordinator = try XCTUnwrap(vm.coordinator)
        var catalog = coordinator.snapshot().workspaceCatalog
        let tree = TagTreeAsset(id: "tree", name: "Topics", nodes: [.init(id: "old", name: "Old"), .init(id: "new", name: "New")])
        catalog.trees.append(tree)
        let dataset = try XCTUnwrap(catalog.datasets.first)
        let type = ClassifierTypeAsset(id: "cloud", name: "Cloud", treeID: tree.id, treeRevision: tree.revision,
            datasetID: dataset.id, datasetRevision: dataset.revision, applicablePlatformIDs: ["youtube"],
            classificationProvider: .chatGPT, chatGPT: .init(accountID: "fixture", model: "fixture"))
        catalog.classifierTypes.append(type)
        try coordinator.updateWorkspaceCatalog(catalog)
        XCTAssertEqual(VaultClassifierViewModel.classificationChunkSize, 32)
        let entered = expectation(description: "First inference entered")
        let idle = expectation(description: "Latest evidence delivered")
        let engine = CloudQueueEngine(version: type.cloudModelVersion, entered: entered)
        coordinator.setCloudEngineResolver(CloudQueueResolver(engine: engine))
        let hub = CloudQueueHub(); vm.sharedHubClient = hub
        vm.classificationCoalescer.onIdle = { idle.fulfill() }
        vm.queueVideoClassification(platformID: "youtube", items: [.init(entryID: "v", creatorID: "c", title: "Old evidence")])
        await fulfillment(of: [entered], timeout: 3)
        let latest = NativeVideoTagsBatchItem(entryID: "v", creatorID: "c", title: "New evidence")
        vm.queueVideoClassification(platformID: "youtube", items: [latest, latest])
        await engine.release()
        await fulfillment(of: [idle], timeout: 3)
        let prompts = await engine.prompts
        XCTAssertEqual(prompts.count, 2)
        XCTAssertTrue(prompts[1].contains("New evidence"))
        XCTAssertEqual(hub.broadcasts.count, 1)
        let items = try XCTUnwrap(hub.broadcasts.first?["items"] as? [[String: Any]])
        let tags = try XCTUnwrap(items.first?["tags"] as? [[String: Any]])
        XCTAssertEqual(tags.first?["name"] as? String, "New")
        XCTAssertTrue(vm.inFlightVideoClassifications.isEmpty)
        XCTAssertTrue(vm.latestCloudClassificationInputs.isEmpty)
        await vm.shutdown()
    }
}
