import XCTest
@testable import VaultClassifierCore

private final class CoordinatorRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [LLMClassificationRequest] = []
    func append(_ request: LLMClassificationRequest) { lock.withLock { stored.append(request) } }
    var requests: [LLMClassificationRequest] { lock.withLock { stored } }
}

private struct CoordinatorRecordingLLM: OnDeviceLLM {
    let modelVersion = "recording/v1"
    let recorder: CoordinatorRequestRecorder
    func classify(_ request: LLMClassificationRequest) async throws -> LLMClassificationResult {
        recorder.append(request)
        return .init(tags: [])
    }
}

private final class SubjectExtractionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var started = 0
    private var released = false

    var count: Int { lock.withLock { started } }

    func extract() async -> ResearchSubject? {
        let shouldWait = lock.withLock { () -> Bool in
            started += 1
            return !released
        }
        if shouldWait {
            await withCheckedContinuation { continuation in
                let resumeNow = lock.withLock { () -> Bool in
                    if released { return true }
                    self.continuation = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }
        return ResearchSubject(kind: .term, subject: "HermitCraft")
    }

    func waitUntilStarted() async {
        while count == 0 { await Task.yield() }
    }

    func release() {
        let pending = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            released = true
            defer { continuation = nil }
            return continuation
        }
        pending?.resume()
    }
}

private struct DecliningSubjectLLM: OnDeviceLLM, OnDeviceResearchSubjectExtracting {
    let modelVersion = "decline/v1"
    let probe: SubjectExtractionProbe
    func classify(_ request: LLMClassificationRequest) async throws -> LLMClassificationResult {
        .init(tags: [])
    }
    func extractResearchSubject(_ request: LLMResearchSubjectRequest) async throws -> ResearchSubject? {
        await probe.extract()
    }
}

private final class ImmediateSubjectProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCount = 0
    var count: Int { lock.withLock { storedCount } }
    func record() { lock.withLock { storedCount += 1 } }
}

private struct ImmediateSubjectLLM: OnDeviceLLM, OnDeviceResearchSubjectExtracting {
    let modelVersion = "subject/v1"
    let probe: ImmediateSubjectProbe
    func classify(_ request: LLMClassificationRequest) async throws -> LLMClassificationResult {
        .init(tags: [])
    }
    func extractResearchSubject(_ request: LLMResearchSubjectRequest) async throws -> ResearchSubject? {
        probe.record()
        return ResearchSubject(kind: .term, subject: "HermitCraft")
    }
}

private final class NeedsRequestProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [LLMResearchNeedsRequest] = []
    private var storedLegacyCount = 0
    func record(_ request: LLMResearchNeedsRequest) { lock.withLock { stored.append(request) } }
    func recordLegacy() { lock.withLock { storedLegacyCount += 1 } }
    var requests: [LLMResearchNeedsRequest] { lock.withLock { stored } }
    var legacyCount: Int { lock.withLock { storedLegacyCount } }
}

/// Declines every title and supports Decode 2 (term extraction over the prompt).
private struct NeedsExtractingLLM: OnDeviceLLM, OnDeviceResearchSubjectExtracting, OnDeviceResearchNeedsExtracting {
    let modelVersion = "needs/v1"
    let probe: NeedsRequestProbe
    let terms: [String]
    func classify(_ request: LLMClassificationRequest) async throws -> LLMClassificationResult { .init(tags: []) }
    func extractResearchSubject(_ request: LLMResearchSubjectRequest) async throws -> ResearchSubject? {
        probe.recordLegacy()
        return ResearchSubject(kind: .term, subject: "LegacySubject")
    }
    func researchNeeds(_ request: LLMResearchNeedsRequest) async throws -> [String] {
        probe.record(request)
        return terms
    }
}

private final class BatchCallProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storedBatchSizes: [Int] = []
    private var storedSingles = 0
    func recordBatch(_ size: Int) { lock.withLock { storedBatchSizes.append(size) } }
    func recordSingle() { lock.withLock { storedSingles += 1 } }
    var batchSizes: [Int] { lock.withLock { storedBatchSizes } }
    var singles: Int { lock.withLock { storedSingles } }
}

/// A batching engine: tags a video "Games" when its title mentions games.
private struct BatchingLLM: OnDeviceBatchLLM {
    let modelVersion = "batching/v1"
    let probe: BatchCallProbe
    private func answer(_ request: LLMClassificationRequest) -> LLMClassificationResult {
        request.dynamicSuffix.lowercased().contains("games")
            ? .init(tags: [LLMTagScore(name: "Games", confidence: 5)]) : .init(tags: [])
    }
    func classify(_ request: LLMClassificationRequest) async throws -> LLMClassificationResult {
        probe.recordSingle()
        return answer(request)
    }
    func classifyBatch(_ requests: [LLMClassificationRequest]) async throws -> [LLMClassificationResult] {
        probe.recordBatch(requests.count)
        return requests.map(answer)
    }
}

private final class ResearchSubjectRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ResearchSubject] = []
    func append(_ subject: ResearchSubject) { lock.withLock { stored.append(subject) } }
    var subjects: [ResearchSubject] { lock.withLock { stored } }
}

private actor CountingEngineResolver: OnDeviceLLMEngineResolving {
    private(set) var requestedFiles: [String] = []
    let engine: any OnDeviceLLM

    init(engine: any OnDeviceLLM) { self.engine = engine }

    func resolveEngine(
        forModel fileName: String,
        configuration: LocalLLMSettings
    ) async throws -> any OnDeviceLLM {
        requestedFiles.append(fileName)
        return engine
    }
}

final class VideoClassificationCoordinatorTests: XCTestCase {
    func testInheritedModelFastPathAvoidsResolverAndExplicitModelUsesIt() async throws {
        let (coordinator, root) = try makeCoordinatorWithYouTubeType()
        defer { try? FileManager.default.removeItem(at: root) }
        let selectedRecorder = CoordinatorRequestRecorder()
        let resolver = CountingEngineResolver(engine: CoordinatorRecordingLLM(recorder: selectedRecorder))
        coordinator.setOnDeviceLLMEngineResolver(resolver)

        _ = try await coordinator.classifyVideo(
            platformID: "youtube", entryID: "inherited", creatorID: "creator", title: "Title"
        )
        let inheritedRequests = await resolver.requestedFiles
        XCTAssertEqual(inheritedRequests, [])

        var catalog = coordinator.snapshot().workspaceCatalog
        let index = try XCTUnwrap(catalog.classifierTypes.firstIndex(where: { $0.applicablePlatformID == "youtube" }))
        catalog.classifierTypes[index].modelFileName = "selected.gguf"
        catalog.classifierTypes[index].localModelOverrides = .init(
            allowDecline: false,
            confidenceThresholds: [0.1, 0.3, 0.6, 0.9]
        )
        try coordinator.updateWorkspaceCatalog(catalog)

        _ = try await coordinator.classifyVideo(
            platformID: "youtube", entryID: "selected", creatorID: "creator", title: "Title"
        )
        let selectedRequests = await resolver.requestedFiles
        XCTAssertEqual(selectedRequests, ["selected.gguf"])
        XCTAssertEqual(selectedRecorder.requests.count, 1)
        XCTAssertEqual(selectedRecorder.requests.first?.allowDecline, false)
        XCTAssertEqual(selectedRecorder.requests.first?.confidenceThresholds, [0.1, 0.3, 0.6, 0.9])
    }

    func testExplicitTypeModelAlsoPerformsResearchSubjectExtraction() async throws {
        let (coordinator, root) = try makeCoordinatorWithYouTubeType()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaultProbe = ImmediateSubjectProbe()
        let selectedProbe = ImmediateSubjectProbe()
        coordinator.setOnDeviceLLM(ImmediateSubjectLLM(probe: defaultProbe))
        coordinator.setOnDeviceLLMEngineResolver(CountingEngineResolver(
            engine: ImmediateSubjectLLM(probe: selectedProbe)
        ))
        try coordinator.updateSettings(.init(research: .init(enabled: true)))
        coordinator.setGroundedResearchQueue(GroundedResearchQueue(
            configurationProvider: { _ in nil },
            snapshotProvider: { _ in .init() },
            mutationWriter: { _ in },
            researcher: { _, _ in throw GroundedResearchError.invalidConfiguration }
        ))
        var catalog = coordinator.snapshot().workspaceCatalog
        let index = try XCTUnwrap(catalog.classifierTypes.firstIndex(where: { $0.applicablePlatformID == "youtube" }))
        catalog.classifierTypes[index].modelFileName = "selected.gguf"
        try coordinator.updateWorkspaceCatalog(catalog)

        _ = try await coordinator.classifyVideo(
            platformID: "youtube", entryID: "selected", creatorID: "creator", title: "Unclear"
        )
        for _ in 0..<100 where selectedProbe.count == 0 { await Task.yield() }

        XCTAssertEqual(selectedProbe.count, 1)
        XCTAssertEqual(defaultProbe.count, 0)
    }

    private func temporaryStateFile() -> (root: URL, file: LocalStateFile) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        return (root, LocalStateFile(url: root.appendingPathComponent("state.json")))
    }

    private func makeCoordinatorWithYouTubeType() throws -> (LocalClassifierCoordinator, URL) {
        let fixture = temporaryStateFile()
        let coordinator = try LocalClassifierCoordinator(verifiedPackage: SeedPackageLoader.bundled(), stateFile: fixture.file)

        var catalog = WorkspaceCatalog.starter()
        let tree = TagTreeAsset(id: "t", name: "Topics", nodes: [
            .init(id: "g", name: "Games"),
            .init(id: "p", name: "Politics"),
        ])
        catalog.trees.append(tree)
        let dataset = catalog.datasets[0]
        catalog.classifierTypes.append(ClassifierTypeAsset(
            id: "type", name: "YT", treeID: tree.id, treeRevision: tree.revision,
            datasetID: dataset.id, datasetRevision: dataset.revision, applicablePlatformID: "youtube"
        ))
        try coordinator.updateWorkspaceCatalog(catalog)
        // Sanity: the type survived reconciliation and targets youtube.
        let live = coordinator.snapshot().workspaceCatalog
        XCTAssertEqual(live.classifierTypes.first?.applicablePlatformID, "youtube")
        return (coordinator, fixture.root)
    }

    func testClassifyVideoProducesPerVideoTagsAndCaches() async throws {
        let (coordinator, root) = try makeCoordinatorWithYouTubeType()
        defer { try? FileManager.default.removeItem(at: root) }

        // No classification yet -> decision cache is empty.
        XCTAssertNil(coordinator.cachedVideoTags(platformID: "youtube", entryID: "youtube:video:v1"))

        // The stub LLM selects allowed tag names present in the prompt; the title
        // contains "Games" so we expect the Games tag.
        let projection = try await coordinator.classifyVideo(
            platformID: "youtube", entryID: "youtube:video:v1", creatorID: "c1",
            title: "A great Games montage"
        )
        XCTAssertEqual(projection.tags.map(\.id), ["g"])

        // Now the decision cache returns it without re-classifying.
        let cached = coordinator.cachedVideoTags(platformID: "youtube", entryID: "youtube:video:v1")
        XCTAssertEqual(cached?.tags.map(\.id), ["g"])
    }

    func testClassifyVideoUpdatesDerivedCreatorHistogram() async throws {
        let (coordinator, root) = try makeCoordinatorWithYouTubeType()
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try await coordinator.classifyVideo(
            platformID: "youtube", entryID: "youtube:video:v1", creatorID: "c1",
            title: "Games highlights"
        )
        let histogram = coordinator.snapshot().workspaceCatalog
            .creatorHistogram(classifierTypeID: "type", platformID: "youtube", creatorID: "c1")
        XCTAssertEqual(histogram?.videoCount, 1)
        XCTAssertNotNil(histogram?.stats["g"])
    }

    func testClassifyVideoOnCollectionDisabledPlatformThrows() async throws {
        let fixture = temporaryStateFile()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = try LocalClassifierCoordinator(verifiedPackage: SeedPackageLoader.bundled(), stateFile: fixture.file)

        var catalog = WorkspaceCatalog.starter()
        if let index = catalog.bindings.firstIndex(where: { $0.id == "youtube" }) {
            catalog.bindings[index].collectionEnabled = false
        }
        try coordinator.updateWorkspaceCatalog(catalog)

        do {
            _ = try await coordinator.classifyVideo(
                platformID: "youtube", entryID: "v1", creatorID: "c1", title: "x")
            XCTFail("expected disabled-collection error")
        } catch {
            // expected
        }
    }

    func testClassifyVideoResolvesEffectiveOptionsPerType() async throws {
        let fixture = temporaryStateFile()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = try LocalClassifierCoordinator(
            verifiedPackage: SeedPackageLoader.bundled(), stateFile: fixture.file
        )
        var catalog = WorkspaceCatalog.starter()
        let treeA = TagTreeAsset(id: "ta", name: "A", nodes: [.init(id: "a", name: "Alpha")])
        let treeB = TagTreeAsset(id: "tb", name: "B", nodes: [.init(id: "b", name: "Beta")])
        catalog.trees += [treeA, treeB]
        let dataset = catalog.datasets[0]
        catalog.classifierTypes = [
            .init(
                id: "a", name: "A", treeID: treeA.id, treeRevision: treeA.revision,
                datasetID: dataset.id, datasetRevision: dataset.revision,
                applicablePlatformID: "youtube",
                localModelOverrides: .init(
                    houseRules: "Type A rule.", allowDecline: false,
                    confidenceThresholds: [0.1, 0.3, 0.6, 0.9],
                    maximumTags: 2
                ), order: 0
            ),
            // A platform belongs to at most one classifier type, so the second
            // type lives on its own platform (same shared dataset).
            .init(
                id: "b", name: "B", treeID: treeB.id, treeRevision: treeB.revision,
                datasetID: dataset.id, datasetRevision: dataset.revision,
                applicablePlatformID: "bilibili", order: 1
            ),
        ]
        _ = try catalog.ensurePlatformBinding("bilibili")
        try coordinator.updateWorkspaceCatalog(catalog)
        coordinator.setClassificationOptions(maximumTags: 3, houseRules: "Global rule.")
        let recorder = CoordinatorRequestRecorder()
        coordinator.setOnDeviceLLM(CoordinatorRecordingLLM(recorder: recorder))

        _ = try await coordinator.classifyVideo(
            platformID: "youtube", entryID: "v", creatorID: "c", title: "title"
        )
        _ = try await coordinator.classifyVideo(
            platformID: "bilibili", entryID: "w", creatorID: "c", title: "title"
        )

        XCTAssertEqual(recorder.requests.count, 2, "one request per platform's single type")
        XCTAssertTrue(recorder.requests[0].staticPrefix.contains("Type A rule."))
        XCTAssertFalse(recorder.requests[0].staticPrefix.contains("Global rule."))
        XCTAssertEqual(recorder.requests[0].allowDecline, false)
        XCTAssertEqual(recorder.requests[0].confidenceThresholds, [0.1, 0.3, 0.6, 0.9])
        XCTAssertTrue(recorder.requests[1].staticPrefix.contains("Global rule."))
        XCTAssertNil(recorder.requests[1].allowDecline)
        XCTAssertNil(recorder.requests[1].confidenceThresholds)
        XCTAssertEqual(recorder.requests.map(\.maximumTags), [2, 3], "type A overrides maximumTags (2); type B inherits the global (3)")
    }

    func testResearchTriggerIsExplicitModelDeclineOnly() {
        let base = VideoClassification(
            classifierTypeID: "type", platformID: "youtube", entryID: "v", creatorID: "c",
            treeID: "tree", treeRevision: 1,
            tags: [], source: .model, modelVersion: "m"
        )
        XCTAssertTrue(LocalClassifierCoordinator.hasExplicitModelDecline([base]))
        var lowConfidence = base
        lowConfidence.tags = [.init(tagID: "tag", confidence: 1)]
        XCTAssertFalse(LocalClassifierCoordinator.hasExplicitModelDecline([lowConfidence]))
        var knowledgeDecline = base
        knowledgeDecline.source = .modelKnowledge
        XCTAssertFalse(LocalClassifierCoordinator.hasExplicitModelDecline([knowledgeDecline]))
    }

    func testUrgencyDrivenResearchTrigger() {
        // RESEARCH-REDESIGN §7: research fires when a video's DERIVED urgency
        // (inverse mean confidence; decline = 5) reaches the user's urgencyFloor.
        let decline = VideoClassification(
            classifierTypeID: "type", platformID: "youtube", entryID: "v", creatorID: "c",
            treeID: "tree", treeRevision: 1, tags: [], source: .model, modelVersion: "m"
        )
        var low = decline            // confidence 3 → urgency 3
        low.tags = [.init(tagID: "tag", confidence: 3)]
        var mid = decline            // confidence 4 → urgency 2
        mid.tags = [.init(tagID: "tag", confidence: 4)]
        var high = decline           // confidence 5 → urgency 1
        high.tags = [.init(tagID: "tag", confidence: 5)]
        var grounded = low           // non-model source never triggers
        grounded.source = .modelKnowledge

        XCTAssertEqual(LocalClassifierCoordinator.researchUrgency(for: decline), 5)
        XCTAssertEqual(LocalClassifierCoordinator.researchUrgency(for: low), 3)
        XCTAssertEqual(LocalClassifierCoordinator.researchUrgency(for: high), 1)

        // A decline (urgency 5) triggers at any floor.
        XCTAssertTrue(LocalClassifierCoordinator.shouldTriggerResearch(for: decline, settings: .init(urgencyFloor: 5)))
        // Low confidence (urgency 3) triggers at floor 3, not at a stricter floor 4.
        XCTAssertTrue(LocalClassifierCoordinator.shouldTriggerResearch(for: low, settings: .init(urgencyFloor: 3)))
        XCTAssertFalse(LocalClassifierCoordinator.shouldTriggerResearch(for: low, settings: .init(urgencyFloor: 4)))
        // Confident classifications (urgency 1–2) don't trigger at the default floor.
        XCTAssertFalse(LocalClassifierCoordinator.shouldTriggerResearch(for: mid, settings: .init(urgencyFloor: 3)))
        XCTAssertFalse(LocalClassifierCoordinator.shouldTriggerResearch(for: high, settings: .init(urgencyFloor: 3)))
        // Non-model (grounded) results never trigger, whatever the urgency/floor.
        XCTAssertFalse(LocalClassifierCoordinator.shouldTriggerResearch(for: grounded, settings: .init(urgencyFloor: 1)))
    }

    func testEffectiveResearchSettingsInheritOverrideAndRespectMasterGate() {
        let global = ResearchSettings(
            enabled: true,
            llmProviderProfileID: "global-llm",
            llmModelIdentifier: "global-model",
            requestsPerMinute: 6,
            dailyTokenLimit: 10_000,
            urgencyFloor: 5
        )
        let inherited = ClassifierTypeAsset(
            id: "inherit", name: "Inherit", treeID: "tree", treeRevision: 1,
            datasetID: "dataset", datasetRevision: 1
        )
        XCTAssertEqual(
            LocalClassifierCoordinator.effectiveResearchSettings(global: global, for: inherited),
            global
        )

        let override = ResearchSettings(
            enabled: true,
            llmProviderProfileID: "type-llm",
            llmModelIdentifier: "type-model",
            requestsPerMinute: 15,
            dailyTokenLimit: 20_000,
            urgencyFloor: 3
        )
        let overridden = ClassifierTypeAsset(
            id: "override", name: "Override", treeID: "tree", treeRevision: 1,
            datasetID: "dataset", datasetRevision: 1, researchOverrides: override
        )
        XCTAssertEqual(
            LocalClassifierCoordinator.effectiveResearchSettings(global: global, for: overridden),
            override
        )

        var masterOff = global
        masterOff.enabled = false
        XCTAssertNil(LocalClassifierCoordinator.effectiveResearchSettings(global: masterOff, for: overridden))

        var typeOff = override
        typeOff.enabled = false
        let optedOut = ClassifierTypeAsset(
            id: "off", name: "Off", treeID: "tree", treeRevision: 1,
            datasetID: "dataset", datasetRevision: 1, researchOverrides: typeOff
        )
        XCTAssertNil(LocalClassifierCoordinator.effectiveResearchSettings(global: global, for: optedOut))
    }

    func testResearchDisabledDoesNoSecondDecode() async throws {
        let (coordinator, root) = try makeCoordinatorWithYouTubeType()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = SubjectExtractionProbe()
        coordinator.setOnDeviceLLM(DecliningSubjectLLM(probe: probe))
        _ = try await coordinator.classifyVideo(
            platformID: "youtube", entryID: "v", creatorID: "youtube:handle:@creator", title: "HermitCraft"
        )
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(probe.count, 0)
    }

    func testDeclineSubjectDecodeIsFireAndForgetFromLiveClassification() async throws {
        let (coordinator, root) = try makeCoordinatorWithYouTubeType()
        defer { try? FileManager.default.removeItem(at: root) }
        try coordinator.updateSettings(.init(research: .init(enabled: true)))
        let queue = GroundedResearchQueue(
            configurationProvider: { _ in nil },
            snapshotProvider: { _ in .init() },
            mutationWriter: { _ in },
            researcher: { _, _ in throw GroundedResearchError.invalidConfiguration }
        )
        coordinator.setGroundedResearchQueue(queue)
        let probe = SubjectExtractionProbe()
        coordinator.setOnDeviceLLM(DecliningSubjectLLM(probe: probe))

        // This returns while the second decode is still deliberately blocked.
        _ = try await coordinator.classifyVideo(
            platformID: "youtube", entryID: "v", creatorID: "youtube:handle:@creator", title: "HermitCraft"
        )
        await probe.waitUntilStarted()
        XCTAssertEqual(probe.count, 1)
        probe.release()
        for _ in 0..<20 { await Task.yield() }
        await queue.waitUntilIdle()
    }

    func testRecordResearchKnowledgeReclassifiesOutsideLockAndCallsBack() async throws {
        let (coordinator, root) = try makeCoordinatorWithYouTubeType()
        defer { try? FileManager.default.removeItem(at: root) }
        var catalog = coordinator.snapshot().workspaceCatalog
        let datasetIndex = try XCTUnwrap(catalog.datasets.firstIndex(where: { $0.id == catalog.bindings.first(where: { $0.id == "youtube" })?.datasetID }))
        _ = catalog.datasets[datasetIndex].upsertCollectedEntry(.init(
            id: "row", platformID: "youtube", entryID: "v", creatorID: "c",
            creatorName: "Creator", entryType: "video", title: "HermitCraft Games"
        ))
        try coordinator.updateWorkspaceCatalog(catalog)
        _ = try await coordinator.classifyVideo(
            platformID: "youtube", entryID: "v", creatorID: "c", title: "HermitCraft Games"
        )
        let callback = expectation(description: "reclassified callback")
        coordinator.setOnVideoReclassified { platformID, entryID, _ in
            if platformID == "youtube", entryID == "v" { callback.fulfill() }
        }

        try await coordinator.recordResearchKnowledge(
            .init(kind: .term, subject: "HermitCraft", meaning: "A Minecraft Games series."),
            usage: .init(provider: "llm", model: "model", tokenCount: 25, status: GroundedResearchQueue.researchUsageStatus),
            triggeringTask: .init(
                classifierTypeID: "type",
                platformID: "youtube", entryID: "v", creatorID: "c",
                subjects: [ResearchSubject(kind: .term, subject: "HermitCraft")!]
            )
        )
        await fulfillment(of: [callback], timeout: 1)
        let saved = coordinator.snapshot().workspaceCatalog
        XCTAssertEqual(saved.videoClassification(
            classifierTypeID: "type", platformID: "youtube", entryID: "v"
        )?.source, .modelKnowledge)
        XCTAssertEqual(saved.tokenUsage.first?.tokenCount, 25)
    }

    func testCorrectionsAreAuthoritativeAndRetrievedPerVideoNotDistilledIntoHouseRules() async throws {
        let (coordinator, root) = try makeCoordinatorWithYouTubeType()
        defer { try? FileManager.default.removeItem(at: root) }
        var catalog = coordinator.snapshot().workspaceCatalog
        let datasetIndex = try XCTUnwrap(catalog.datasets.firstIndex(where: {
            $0.id == catalog.bindings.first(where: { $0.id == "youtube" })?.datasetID
        }))
        let typeIndex = try XCTUnwrap(catalog.classifierTypes.firstIndex(where: { $0.id == "type" }))
        catalog.classifierTypes[typeIndex].localModelOverrides = .init(houseRules: "Manual type rule.")
        let correctionCount = 5
        for index in 0..<correctionCount {
            _ = catalog.datasets[datasetIndex].upsertCollectedEntry(.init(
                id: "row-\(index)", platformID: "youtube", entryID: "v\(index)",
                creatorID: "youtube:handle:@creator", creatorName: "Creator",
                entryType: "video", title: "Games episode \(index)"
            ))
        }
        try coordinator.updateWorkspaceCatalog(catalog)
        coordinator.setClassificationOptions(maximumTags: 3, houseRules: "Global manual rule.")

        // Submitting corrections NEVER mutates the type's house rules — the manual
        // rule stays exactly as authored, at every step (no distilled block).
        for index in 0..<correctionCount {
            let projection = try coordinator.submitCorrection(
                classifierTypeID: "type", platformID: "youtube", entryID: "v\(index)",
                correctTagIDs: ["g"], note: "Keep games together."
            )
            XCTAssertEqual(projection.tags.map(\.id), ["g"])
            XCTAssertEqual(
                coordinator.snapshot().workspaceCatalog.classifierTypes[typeIndex]
                    .localModelOverrides?.houseRules,
                "Manual type rule.",
                "corrections must not auto-write the house-rules block"
            )
        }

        let saved = coordinator.snapshot().workspaceCatalog
        let rules = saved.classifierTypes[typeIndex].localModelOverrides?.houseRules
        XCTAssertEqual(rules, "Manual type rule.", "corrections never write into the house rules")
        XCTAssertEqual(saved.videoClassification(
            classifierTypeID: "type", platformID: "youtube", entryID: "v\(correctionCount - 1)"
        )?.source, .humanCorrected)

        let recorder = CoordinatorRequestRecorder()
        coordinator.setOnDeviceLLM(CoordinatorRecordingLLM(recorder: recorder))

        // A corrected row is authoritative: re-classifying it never hits the model.
        let correctedProjection = try await coordinator.classifyVideo(
            platformID: "youtube", entryID: "v\(correctionCount - 1)",
            creatorID: "youtube:handle:@creator", title: "Games episode"
        )
        XCTAssertEqual(correctedProjection.tags.map(\.id), ["g"])
        XCTAssertTrue(recorder.requests.isEmpty, "live and research refreshes preserve human-corrected rows")

        // Classifying a FRESH, related video (same creator) surfaces the user's
        // corrections as grounded per-video exemplars in the DYNAMIC suffix, while
        // the manual type house rule stays in the cached static prefix (it
        // intentionally overrides the global rule), and no distilled "Learned
        // preferences" block exists anywhere.
        _ = try await coordinator.classifyVideo(
            platformID: "youtube", entryID: "fresh",
            creatorID: "youtube:handle:@creator", title: "Games episode preview"
        )
        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertTrue(request.staticPrefix.contains("Manual type rule."), "manual house rule reaches the cached prefix")
        XCTAssertFalse(request.staticPrefix.contains("Learned preferences"))
        XCTAssertFalse(request.dynamicSuffix.contains("Learned preferences"))
        XCTAssertTrue(request.dynamicSuffix.contains("past corrections"), "grounded exemplars present per video")
        XCTAssertTrue(request.dynamicSuffix.contains("Games episode"), "the real corrected titles are the exemplars")
    }

    /// Research is driven by the model's own uncertainty; a human correction is
    /// authoritative, so it must never start a second decode or enqueue research
    /// (the former `correctionsOnly`/`all` trigger modes are gone) — even with the
    /// most permissive urgency floor.
    func testCorrectionNeverSchedulesResearch() async throws {
        let (coordinator, root) = try makeCoordinatorWithYouTubeType()
        defer { try? FileManager.default.removeItem(at: root) }
        var catalog = coordinator.snapshot().workspaceCatalog
        let datasetIndex = try XCTUnwrap(catalog.datasets.firstIndex(where: {
            $0.id == catalog.bindings.first(where: { $0.id == "youtube" })?.datasetID
        }))
        _ = catalog.datasets[datasetIndex].upsertCollectedEntry(.init(
            id: "row", platformID: "youtube", entryID: "v", creatorID: "youtube:handle:@creator",
            creatorName: "Creator", entryType: "video", title: "HermitCraft episode"
        ))
        try coordinator.updateWorkspaceCatalog(catalog)
        try coordinator.updateSettings(.init(research: .init(
            enabled: true,
            urgencyFloor: 1
        )))
        let queue = GroundedResearchQueue(
            configurationProvider: { _ in nil },
            snapshotProvider: { _ in .init() },
            mutationWriter: { _ in },
            researcher: { _, _ in throw GroundedResearchError.invalidConfiguration }
        )
        coordinator.setGroundedResearchQueue(queue)
        let probe = SubjectExtractionProbe()
        coordinator.setOnDeviceLLM(DecliningSubjectLLM(probe: probe))

        _ = try coordinator.submitCorrection(
            classifierTypeID: "type", platformID: "youtube", entryID: "v", correctTagIDs: ["g"]
        )
        for _ in 0..<50 { await Task.yield() }
        try? await Task<Never, Never>.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(probe.count, 0)
        let pending = await queue.pendingCount
        XCTAssertEqual(pending, 0)
    }

    /// End-to-end: a fake, unrecognized title is declined by the model, which
    /// triggers grounded research — and only the *sanitized* subjects (the
    /// extracted term and the @handle) ever reach the research queue. The raw
    /// title text and the raw `youtube:handle:` creator ID never leave.
    func testFakeDecliningTitleTriggersResearchAndOnlySanitizedSubjectsLeave() async throws {
        let (coordinator, root) = try makeCoordinatorWithYouTubeType()
        defer { try? FileManager.default.removeItem(at: root) }
        try coordinator.updateSettings(.init(research: .init(enabled: true)))
        let recorder = ResearchSubjectRecorder()
        let queue = GroundedResearchQueue(
            configurationProvider: { _ in
                .init(
                    providers: .init(
                        llmProfile: .init(id: "llm", type: .gemini, credential: "k"),
                        llmCredential: .init(values: [.apiKey: "k"]),
                        llmModelIdentifier: "gemini-2.0-flash"
                    ),
                    requestsPerMinute: 600,
                    dailyTokenLimit: 1_000_000
                )
            },
            snapshotProvider: { _ in .init() },
            mutationWriter: { _ in },
            researcher: { subject, _ in
                recorder.append(subject)
                return .init(
                    knowledge: .init(kind: subject.kind, subject: subject.subject, meaning: "meaning"),
                    chargedTokenCount: 1
                )
            }
        )
        coordinator.setGroundedResearchQueue(queue)
        // Declines every title, then extracts "HermitCraft" as the subject.
        coordinator.setOnDeviceLLM(ImmediateSubjectLLM(probe: ImmediateSubjectProbe()))

        let projection = try await coordinator.classifyVideo(
            platformID: "youtube", entryID: "youtube:video:fake",
            creatorID: "youtube:handle:@creator",
            title: "Totally unrecognized nonsense zzzqqq"
        )
        XCTAssertTrue(projection.tags.isEmpty, "an unrecognized title should be declined by the model")

        // The second decode is fire-and-forget: wait for it to extract, enqueue,
        // and drain the TERM subject. Author research is now accumulation-gated
        // (§8) — a single declining video does not research the creator — so only
        // the extracted term leaves here.
        for _ in 0..<200 where recorder.subjects.isEmpty {
            try? await Task<Never, Never>.sleep(nanoseconds: 2_000_000)
        }
        await queue.waitUntilIdle()
        let leaked = recorder.subjects.map(\.subject)
        XCTAssertTrue(leaked.contains("HermitCraft"), "the extracted term subject should trigger research")
        XCTAssertFalse(leaked.contains("@creator"), "a single video must not trigger author research (accumulation-gated)")
        for subject in leaked {
            XCTAssertFalse(subject.lowercased().contains("nonsense"), "raw title text must never leave the device")
            XCTAssertFalse(subject.contains("youtube:"), "raw creator/channel IDs must never leave the device")
        }
    }

    /// Decode 2 wiring: when the engine supports `researchNeeds`, its copied terms
    /// (over the SAME classification prompt) are what get researched — the legacy
    /// single-subject decode is not consulted. When Decode 2 finds nothing, the
    /// legacy decode is the fallback.
    func testDecodeTwoTermsAreResearchedOverTheClassificationPrompt() async throws {
        for (terms, expected, expectLegacy) in [
            (["HermitCraft", "Mumbo Jumbo"], Set(["HermitCraft", "Mumbo Jumbo"]), false),
            ([String](), Set(["LegacySubject"]), true),
        ] {
            let (coordinator, root) = try makeCoordinatorWithYouTubeType()
            defer { try? FileManager.default.removeItem(at: root) }
            try coordinator.updateSettings(.init(research: .init(enabled: true)))
            let recorder = ResearchSubjectRecorder()
            let queue = GroundedResearchQueue(
                configurationProvider: { _ in
                    .init(
                        providers: .init(
                            llmProfile: .init(id: "llm", type: .gemini, credential: "k"),
                            llmCredential: .init(values: [.apiKey: "k"]),
                            llmModelIdentifier: "gemini-2.0-flash"
                        ),
                        requestsPerMinute: 6_000,
                        dailyTokenLimit: 1_000_000
                    )
                },
                snapshotProvider: { _ in .init() },
                mutationWriter: { _ in },
                researcher: { subject, _ in
                    recorder.append(subject)
                    return .init(knowledge: .init(kind: subject.kind, subject: subject.subject, meaning: "m"), chargedTokenCount: 1)
                },
                sleeper: { _ in }
            )
            coordinator.setGroundedResearchQueue(queue)
            let probe = NeedsRequestProbe()
            coordinator.setOnDeviceLLM(NeedsExtractingLLM(probe: probe, terms: terms))

            _ = try await coordinator.classifyVideo(
                platformID: "youtube", entryID: "youtube:video:needs",
                creatorID: "youtube:handle:@creator", title: "HermitCraft finale with Mumbo Jumbo"
            )
            for _ in 0..<300 where recorder.subjects.count < expected.count {
                try? await Task<Never, Never>.sleep(nanoseconds: 2_000_000)
            }
            await queue.waitUntilIdle()

            XCTAssertEqual(Set(recorder.subjects.map(\.subject)), expected)
            XCTAssertEqual(probe.requests.count, 1)
            XCTAssertTrue(probe.requests[0].dynamicSuffix.contains("HermitCraft finale with Mumbo Jumbo"),
                          "Decode 2 must run over the classification prompt (KV-prefix reuse)")
            XCTAssertTrue(probe.requests[0].dynamicSuffix.hasSuffix("{\"tags\":[{\"name\":\""))
            XCTAssertEqual(probe.legacyCount > 0, expectLegacy)
        }
    }

    /// LATENCY-REFINEMENT Phase 1: a screenful reaches the engine as ONE batch (not
    /// N serial decodes), results come back keyed per video, a human-corrected
    /// video is never re-decoded, and a single video still uses the plain path.
    func testClassifyVideosSendsOneBatchAndKeysResultsPerVideo() async throws {
        let (coordinator, root) = try makeCoordinatorWithYouTubeType()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = BatchCallProbe()
        coordinator.setOnDeviceLLM(BatchingLLM(probe: probe))

        let projections = try await coordinator.classifyVideos(platformID: "youtube", items: [
            .init(title: "Best games of the year", entryID: "a", creatorID: "youtube:handle:@one"),
            .init(title: "A quiet walk", entryID: "b", creatorID: "youtube:handle:@two"),
            .init(title: "More GAMES news", entryID: "c", creatorID: "youtube:handle:@one"),
        ])
        XCTAssertEqual(probe.batchSizes, [3], "three videos → one batched engine call")
        XCTAssertEqual(probe.singles, 0)
        XCTAssertEqual(projections["a"]?.tags.map(\.id), ["g"])
        XCTAssertEqual(projections["b"]?.tags.map(\.id) ?? ["?"], [])
        XCTAssertEqual(projections["c"]?.tags.map(\.id), ["g"])
        // Persisted once for all three.
        XCTAssertEqual(coordinator.snapshot().workspaceCatalog.videoClassifications.count, 3)

        // A single video is a batch of one → the plain decode, no batch call.
        _ = try await coordinator.classifyVideo(platformID: "youtube", entryID: "d", creatorID: "youtube:handle:@two", title: "solo games")
        XCTAssertEqual(probe.batchSizes, [3])
        XCTAssertEqual(probe.singles, 1)
    }

    /// The contrast case: a title the model classifies confidently is not a
    /// decline, so under the default declineOnly policy it triggers no research.
    func testConfidentlyTaggedTitleDoesNotTriggerResearch() async throws {
        let (coordinator, root) = try makeCoordinatorWithYouTubeType()
        defer { try? FileManager.default.removeItem(at: root) }
        try coordinator.updateSettings(.init(research: .init(enabled: true)))
        let recorder = ResearchSubjectRecorder()
        let queue = GroundedResearchQueue(
            configurationProvider: { _ in
                .init(
                    providers: .init(
                        llmProfile: .init(id: "llm", type: .gemini, credential: "k"),
                        llmCredential: .init(values: [.apiKey: "k"]),
                        llmModelIdentifier: "gemini-2.0-flash"
                    ),
                    requestsPerMinute: 600,
                    dailyTokenLimit: 1_000_000
                )
            },
            snapshotProvider: { _ in .init() },
            mutationWriter: { _ in },
            researcher: { subject, _ in
                recorder.append(subject)
                return .init(
                    knowledge: .init(kind: subject.kind, subject: subject.subject, meaning: "m"),
                    chargedTokenCount: 1
                )
            }
        )
        coordinator.setGroundedResearchQueue(queue)
        // Default stub selects allowed tag names present in the title ("Games").

        let projection = try await coordinator.classifyVideo(
            platformID: "youtube", entryID: "youtube:video:games",
            creatorID: "c1", title: "A great Games montage"
        )
        XCTAssertEqual(projection.tags.map(\.id), ["g"], "a clear title should classify, not decline")

        for _ in 0..<50 { await Task.yield() }
        await queue.waitUntilIdle()
        XCTAssertTrue(recorder.subjects.isEmpty, "a confident classification must not trigger research")
    }

    func testEditAndDeleteKnowledgeEntryMutateTheCorrectMap() throws {
        let (coordinator, root) = try makeCoordinatorWithYouTubeType()
        defer { try? FileManager.default.removeItem(at: root) }
        var catalog = coordinator.snapshot().workspaceCatalog
        catalog.upsertKnowledgeEntry(KnowledgeEntry(kind: .creator, subject: "c1", meaning: "old creator desc"))
        catalog.upsertKnowledgeEntry(KnowledgeEntry(kind: .term, subject: "HermitCraft", meaning: "smp"))
        try coordinator.updateWorkspaceCatalog(catalog)

        // Editing a creator description keeps the id/kind and updates the text.
        XCTAssertTrue(try coordinator.updateKnowledgeEntryMeaning(id: "creator:c1", meaning: "new creator desc"))
        XCTAssertEqual(
            coordinator.snapshot().workspaceCatalog.creatorKnowledgeEntry(for: "c1")?.meaning,
            "new creator desc"
        )
        // Editing an unknown id is a no-op.
        XCTAssertFalse(try coordinator.updateKnowledgeEntryMeaning(id: "term:missing", meaning: "x"))

        // Deleting the term forgets it; the creator is untouched.
        try coordinator.deleteKnowledgeEntry(id: "term:hermitcraft")
        let afterTerm = coordinator.snapshot().workspaceCatalog
        XCTAssertTrue(afterTerm.knowledgeEntries.isEmpty)
        XCTAssertEqual(afterTerm.creatorKnowledge.count, 1)

        // Deleting the creator forgets it (allowing a fresh re-research).
        try coordinator.deleteKnowledgeEntry(id: "creator:c1")
        XCTAssertTrue(coordinator.snapshot().workspaceCatalog.creatorKnowledge.isEmpty)
    }

    func testResearchBackfillSweepsPersistedLowConfidenceRowsWithinBound() async throws {
        let (coordinator, root) = try makeCoordinatorWithYouTubeType()
        defer { try? FileManager.default.removeItem(at: root) }
        var catalog = coordinator.snapshot().workspaceCatalog
        let datasetIndex = try XCTUnwrap(catalog.datasets.firstIndex(where: {
            $0.id == catalog.bindings.first(where: { $0.id == "youtube" })?.datasetID
        }))
        for index in 0..<6 {
            _ = catalog.datasets[datasetIndex].upsertCollectedEntry(.init(
                id: "row-\(index)", platformID: "youtube", entryID: "v\(index)",
                creatorID: "youtube:handle:@creator", creatorName: "Creator",
                entryType: "video", title: "HermitCraft \(index)"
            ))
            catalog.upsertVideoClassification(.init(
                classifierTypeID: "type", platformID: "youtube", entryID: "v\(index)",
                creatorID: "youtube:handle:@creator", treeID: "t", treeRevision: 1,
                tags: [.init(tagID: "g", confidence: index == 5 ? 5 : 2)],
                source: .model, modelVersion: "old", updatedAtMilliseconds: Int64(index)
            ))
        }
        try coordinator.updateWorkspaceCatalog(catalog)
        try coordinator.updateSettings(.init(research: .init(
            enabled: true,
            urgencyFloor: 4   // confidence-2 rows are urgency 4
        )))
        let queue = GroundedResearchQueue(
            configurationProvider: { _ in nil }, snapshotProvider: { _ in .init() },
            mutationWriter: { _ in },
            researcher: { _, _ in throw GroundedResearchError.invalidConfiguration }
        )
        coordinator.setGroundedResearchQueue(queue)
        let probe = ImmediateSubjectProbe()
        coordinator.setOnDeviceLLM(ImmediateSubjectLLM(probe: probe))

        coordinator.startResearchBackfill(limit: 3)
        for _ in 0..<100 where probe.count < 3 {
            try? await Task<Never, Never>.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(probe.count, 3)
        await queue.waitUntilIdle()
    }

    func testStaleClassificationsAreNotServedFromCache() {
        func row(_ source: VideoClassificationSource, _ modelVersion: String) -> VideoClassification {
            VideoClassification(
                classifierTypeID: "t", platformID: "youtube", entryID: "youtube:video:v",
                creatorID: "c", treeID: "tree", treeRevision: 1,
                tags: [], source: source, modelVersion: modelVersion
            )
        }
        let type = ClassifierTypeAsset(
            id: "t", name: "YT", treeID: "tree", treeRevision: 1,
            datasetID: "d", datasetRevision: 1, applicablePlatformID: "youtube"
        )
        let settings = LocalLLMSettings(modelFileName: "qwen2.5-7b.gguf")
        let current = LocalClassifierCoordinator.isClassificationCurrent

        // Current model (with and without the "+<prompt>" suffix) → served.
        XCTAssertTrue(current(row(.model, "llamacpp/qwen2.5-7b.gguf+prompt-3"), type, settings))
        XCTAssertTrue(current(row(.model, "llamacpp/qwen2.5-7b.gguf"), type, settings))
        // Stub-era and a previously-selected model → stale.
        XCTAssertFalse(current(row(.model, "stub/v1"), type, settings))
        XCTAssertFalse(current(row(.model, "llamacpp/llama-3.2-3b.gguf+prompt-3"), type, settings))
        // A human correction is authoritative regardless of its model version.
        XCTAssertTrue(current(row(.humanCorrected, "stub/v1"), type, settings))
        // A per-type model overrides the global default.
        var typeWithModel = type
        typeWithModel.modelFileName = "gemma-2b.gguf"
        XCTAssertTrue(current(row(.model, "llamacpp/gemma-2b.gguf+p"), typeWithModel, settings))
        XCTAssertFalse(current(row(.model, "llamacpp/qwen2.5-7b.gguf+p"), typeWithModel, settings))
        // No real model configured → serve whatever exists (cannot reclassify).
        XCTAssertTrue(current(row(.model, "stub/v1"), type, LocalLLMSettings(modelFileName: nil)))
    }
}
