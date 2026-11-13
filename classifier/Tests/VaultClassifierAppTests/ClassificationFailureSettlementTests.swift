import Foundation
import XCTest
import VaultClassifierCore
import VaultClassifierBridge
import VaultClassifierResearch
@testable import VaultClassifierApp

private actor SettlementLLM: BatchClassificationEngine {
    enum Mode { case allFail, mixed, succeed, empty }
    enum Failure: Error { case injected }
    nonisolated let modelVersion = "fixture/v1"
    private var mode: Mode
    private let beforeBatch: (@Sendable () -> Void)?
    private(set) var batchSizes: [Int] = []
    private(set) var singleTitles: [String] = []

    init(_ mode: Mode, beforeBatch: (@Sendable () -> Void)? = nil) {
        self.mode = mode
        self.beforeBatch = beforeBatch
    }
    func setMode(_ mode: Mode) { self.mode = mode }
    func classifyBatch(_ requests: [LLMClassificationRequest]) async throws -> [LLMClassificationResult] {
        batchSizes.append(requests.count)
        beforeBatch?()
        if mode == .allFail || (mode == .mixed && requests.contains(where: { $0.dynamicSuffix.contains("Failure") })) { throw Failure.injected }
        return requests.map { _ in answer() }
    }
    func classify(_ request: LLMClassificationRequest) async throws -> LLMClassificationResult {
        singleTitles.append(request.dynamicSuffix)
        if mode == .allFail || (mode == .mixed && request.dynamicSuffix.contains("Failure")) {
            throw Failure.injected
        }
        return answer()
    }
    private func answer() -> LLMClassificationResult {
        mode == .empty ? .init(tags: []) : .init(tags: [.init(name: "Games", confidence: 5)])
    }
}

/// Exercises the production coordinator and retry path, using isolated storage
/// and injected model errors. No hub, user preferences, model or network work.
@MainActor
final class ClassificationFailureSettlementTests: XCTestCase {
    private var directory: URL!
    private let failed = NativeVideoTagsBatchItem(entryID: "youtube:video:failed00001", creatorID: "youtube:handle:@fixture", title: "Failure title 中文")
    private let good = NativeVideoTagsBatchItem(entryID: "youtube:video:success0001", creatorID: "youtube:handle:@fixture", title: "Games success title")

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("vault-settlement-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDown() async throws {
        LocalStateFile.flushAllPendingWrites()
        try? FileManager.default.removeItem(at: directory)
    }
    private func makeModel() throws -> VaultClassifierViewModel {
        let model = try VaultClassifierViewModel(headlessVaultDirectory: directory)
        let coordinator = try XCTUnwrap(model.coordinator)
        var catalog = WorkspaceCatalog.starter()
        let tree = TagTreeAsset(id: "settlement-tree", name: "Topics", nodes: [.init(id: "games", name: "Games")])
        catalog.trees.append(tree)
        let dataset = catalog.datasets[0]
        catalog.classifierTypes.append(.init(id: "settlement-type", name: "YouTube", treeID: tree.id, treeRevision: tree.revision,
                                            datasetID: dataset.id, datasetRevision: dataset.revision, applicablePlatformIDs: ["youtube"], chatGPT: .init(accountID: "fixture", model: "fixture")))
        try coordinator.updateWorkspaceCatalog(catalog)
        for item in [failed, good] {
            try coordinator.collectPlatformEntry(.init(platform: "youtube", entryID: item.entryID, sourceID: item.creatorID,
                                                       surface: .feed, evidence: .init(title: item.title)))
        }
        XCTAssertEqual(coordinator.enabledClassificationPlatformIDs(), ["youtube"])
        return model
    }
    private func assertFailed(_ model: VaultClassifierViewModel, _ projection: VideoTagsProjection?, entryID: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(projection, file: file, line: line)
        XCTAssertEqual(model.failedCloudClassifications[VaultClassifierViewModel.inFlightKey("youtube", entryID)]?.code,
                       .taggingFailed, file: file, line: line)
    }
    private func assertNoFailedDecision(_ model: VaultClassifierViewModel, file: StaticString = #filePath, line: UInt = #line) throws {
        let coordinator = try XCTUnwrap(model.coordinator)
        XCTAssertFalse(coordinator.snapshot().workspaceCatalog.videoClassifications.contains { $0.entryID == failed.entryID }, file: file, line: line)
        XCTAssertNil(coordinator.cachedVideoTags(platformID: "youtube", entryID: failed.entryID), file: file, line: line)
        LocalStateFile.flushAllPendingWrites()
        let reopened = try VaultClassifierViewModel(headlessVaultDirectory: directory)
        XCTAssertFalse(reopened.coordinator?.snapshot().workspaceCatalog.videoClassifications.contains { $0.entryID == failed.entryID } == true, file: file, line: line)
    }

    func testAllErrorsCarryFailureStatusWithoutSavingFalseDecisions() async throws {
        let model = try makeModel(), engine = SettlementLLM(.allFail)
        model.coordinator?.setFixtureEngine(engine)
        let resolved = await model.resolveClassificationChunk(platformID: "youtube", [failed, good])
        XCTAssertTrue(resolved.isEmpty)
        assertFailed(model, resolved[failed.entryID], entryID: failed.entryID)
        assertFailed(model, resolved[good.entryID], entryID: good.entryID)
        LocalStateFile.flushAllPendingWrites()
        let reopened = try VaultClassifierViewModel(headlessVaultDirectory: directory)
        XCTAssertEqual(reopened.failedCloudClassifications[VaultClassifierViewModel.inFlightKey("youtube", failed.entryID)]?.code,
                       .taggingFailed, "failed status survives an ordinary restart")
        let batches = await engine.batchSizes, singles = await engine.singleTitles
        XCTAssertEqual(batches, [2]); XCTAssertTrue(singles.isEmpty, "failed cloud batches require Retry")
        try assertNoFailedDecision(model)
        XCTAssertTrue(model.coordinator?.snapshot().workspaceCatalog.videoClassifications.isEmpty == true)
    }

    func testRetryAfterTerminalFailureCanReplaceItWithRealModelResult() async throws {
        let model = try makeModel(), engine = SettlementLLM(.allFail)
        model.coordinator?.setFixtureEngine(engine)
        let first = await model.resolveClassificationChunk(platformID: "youtube", [failed])
        assertFailed(model, first[failed.entryID], entryID: failed.entryID); try assertNoFailedDecision(model)
        await engine.setMode(.succeed)
        let next = await model.resolveClassificationChunk(platformID: "youtube", [failed])
        XCTAssertEqual(next[failed.entryID]?.tags.map(\.id), ["games"])
        XCTAssertNil(model.failedCloudClassifications[VaultClassifierViewModel.inFlightKey("youtube", failed.entryID)])
        LocalStateFile.flushAllPendingWrites()
        let reopened = try VaultClassifierViewModel(headlessVaultDirectory: directory)
        XCTAssertNil(reopened.failedCloudClassifications[VaultClassifierViewModel.inFlightKey("youtube", failed.entryID)])
        XCTAssertEqual(next[failed.entryID], model.coordinator?.cachedVideoTags(platformID: "youtube", entryID: failed.entryID))
        XCTAssertEqual(model.coordinator?.snapshot().workspaceCatalog.videoClassifications.count, 1)
    }

    func testRetryArmsFailuresWithoutReplayingUnseenItems() async throws {
        let model = try makeModel(), engine = SettlementLLM(.allFail)
        model.coordinator?.setFixtureEngine(engine)
        _ = await model.resolveClassificationChunk(platformID: "youtube", [failed, good])
        XCTAssertEqual(model.failedCloudClassifications.count, 2)
        await engine.setMode(.succeed)
        let callsBefore = (await engine.batchSizes).count + (await engine.singleTitles).count

        func pull(_ item: NativeVideoTagsBatchItem, newlyShown: Bool) throws -> NativeVideoTagsBatchResponseItem {
            var requestItem = item
            requestItem.newAppearance = newlyShown
            let request = NativeVideoTagsBatchRequest(platformID: "youtube", items: [requestItem])
            let reply = model.handleSharedHubRequest(.init(sourcePeerID: "test-browser", requestID: UUID().uuidString,
                operation: .videoTagsBatch, bodyData: try JSONEncoder().encode(request)))
            XCTAssertNil(reply.error)
            let response = try JSONDecoder().decode(NativeVideoTagsBatchResponse.self,
                from: JSONSerialization.data(withJSONObject: XCTUnwrap(reply.body)))
            return try XCTUnwrap(response.items.first)
        }

        XCTAssertNotNil(try pull(failed, newlyShown: true).failureCode,
            "Before Retry, a failed item stays failed even when it appears again.")
        await model.resumeChatGPTClassificationsForVisibleEntries()
        XCTAssertEqual(model.failedCloudClassifications.count, 2)
        let callsAfterRetry = (await engine.batchSizes).count + (await engine.singleTitles).count
        XCTAssertEqual(callsAfterRetry, callsBefore,
            "Retry must not dispatch the saved failure queue.")
        XCTAssertNotNil(try pull(failed, newlyShown: false).failureCode,
            "An existing card remains failed after Retry.")
        let idle = expectation(description: "Newly shown failed video classified")
        model.classificationCoalescer.onIdle = { idle.fulfill() }
        XCTAssertTrue(try pull(failed, newlyShown: true).pending)
        await fulfillment(of: [idle], timeout: 3)
        XCTAssertEqual(model.coordinator?.cachedVideoTags(platformID: "youtube", entryID: failed.entryID)?.tags.map(\.id), ["games"])
        XCTAssertNil(model.failedCloudClassifications[VaultClassifierViewModel.inFlightKey("youtube", failed.entryID)])
        XCTAssertNotNil(model.failedCloudClassifications[VaultClassifierViewModel.inFlightKey("youtube", good.entryID)],
            "The other old failure remains stored and was not classified.")
    }

    func testUndispatchedFailureRetriesOnNewAppearanceWithoutRetryClick() async throws {
        let model = try makeModel(), engine = SettlementLLM(.succeed)
        model.coordinator?.setFixtureEngine(engine)
        let key = VaultClassifierViewModel.inFlightKey("youtube", failed.entryID)
        model.failedCloudClassifications[key] = .init(platform: "youtube", item: failed,
            code: .serviceUnavailable, retryWithoutDispatch: true)
        XCTAssertTrue(model.persistFailedClassifications())

        func pull(_ newlyShown: Bool) throws -> NativeVideoTagsResponse {
            let request = NativeVideoTagsRequest(platformID: "youtube", entryID: failed.entryID,
                creatorID: failed.creatorID, title: failed.title, newAppearance: newlyShown)
            let reply = model.handleSharedHubRequest(.init(sourcePeerID: "test-browser", requestID: UUID().uuidString,
                operation: .videoTags, bodyData: try JSONEncoder().encode(request)))
            XCTAssertNil(reply.error)
            return try JSONDecoder().decode(NativeVideoTagsResponse.self,
                from: JSONSerialization.data(withJSONObject: XCTUnwrap(reply.body)))
        }

        XCTAssertNotNil(try pull(false).failureCode)
        let idle = expectation(description: "Undispatched failure retried")
        model.classificationCoalescer.onIdle = { idle.fulfill() }
        XCTAssertTrue(try pull(true).pending)
        await fulfillment(of: [idle], timeout: 3)
        XCTAssertNil(model.failedCloudClassifications[key])
        XCTAssertEqual(model.coordinator?.cachedVideoTags(platformID: "youtube", entryID: failed.entryID)?.tags.map(\.id), ["games"])
    }

    func testHumanCorrectionSurvivesFailedSiblingWithoutRunningItsModel() async throws {
        let model = try makeModel(), engine = SettlementLLM(.allFail)
        let coordinator = try XCTUnwrap(model.coordinator)
        coordinator.setFixtureEngine(engine)
        let manual = try coordinator.submitCorrection(classifierTypeID: "settlement-type", platformID: "youtube", entryID: good.entryID, correctTagIDs: ["games"])
        let resolved = await model.resolveClassificationChunk(platformID: "youtube", [failed, good])
        assertFailed(model, resolved[failed.entryID], entryID: failed.entryID)
        XCTAssertEqual(resolved[good.entryID], manual)
        XCTAssertFalse(resolved[good.entryID]?.predicted ?? true)
        let titles = await engine.singleTitles
        XCTAssertFalse(titles.contains { $0.contains(good.title) })
        XCTAssertEqual(coordinator.snapshot().workspaceCatalog.videoClassifications.first?.source, .humanCorrected)
        try assertNoFailedDecision(model)
    }

    func testCurrentCachedModelResultSurvivesFailedSibling() async throws {
        let model = try makeModel(), engine = SettlementLLM(.succeed)
        let coordinator = try XCTUnwrap(model.coordinator)
        coordinator.setFixtureEngine(engine)
        _ = await model.resolveClassificationChunk(platformID: "youtube", [good])
        let cached = try XCTUnwrap(coordinator.cachedVideoTags(platformID: "youtube", entryID: good.entryID))
        await engine.setMode(.allFail)
        let resolved = await model.resolveClassificationChunk(platformID: "youtube", [failed, good])
        assertFailed(model, resolved[failed.entryID], entryID: failed.entryID)
        XCTAssertEqual(resolved[good.entryID], cached)
        XCTAssertEqual(coordinator.cachedVideoTags(platformID: "youtube", entryID: good.entryID), cached)
        XCTAssertEqual(coordinator.snapshot().workspaceCatalog.videoClassifications.map(\.entryID), [good.entryID])
        try assertNoFailedDecision(model)
    }

    func testDisablingClassificationDuringFailureSuppressesTerminalDelivery() async throws {
        let model = try makeModel(), coordinator = try XCTUnwrap(model.coordinator)
        let engine = SettlementLLM(.allFail, beforeBatch: {
            var settings = coordinator.snapshot().settings
            settings.classificationEnabled = false
            try? coordinator.updateSettings(settings)
        })
        coordinator.setFixtureEngine(engine)
        let resolved = await model.resolveClassificationChunk(platformID: "youtube", [failed, good])
        XCTAssertTrue(resolved.isEmpty)
        let singles = await engine.singleTitles
        XCTAssertTrue(singles.isEmpty)
        try assertNoFailedDecision(model)
    }

    func testNaturalEmptyModelDecisionRemainsCachedInsteadOfBeingAFailureFallback() async throws {
        let model = try makeModel(), engine = SettlementLLM(.empty)
        let coordinator = try XCTUnwrap(model.coordinator)
        coordinator.setFixtureEngine(engine)
        let resolved = await model.resolveClassificationChunk(platformID: "youtube", [failed])
        XCTAssertTrue(resolved[failed.entryID]?.tags.isEmpty == true)
        XCTAssertEqual(resolved[failed.entryID], coordinator.cachedVideoTags(platformID: "youtube", entryID: failed.entryID))
        XCTAssertEqual(coordinator.snapshot().workspaceCatalog.videoClassifications.count, 1)
        XCTAssertEqual(coordinator.snapshot().workspaceCatalog.videoClassifications.first?.source, .model)
    }

    func testProductionChunkClearsInFlightKeysAfterTerminalErrors() async throws {
        let model = try makeModel(), engine = SettlementLLM(.allFail)
        model.coordinator?.setFixtureEngine(engine)
        model.inFlightVideoClassifications = Set([failed, good].map { VaultClassifierViewModel.inFlightKey("youtube", $0.entryID) })
        await model.classifyChunk(platformID: "youtube", [failed, good])
        XCTAssertTrue(model.inFlightVideoClassifications.isEmpty)
        try assertNoFailedDecision(model)
    }
    func testProductionChunkPersistsSuccessfulItemDespiteSiblingFailure() async throws {
        let model = try makeModel(), engine = SettlementLLM(.mixed)
        model.coordinator?.setFixtureEngine(engine)
        model.inFlightVideoClassifications = Set([failed, good].map { VaultClassifierViewModel.inFlightKey("youtube", $0.entryID) })
        await model.classifyChunk(platformID: "youtube", [failed, good])
        XCTAssertTrue(model.inFlightVideoClassifications.isEmpty)
        XCTAssertEqual(model.coordinator?.cachedVideoTags(platformID:"youtube",entryID:good.entryID)?.tags.map(\.id), ["games"])
        try assertNoFailedDecision(model)
        let titles = await engine.singleTitles
        XCTAssertEqual(titles.count, 2)
    }

    func testProviderErrorsMapToPresentationSafeFailureCodes() {
        XCTAssertEqual(VaultClassifierViewModel.taggingFailureCode(CloudClassificationError.usageLimit), .limitReached)
        XCTAssertEqual(VaultClassifierViewModel.taggingFailureCode(ChatGPTPlanError.usageUnavailable), .limitReached)
        XCTAssertEqual(VaultClassifierViewModel.taggingFailureCode(CloudClassificationError.signInRequired), .signInRequired)
        XCTAssertEqual(VaultClassifierViewModel.taggingFailureCode(ProviderTestHTTPError.status(401)), .accessDenied)
        XCTAssertEqual(VaultClassifierViewModel.taggingFailureCode(ProviderTestHTTPError.status(429)), .rateLimited)
        XCTAssertEqual(VaultClassifierViewModel.taggingFailureCode(ProviderTestHTTPError.status(503)), .serviceUnavailable)
        XCTAssertEqual(VaultClassifierViewModel.taggingFailureCode(URLError(.timedOut)), .connectionIssue)
    }
}
