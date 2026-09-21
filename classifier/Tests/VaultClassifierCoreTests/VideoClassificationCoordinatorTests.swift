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

/// Declines every title: the weakest possible signal, so research decisions are
/// exercised without any model.
private struct DecliningLLM: OnDeviceLLM {
    let modelVersion = "decline/v1"
    func classify(_ request: LLMClassificationRequest) async throws -> LLMClassificationResult { .init(tags: []) }
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

    func testEffectiveResearchSettingsInheritOverrideAndRespectMasterGate() {
        let global = ResearchSettings(
            enabled: true,
            llmProviderProfileID: "global-llm",
            llmModelIdentifier: "global-model",
            requestsPerMinute: 6,
            dailyTokenLimit: 10_000
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
            dailyTokenLimit: 20_000
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
        try coordinator.updateSettings(.init(research: .init(enabled: true)))
        let queue = GroundedResearchQueue(
            configurationProvider: { _ in nil },
            snapshotProvider: { _ in .init() },
            mutationWriter: { _ in },
            researcher: { _, _ in throw GroundedResearchError.invalidConfiguration }
        )
        coordinator.setGroundedResearchQueue(queue)
        coordinator.setOnDeviceLLM(DecliningLLM())

        _ = try coordinator.submitCorrection(
            classifierTypeID: "type", platformID: "youtube", entryID: "v", correctTagIDs: ["g"]
        )
        for _ in 0..<50 { await Task.yield() }
        try? await Task<Never, Never>.sleep(nanoseconds: 20_000_000)
        let pending = await queue.pendingCount
        XCTAssertEqual(pending, 0)
    }

    private func recordingQueue(
        _ recorder: ResearchSubjectRecorder,
        writer: @escaping GroundedResearchQueue.MutationWriter = { _ in }
    ) -> GroundedResearchQueue {
        GroundedResearchQueue(
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
            mutationWriter: writer,
            researcher: { subject, _ in
                recorder.append(subject)
                return .init(
                    knowledge: .init(kind: subject.kind, subject: subject.subject, meaning: "meaning"),
                    chargedTokenCount: 1
                )
            },
            sleeper: { _ in }
        )
    }

    /// The only AUTOMATIC research is the creator accumulator. A declined video
    /// sends nothing on its own — no term is ever picked from a title — and once the
    /// creator has been hard to classify often enough, only the sanitized @handle
    /// leaves: never title text, never the raw `youtube:handle:` id.
    func testDeclinedVideosSendNothingUntilTheCreatorThresholdThenOnlyTheHandle() async throws {
        let (coordinator, root) = try makeCoordinatorWithYouTubeType()
        defer { try? FileManager.default.removeItem(at: root) }
        try coordinator.updateSettings(.init(research: .init(
            enabled: true,
            authorThreshold: .init(score: 3, halfLifeDays: 14)
        )))
        let recorder = ResearchSubjectRecorder()
        let queue = recordingQueue(recorder)
        coordinator.setGroundedResearchQueue(queue)
        coordinator.setOnDeviceLLM(DecliningLLM())

        for index in 0..<2 {
            let projection = try await coordinator.classifyVideo(
                platformID: "youtube", entryID: "youtube:video:fake\(index)",
                creatorID: "youtube:handle:@creator", title: "HermitCraft nonsense zzzqqq \(index)"
            )
            XCTAssertTrue(projection.tags.isEmpty)
        }
        for _ in 0..<50 { await Task.yield() }
        await queue.waitUntilIdle()
        XCTAssertTrue(recorder.subjects.isEmpty, "below the creator threshold nothing may leave the device")

        _ = try await coordinator.classifyVideo(
            platformID: "youtube", entryID: "youtube:video:fake2",
            creatorID: "youtube:handle:@creator", title: "HermitCraft nonsense zzzqqq 2"
        )
        for _ in 0..<200 where recorder.subjects.isEmpty {
            try? await Task<Never, Never>.sleep(nanoseconds: 2_000_000)
        }
        await queue.waitUntilIdle()
        XCTAssertEqual(recorder.subjects.map(\.kind), [.creator])
        XCTAssertEqual(recorder.subjects.map(\.subject), ["@creator"])
    }

    /// Terms reach research only when the USER names one: it is looked up, stored,
    /// and then matches titles. Junk subjects and a research-off state are refused.
    func testOnlyAUserAddedTermIsLookedUp() async throws {
        let (coordinator, root) = try makeCoordinatorWithYouTubeType()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = ResearchSubjectRecorder()
        let queue = recordingQueue(recorder) { [coordinator] mutation in
            await coordinator.recordResearchMutation(mutation)
        }
        coordinator.setGroundedResearchQueue(queue)

        let whileOff = await coordinator.researchTerm("HermitCraft")
        XCTAssertFalse(whileOff, "research off: nothing may be queued")
        try coordinator.updateSettings(.init(research: .init(enabled: true)))
        let tooGeneric = await coordinator.researchTerm("ab")
        XCTAssertFalse(tooGeneric)

        let queued = await coordinator.researchTerm("  HermitCraft ")
        XCTAssertTrue(queued)
        for _ in 0..<200 where coordinator.snapshot().workspaceCatalog.knowledgeEntries.isEmpty {
            try? await Task<Never, Never>.sleep(nanoseconds: 2_000_000)
        }
        await queue.waitUntilIdle()
        XCTAssertEqual(recorder.subjects.map(\.subject), ["HermitCraft"])
        let stored = coordinator.snapshot().workspaceCatalog.knowledgeEntries
        XCTAssertEqual(stored.map(\.subject), ["HermitCraft"])
        XCTAssertTrue(stored[0].matches(title: "HermitCraft season finale"))
    }

    /// A term the user described themselves is stored as written, with no lookup.
    func testAUserWrittenTermIsStoredWithoutResearch() throws {
        let (coordinator, root) = try makeCoordinatorWithYouTubeType()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(try coordinator.addKnowledgeTerm(subject: " Lifesteal SMP ", meaning: " A Minecraft server. "))
        XCTAssertFalse(try coordinator.addKnowledgeTerm(subject: "ab", meaning: "too generic to match safely"))
        XCTAssertFalse(try coordinator.addKnowledgeTerm(subject: "JudeLow", meaning: "   "))
        let stored = coordinator.snapshot().workspaceCatalog.knowledgeEntries
        XCTAssertEqual(stored.map(\.subject), ["Lifesteal SMP"])
        XCTAssertEqual(stored.first?.meaning, "A Minecraft server.")
        XCTAssertEqual(stored.first?.kind, .term)
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
