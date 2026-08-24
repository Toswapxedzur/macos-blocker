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
                    confidenceThresholds: [0.1, 0.3, 0.6, 0.9]
                ), order: 0
            ),
            .init(
                id: "b", name: "B", treeID: treeB.id, treeRevision: treeB.revision,
                datasetID: dataset.id, datasetRevision: dataset.revision,
                applicablePlatformID: "youtube", order: 1
            ),
        ]
        try coordinator.updateWorkspaceCatalog(catalog)
        coordinator.setClassificationOptions(maximumTags: 3, houseRules: "Global rule.")
        let recorder = CoordinatorRequestRecorder()
        coordinator.setOnDeviceLLM(CoordinatorRecordingLLM(recorder: recorder))

        _ = try await coordinator.classifyVideo(
            platformID: "youtube", entryID: "v", creatorID: "c", title: "title"
        )

        XCTAssertEqual(recorder.requests.count, 2)
        XCTAssertTrue(recorder.requests[0].staticPrefix.contains("Type A rule."))
        XCTAssertFalse(recorder.requests[0].staticPrefix.contains("Global rule."))
        XCTAssertEqual(recorder.requests[0].allowDecline, false)
        XCTAssertEqual(recorder.requests[0].confidenceThresholds, [0.1, 0.3, 0.6, 0.9])
        XCTAssertTrue(recorder.requests[1].staticPrefix.contains("Global rule."))
        XCTAssertNil(recorder.requests[1].allowDecline)
        XCTAssertNil(recorder.requests[1].confidenceThresholds)
        XCTAssertEqual(recorder.requests.map(\.maximumTags), [3, 3], "maximumTags remains global")
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

    func testGranularResearchTriggerModesAndConfidenceLevel() {
        let decline = VideoClassification(
            classifierTypeID: "type", platformID: "youtube", entryID: "v", creatorID: "c",
            treeID: "tree", treeRevision: 1, tags: [], source: .model, modelVersion: "m"
        )
        var low = decline
        low.tags = [.init(tagID: "tag", confidence: 3)]
        var grounded = low
        grounded.source = .modelKnowledge

        XCTAssertTrue(LocalClassifierCoordinator.shouldTriggerResearch(
            for: decline,
            settings: .init(trigger: .declineOnly)
        ))
        XCTAssertFalse(LocalClassifierCoordinator.shouldTriggerResearch(
            for: low,
            settings: .init(trigger: .declineOnly, confidenceTriggerLevel: 3)
        ))
        XCTAssertTrue(LocalClassifierCoordinator.shouldTriggerResearch(
            for: low,
            settings: .init(trigger: .declineAndLowConfidence, confidenceTriggerLevel: 3)
        ))
        XCTAssertFalse(LocalClassifierCoordinator.shouldTriggerResearch(
            for: low,
            settings: .init(trigger: .declineAndLowConfidence, confidenceTriggerLevel: 2)
        ))
        XCTAssertFalse(LocalClassifierCoordinator.shouldTriggerResearch(
            for: decline,
            settings: .init(trigger: .correctionsOnly)
        ))
        XCTAssertFalse(LocalClassifierCoordinator.shouldTriggerResearch(
            for: grounded,
            settings: .init(trigger: .all, confidenceTriggerLevel: 5)
        ))
    }

    func testEffectiveResearchSettingsInheritOverrideAndRespectMasterGate() {
        let global = ResearchSettings(
            enabled: true,
            llmProviderProfileID: "global-llm",
            llmModelIdentifier: "global-model",
            webSearchProviderProfileID: "global-search",
            requestsPerMinute: 6,
            dailyTokenLimit: 10_000,
            maxSubjectsPerVideo: 3
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
            webSearchProviderProfileID: "type-search",
            requestsPerMinute: 15,
            dailyTokenLimit: 20_000,
            maxSubjectsPerVideo: 1
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

    func testCorrectionsAreAuthoritativeAndDistillOnlyAtBatchBoundary() async throws {
        let (coordinator, root) = try makeCoordinatorWithYouTubeType()
        defer { try? FileManager.default.removeItem(at: root) }
        var catalog = coordinator.snapshot().workspaceCatalog
        let datasetIndex = try XCTUnwrap(catalog.datasets.firstIndex(where: {
            $0.id == catalog.bindings.first(where: { $0.id == "youtube" })?.datasetID
        }))
        let typeIndex = try XCTUnwrap(catalog.classifierTypes.firstIndex(where: { $0.id == "type" }))
        catalog.classifierTypes[typeIndex].localModelOverrides = .init(houseRules: "Manual type rule.")
        for index in 0..<CorrectionDistiller.batchSize {
            _ = catalog.datasets[datasetIndex].upsertCollectedEntry(.init(
                id: "row-\(index)", platformID: "youtube", entryID: "v\(index)",
                creatorID: "youtube:handle:@creator", creatorName: "Creator",
                entryType: "video", title: "Games episode \(index)"
            ))
        }
        try coordinator.updateWorkspaceCatalog(catalog)
        coordinator.setClassificationOptions(maximumTags: 3, houseRules: "Global manual rule.")

        for index in 0..<(CorrectionDistiller.batchSize - 1) {
            let projection = try coordinator.submitCorrection(
                classifierTypeID: "type", platformID: "youtube", entryID: "v\(index)",
                correctTagIDs: ["g"], note: "Keep games together."
            )
            XCTAssertEqual(projection.tags.map(\.id), ["g"])
            XCTAssertEqual(
                coordinator.snapshot().workspaceCatalog.classifierTypes[typeIndex]
                    .localModelOverrides?.houseRules,
                "Manual type rule."
            )
        }
        _ = try coordinator.submitCorrection(
            classifierTypeID: "type", platformID: "youtube",
            entryID: "v\(CorrectionDistiller.batchSize - 1)", correctTagIDs: ["g"]
        )

        let saved = coordinator.snapshot().workspaceCatalog
        let rules = saved.classifierTypes[typeIndex].localModelOverrides?.houseRules
        XCTAssertTrue(rules?.contains("Manual type rule.") == true)
        XCTAssertTrue(CorrectionDistiller.containsLearnedPreferences(rules))
        XCTAssertEqual(CorrectionDistiller.distilledCorrectionCount(in: rules), CorrectionDistiller.batchSize)
        XCTAssertEqual(saved.videoClassification(
            classifierTypeID: "type", platformID: "youtube",
            entryID: "v\(CorrectionDistiller.batchSize - 1)"
        )?.source, .humanCorrected)

        let recorder = CoordinatorRequestRecorder()
        coordinator.setOnDeviceLLM(CoordinatorRecordingLLM(recorder: recorder))
        let correctedProjection = try await coordinator.classifyVideo(
            platformID: "youtube", entryID: "v\(CorrectionDistiller.batchSize - 1)",
            creatorID: "youtube:handle:@creator", title: "Games episode"
        )
        XCTAssertEqual(correctedProjection.tags.map(\.id), ["g"])
        XCTAssertTrue(recorder.requests.isEmpty, "live and research refreshes preserve human-corrected rows")

        _ = try await coordinator.classifyVideo(
            platformID: "youtube", entryID: "fresh", creatorID: "creator", title: "Fresh title"
        )
        XCTAssertTrue(recorder.requests[0].staticPrefix.contains("Global manual rule."))
        XCTAssertTrue(recorder.requests[0].staticPrefix.contains("Manual type rule."))
        XCTAssertTrue(recorder.requests[0].staticPrefix.contains("Learned preferences"))
    }

    func testCorrectionTriggersSanitizedSecondDecodeWhenConfigured() async throws {
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
            trigger: .correctionsOnly
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
        await probe.waitUntilStarted()
        XCTAssertEqual(probe.count, 1)
        probe.release()
        for _ in 0..<20 { await Task.yield() }
        await queue.waitUntilIdle()
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
            trigger: .declineAndLowConfidence
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
}
