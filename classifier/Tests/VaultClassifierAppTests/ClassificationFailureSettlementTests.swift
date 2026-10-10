import Foundation
import XCTest
import VaultClassifierCore
import VaultClassifierBridge
@testable import VaultClassifierApp

private struct SettlementDictionary: DictionaryEvidenceProviding {
    func localEvidence(title: String, creatorID: String) -> DictionaryEvidence { .init() }
    func evidence(title: String, creatorID: String, subscriberCount: Int64?) async -> DictionaryEvidence { .init() }
}

private actor SettlementLLM: OnDeviceBatchLLM {
    enum Mode { case allFail, mixed, succeed, empty }
    enum Failure: Error { case injected }
    nonisolated let modelVersion = "llamacpp/" + SpeedQualityDial.balanced.ggufFileName
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
        if mode == .allFail || mode == .mixed { throw Failure.injected }
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
                                            datasetID: dataset.id, datasetRevision: dataset.revision, applicablePlatformIDs: ["youtube"]))
        try coordinator.updateWorkspaceCatalog(catalog)
        coordinator.setDictionaryProvider(SettlementDictionary())
        for item in [failed, good] {
            try coordinator.collectPlatformEntry(.init(platform: "youtube", entryID: item.entryID, sourceID: item.creatorID,
                                                       surface: .feed, evidence: .init(title: item.title)))
        }
        XCTAssertEqual(coordinator.enabledClassificationPlatformIDs(), ["youtube"])
        return model
    }
    private func assertTerminal(_ projection: VideoTagsProjection?, file: StaticString = #filePath, line: UInt = #line) throws {
        let value = try XCTUnwrap(projection, file: file, line: line)
        XCTAssertTrue(value.tags.isEmpty, file: file, line: line)
        XCTAssertFalse(value.predicted, file: file, line: line)
        XCTAssertTrue(value.confidenceByTagID.isEmpty, file: file, line: line)
    }
    private func assertNoFailedDecision(_ model: VaultClassifierViewModel, file: StaticString = #filePath, line: UInt = #line) throws {
        let coordinator = try XCTUnwrap(model.coordinator)
        XCTAssertFalse(coordinator.snapshot().workspaceCatalog.videoClassifications.contains { $0.entryID == failed.entryID }, file: file, line: line)
        XCTAssertNil(coordinator.cachedVideoTags(platformID: "youtube", entryID: failed.entryID), file: file, line: line)
        LocalStateFile.flushAllPendingWrites()
        let reopened = try VaultClassifierViewModel(headlessVaultDirectory: directory)
        XCTAssertFalse(reopened.coordinator?.snapshot().workspaceCatalog.videoClassifications.contains { $0.entryID == failed.entryID } == true, file: file, line: line)
    }

    func testAllErrorsSettleEveryOriginalEntryWithoutSavingFalseDecisions() async throws {
        let model = try makeModel(), engine = SettlementLLM(.allFail)
        model.coordinator?.setOnDeviceLLM(engine)
        let resolved = await model.resolveClassificationChunk(platformID: "youtube", [failed, good])
        XCTAssertEqual(Set(resolved.keys), Set([failed.entryID, good.entryID]))
        try assertTerminal(resolved[failed.entryID]); try assertTerminal(resolved[good.entryID])
        let batches = await engine.batchSizes, singles = await engine.singleTitles
        XCTAssertEqual(batches, [2]); XCTAssertEqual(singles.count, 2)
        XCTAssertTrue(singles[0].contains(failed.title)); XCTAssertTrue(singles[1].contains(good.title))
        try assertNoFailedDecision(model)
        XCTAssertTrue(model.coordinator?.snapshot().workspaceCatalog.videoClassifications.isEmpty == true)
    }

    func testBatchFailurePreservesSuccessfulSingleAndSettlesOnlyFailedSingle() async throws {
        let model = try makeModel(), engine = SettlementLLM(.mixed)
        model.coordinator?.setOnDeviceLLM(engine)
        let resolved = await model.resolveClassificationChunk(platformID: "youtube", [failed, good])
        try assertTerminal(resolved[failed.entryID])
        XCTAssertEqual(resolved[good.entryID]?.tags.map(\.id), ["games"])
        XCTAssertEqual(resolved[good.entryID]?.confidenceByTagID["games"], 5)
        XCTAssertEqual(resolved[good.entryID], model.coordinator?.cachedVideoTags(platformID: "youtube", entryID: good.entryID))
        XCTAssertEqual(model.coordinator?.snapshot().workspaceCatalog.videoClassifications.map(\.entryID), [good.entryID])
        try assertNoFailedDecision(model)
    }

    func testRetryAfterTerminalFailureCanReplaceItWithRealModelResult() async throws {
        let model = try makeModel(), engine = SettlementLLM(.allFail)
        model.coordinator?.setOnDeviceLLM(engine)
        let first = await model.resolveClassificationChunk(platformID: "youtube", [failed])
        try assertTerminal(first[failed.entryID]); try assertNoFailedDecision(model)
        await engine.setMode(.succeed)
        let next = await model.resolveClassificationChunk(platformID: "youtube", [failed])
        XCTAssertEqual(next[failed.entryID]?.tags.map(\.id), ["games"])
        XCTAssertEqual(next[failed.entryID], model.coordinator?.cachedVideoTags(platformID: "youtube", entryID: failed.entryID))
        XCTAssertEqual(model.coordinator?.snapshot().workspaceCatalog.videoClassifications.count, 1)
    }

    func testHumanCorrectionSurvivesFailedSiblingWithoutRunningItsModel() async throws {
        let model = try makeModel(), engine = SettlementLLM(.allFail)
        let coordinator = try XCTUnwrap(model.coordinator)
        coordinator.setOnDeviceLLM(engine)
        let manual = try coordinator.submitCorrection(classifierTypeID: "settlement-type", platformID: "youtube", entryID: good.entryID, correctTagIDs: ["games"])
        let resolved = await model.resolveClassificationChunk(platformID: "youtube", [failed, good])
        try assertTerminal(resolved[failed.entryID])
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
        coordinator.setOnDeviceLLM(engine)
        _ = await model.resolveClassificationChunk(platformID: "youtube", [good])
        let cached = try XCTUnwrap(coordinator.cachedVideoTags(platformID: "youtube", entryID: good.entryID))
        await engine.setMode(.allFail)
        let resolved = await model.resolveClassificationChunk(platformID: "youtube", [failed, good])
        try assertTerminal(resolved[failed.entryID])
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
        coordinator.setOnDeviceLLM(engine)
        let resolved = await model.resolveClassificationChunk(platformID: "youtube", [failed, good])
        XCTAssertTrue(resolved.isEmpty)
        let singles = await engine.singleTitles
        XCTAssertTrue(singles.isEmpty)
        try assertNoFailedDecision(model)
    }

    func testNaturalEmptyModelDecisionRemainsCachedInsteadOfBeingAFailureFallback() async throws {
        let model = try makeModel(), engine = SettlementLLM(.empty)
        let coordinator = try XCTUnwrap(model.coordinator)
        coordinator.setOnDeviceLLM(engine)
        let resolved = await model.resolveClassificationChunk(platformID: "youtube", [failed])
        XCTAssertTrue(resolved[failed.entryID]?.tags.isEmpty == true)
        XCTAssertEqual(resolved[failed.entryID], coordinator.cachedVideoTags(platformID: "youtube", entryID: failed.entryID))
        XCTAssertEqual(coordinator.snapshot().workspaceCatalog.videoClassifications.count, 1)
        XCTAssertEqual(coordinator.snapshot().workspaceCatalog.videoClassifications.first?.source, .model)
    }

    func testProductionChunkClearsInFlightKeysAfterTerminalErrors() async throws {
        let model = try makeModel(), engine = SettlementLLM(.allFail)
        model.coordinator?.setOnDeviceLLM(engine)
        model.inFlightVideoClassifications = Set([failed, good].map { VaultClassifierViewModel.inFlightKey("youtube", $0.entryID) })
        await model.classifyChunk(platformID: "youtube", [failed, good])
        XCTAssertTrue(model.inFlightVideoClassifications.isEmpty)
        try assertNoFailedDecision(model)
    }
}
