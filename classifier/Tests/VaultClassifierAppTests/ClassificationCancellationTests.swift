import Foundation
import XCTest
import VaultClassifierBridge
@testable import VaultClassifierCore
@testable import VaultClassifierApp

/// Existing API controls also run on the unmodified lifetime baseline. No GPU,
/// hub, network or native resource fixture is involved.
private actor CancellationFixtureLLM: BatchClassificationEngine {
    nonisolated let modelVersion = "cancel-fixture/v1"
    var batches = 0
    var singles = 0
    func classifyBatch(_ requests: [LLMClassificationRequest]) async throws -> [LLMClassificationResult] {
        batches += 1
        throw CancellationError()
    }
    func classify(_ request: LLMClassificationRequest) async throws -> LLMClassificationResult {
        singles += 1
        throw CancellationError()
    }
}

@MainActor
final class ClassificationCancellationTests: XCTestCase {
    private var directory: URL!
    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("classifier-cancel-\(UUID().uuidString)")
    }
    override func tearDown() async throws {
        LocalStateFile.flushAllPendingWrites()
        try? FileManager.default.removeItem(at: directory)
    }
    private func fixture() throws -> VaultClassifierViewModel {
        let model = try VaultClassifierViewModel(headlessVaultDirectory: directory)
        let coordinator = try XCTUnwrap(model.coordinator)
        var catalog = WorkspaceCatalog.starter()
        let tree = TagTreeAsset(id: "cancel-tree", name: "Topics", nodes: [.init(id: "games", name: "Games")])
        catalog.trees.append(tree)
        let dataset = catalog.datasets[0]
        catalog.classifierTypes.append(.init(id: "cancel-type", name: "YouTube", treeID: tree.id, treeRevision: tree.revision,
            datasetID: dataset.id, datasetRevision: dataset.revision, applicablePlatformIDs: ["youtube"]))
        try coordinator.updateWorkspaceCatalog(catalog)
        return model
    }
    func testCancelledBatchIsNotRetriedOrConvertedToTerminalTags() async throws {
        let model = try fixture(), llm = CancellationFixtureLLM()
        model.coordinator?.setClassificationEngine(llm)
        let result = await model.resolveClassificationChunk(platformID: "youtube", [
            .init(entryID: "youtube:video:cancel00001", creatorID: "youtube:handle:@fixture", title: "Games"),
            .init(entryID: "youtube:video:cancel00003", creatorID: "youtube:handle:@fixture", title: "Games two")])
        XCTAssertTrue(result.isEmpty, "cancellation is not an empty-tag verdict")
        let batches = await llm.batches, singles = await llm.singles
        XCTAssertEqual(batches, 1)
        XCTAssertEqual(singles, 0, "cancelled batch must not retry each item")
        XCTAssertTrue(model.coordinator?.snapshot().workspaceCatalog.videoClassifications.isEmpty == true)
    }
    func testCancelledResolverDoesNotSubstituteStubOrPersistIt() async throws {
        struct Resolver: RetiredLocalEngineResolving {
            func resolveEngine(forModel fileName: String, configuration: TaggingSettings) async throws -> any ClassificationEngine {
                throw CancellationError()
            }
        }
        let model = try fixture(), coordinator = try XCTUnwrap(model.coordinator)
        coordinator.setClassificationEngineEngineResolver(Resolver())
        do {
            _ = try await coordinator.classifyVideo(platformID: "youtube", entryID: "youtube:video:cancel00002", creatorID: "creator", title: "Games")
            XCTFail("cancelled model resolution must throw")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(coordinator.snapshot().workspaceCatalog.videoClassifications.isEmpty)
    }
}
