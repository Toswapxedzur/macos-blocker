import Foundation
import XCTest
import VaultClassifierBridge
@testable import VaultClassifierCore
@testable import VaultClassifierLLM
@testable import VaultClassifierApp

private actor ShutdownGate {
    var entered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func hold() async {
        entered = true
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilEntered() async { while !entered { await Task.yield() } }
    func release() { released = true; continuation?.resume(); continuation = nil }
}
private final class ShutdownEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    func add(_ value: String) { lock.withLock { events.append(value) } }
    var values: [String] { lock.withLock { events } }
}
private actor ShutdownResultLLM: OnDeviceBatchLLM {
    nonisolated let modelVersion = "llamacpp/" + SpeedQualityDial.balanced.ggufFileName
    let gate: ShutdownGate?
    init(gate: ShutdownGate? = nil) { self.gate = gate }
    func classify(_ request: LLMClassificationRequest) async throws -> LLMClassificationResult {
        await gate?.hold()
        return .init(tags: [.init(name: "Games", confidence: 5)])
    }
    func classifyBatch(_ requests: [LLMClassificationRequest]) async throws -> [LLMClassificationResult] {
        await gate?.hold()
        return requests.map { _ in .init(tags: [.init(name: "Games", confidence: 5)]) }
    }
}

@MainActor
final class ClassifierShutdownTests: XCTestCase {
    func testCoalescerDropsWaitingItemsAndWaitsForActiveRun() async {
        let active = ShutdownGate(), events = ShutdownEvents()
        let queue = ClassificationCoalescer<String>(chunkSize: 16, arrivalWindowNanoseconds: 0) { _, items in
            events.add(items.joined(separator: ","))
            await active.hold()
        }
        queue.onIdle = { events.add("idle") }
        queue.enqueue(platformID: "youtube", items: ["running"])
        await active.waitUntilEntered()
        queue.enqueue(platformID: "youtube", items: ["waiting"])
        let closing = Task { await queue.shutdown(); events.add("closed") }
        while queue.pendingCount != 0 { await Task.yield() }
        XCTAssertEqual(events.values, ["running"], "shutdown must wait for active work")
        queue.enqueue(platformID: "youtube", items: ["too-late"])
        await active.release()
        await closing.value
        await queue.shutdown()
        XCTAssertEqual(events.values, ["running", "closed"])
        XCTAssertEqual(queue.pendingCount, 0)
    }
    func testIdleCallbackCanEnqueueTheNextDrainWithoutLosingWakeup() async {
        let events = ShutdownEvents(), completed = ShutdownGate()
        let queue = ClassificationCoalescer<String>(chunkSize: 16, arrivalWindowNanoseconds: 0) { _, items in
            for item in items { events.add(item) }
        }
        var idleCount = 0
        queue.onIdle = {
            idleCount += 1
            if idleCount == 1 { queue.enqueue(platformID: "youtube", items: ["from-idle"]) }
            else { Task { await completed.release() } }
        }
        queue.enqueue(platformID: "youtube", items: ["first"])
        await completed.hold()
        XCTAssertEqual(events.values, ["first", "from-idle"])
        XCTAssertEqual(idleCount, 2)
        await queue.shutdown()
    }

    func testCancellationDuringArrivalWindowNeverStartsInference() async {
        let events = ShutdownEvents()
        let queue = ClassificationCoalescer<String>(chunkSize: 16, arrivalWindowNanoseconds: 60_000_000_000) { _, _ in events.add("ran") }
        queue.enqueue(platformID: "youtube", items: ["waiting"])
        await queue.shutdown()
        XCTAssertTrue(events.values.isEmpty)
        XCTAssertEqual(queue.pendingCount, 0)
    }
    func testEngineReleasesResourcesWhileExternalReferenceRemainsAndRejectsReuse() async throws {
        let events = ShutdownEvents()
        var engine: VaultLocalLLMEngine? = VaultLocalLLMEngine(testingResources: LLMEngineResources(shutdown: .init()) {
            events.add("context"); events.add("model")
        })
        let held = try XCTUnwrap(engine)
        await held.shutdown()
        await held.shutdown()
        engine = nil
        XCTAssertEqual(events.values, ["context", "model"], "deinit is not required for cleanup")
        do { _ = try await held.classifyBatch([]); XCTFail("closed engine must reject even empty inference") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(events.values, ["context", "model"], "retained references and repeated close cannot double-free")
    }
    func testRegistryClosesEvictedLiveEnginesAndDoesNotLoadAfterShutdown() async throws {
        let events = ShutdownEvents()
        let registry = LocalLLMEngineRegistry(loader: { path, _, signal in
            events.add("load:" + path)
            return VaultLocalLLMEngine(testingResources: LLMEngineResources(shutdown: signal) { events.add("free:" + path) })
        }, modelPath: { name, _ in name! })
        let a = try await registry.engine(forModel: "a.gguf", configuration: .init())
        let b = try await registry.engine(forModel: "b.gguf", configuration: .init())
        let c = try await registry.engine(forModel: "c.gguf", configuration: .init())
        let resident = await registry.residentModelFilesInLRUOrder()
        XCTAssertEqual(resident, ["b.gguf", "c.gguf"])
        XCTAssertFalse(events.values.contains("free:a.gguf"), "evicted engine is still held by its caller")
        await registry.shutdown()
        await registry.shutdown()
        XCTAssertEqual(Set(events.values.filter { $0.hasPrefix("free:") }), Set(["free:a.gguf", "free:b.gguf", "free:c.gguf"]))
        XCTAssertEqual(events.values.filter { $0.hasPrefix("free:") }.count, 3)
        do { _ = try await registry.engine(forModel: "late.gguf", configuration: .init()); XCTFail("closed registry must reject") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(events.values.contains("load:late.gguf"))
        withExtendedLifetime([a, b, c]) {}
    }
    func testRegistryJoinsLateLoadAndBothWaitersWithoutInstallingOrErrorStatus() async {
        let gate = ShutdownGate(), events = ShutdownEvents()
        let registry = LocalLLMEngineRegistry(loader: { path, _, signal in
            events.add("loading")
            await gate.hold() // Deliberately ignores cancellation like a current C call.
            return VaultLocalLLMEngine(testingResources: LLMEngineResources(shutdown: signal) { events.add("freed") })
        }, modelPath: { _, _ in "same.gguf" }, onStateChange: { _, status in events.add(status) })
        let first = Task { try await registry.engine(forModel: "same.gguf", configuration: .init()) }
        await gate.waitUntilEntered()
        let second = Task { try await registry.engine(forModel: "same.gguf", configuration: .init()) }
        while await registry.pendingModelLoadWaiterCount() < 2 { await Task.yield() }
        let closing = Task { await registry.shutdown(); events.add("closed") }
        await Task.yield()
        XCTAssertFalse(events.values.contains("closed"))
        await gate.release()
        await closing.value
        for waiter in [first, second] {
            do { _ = try await waiter.value; XCTFail("late load must not escape shutdown") }
            catch { XCTAssertTrue(error is CancellationError) }
        }
        let resident = await registry.residentModelFilesInLRUOrder()
        XCTAssertTrue(resident.isEmpty)
        XCTAssertEqual(events.values.filter { $0 == "freed" }.count, 1)
        XCTAssertFalse(events.values.contains("loaded"))
        XCTAssertFalse(events.values.contains("failed"))
        XCTAssertEqual(events.values.last, "closed")
    }

    func testCancelledInitiatingWaiterDoesNotHideOrPoisonSharedLoadedEngine() async throws {
        let loading = ShutdownGate(), retained = ShutdownGate(), events = ShutdownEvents()
        let registry = LocalLLMEngineRegistry(loader: { _, _, signal in
            events.add("load")
            await loading.hold()
            return VaultLocalLLMEngine(testingResources: LLMEngineResources(shutdown: signal) { events.add("free") })
        }, modelPath: { _, _ in "same.gguf" })
        let first = Task { try await registry.engine(forModel: "same.gguf", configuration: .init()) }
        await loading.waitUntilEntered()
        let second = Task {
            let engine = try await registry.engine(forModel: "same.gguf", configuration: .init())
            await retained.hold()
            return engine
        }
        while await registry.pendingModelLoadWaiterCount() < 2 { await Task.yield() }
        first.cancel()
        await loading.release()
        do { _ = try await first.value; XCTFail("initiating waiter was cancelled") }
        catch { XCTAssertTrue(error is CancellationError) }
        await retained.waitUntilEntered()
        await registry.shutdown()
        XCTAssertEqual(events.values, ["load", "free"], "secondary waiter still holds the shared engine")
        await retained.release()
        let engine = try await second.value
        await engine.shutdown()
        XCTAssertEqual(events.values, ["load", "free"])
    }

    func testShutdownPreservesCompletedResultsButRejectsActiveAndWaitingSaves() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("classifier-shutdown-\(UUID().uuidString)")
        defer { LocalStateFile.flushAllPendingWrites(); try? FileManager.default.removeItem(at: directory) }
        let model = try VaultClassifierViewModel(headlessVaultDirectory: directory)
        let coordinator = try XCTUnwrap(model.coordinator)
        var catalog = WorkspaceCatalog.starter()
        let tree = TagTreeAsset(id: "shutdown-tree", name: "Topics", nodes: [.init(id: "games", name: "Games")])
        catalog.trees.append(tree)
        let dataset = catalog.datasets[0]
        catalog.classifierTypes.append(.init(id: "shutdown-type", name: "YouTube", treeID: tree.id, treeRevision: tree.revision,
            datasetID: dataset.id, datasetRevision: dataset.revision, applicablePlatformIDs: ["youtube"]))
        try coordinator.updateWorkspaceCatalog(catalog)
        coordinator.setOnDeviceLLM(ShutdownResultLLM())
        _ = try await coordinator.classifyVideo(platformID: "youtube", entryID: "completed", creatorID: "creator", title: "Games")
        let completed = coordinator.snapshot().workspaceCatalog.videoClassifications
        XCTAssertEqual(completed.count, 1)
        let active = ShutdownGate()
        coordinator.setOnDeviceLLM(ShutdownResultLLM(gate: active))
        model.queueVideoClassification(platformID: "youtube", items: [.init(entryID: "active", creatorID: "creator", title: "Games")])
        await active.waitUntilEntered()
        model.queueVideoClassification(platformID: "youtube", items: [.init(entryID: "waiting", creatorID: "creator", title: "Games")])
        let closing = Task { await model.shutdown() }
        while !model.isShuttingDown { await Task.yield() }
        model.queueVideoClassification(platformID: "youtube", items: [.init(entryID: "late", creatorID: "creator", title: "Games")])
        await active.release()
        await closing.value
        XCTAssertEqual(coordinator.snapshot().workspaceCatalog.videoClassifications, completed)
        XCTAssertTrue(model.inFlightVideoClassifications.isEmpty)
        let reopened = try VaultClassifierViewModel(headlessVaultDirectory: directory)
        XCTAssertEqual(reopened.coordinator?.snapshot().workspaceCatalog.videoClassifications, completed)
    }
    func testResearchAdmissionClosesWhileModelWorkIsStillBlocked() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shutdown-both-queues-\(UUID().uuidString)")
        defer { LocalStateFile.flushAllPendingWrites(); try? FileManager.default.removeItem(at: directory) }
        let model = try VaultClassifierViewModel(headlessVaultDirectory: directory)
        let inference = ShutdownGate(), research = ShutdownGate()
        model.classificationCoalescer = ClassificationCoalescer(chunkSize: 16, arrivalWindowNanoseconds: 0) { _, _ in await inference.hold() }
        let queue = GroundedResearchQueue(configurationProvider: { _ in .init(providers: .init(
            llmProfile: .init(id: "llm", type: .ollama), llmCredential: .init(values: [:]), llmModelIdentifier: "fixture", maximumOutputTokens: 100),
            requestsPerMinute: 6000, dailyTokenLimit: 1000) }, snapshotProvider: { _ in .init() }, mutationWriter: { _ in XCTFail("cancelled research must not write") },
            researcher: { subject, _ in
                await research.hold()
                return .init(knowledge: .init(kind: subject.kind, subject: subject.subject, meaning: "late"), chargedTokenCount: 1)
            }, sleeper: { _ in })
        model.groundedResearchQueue = queue
        func item(_ name: String) -> ResearchTask { .init(classifierTypeID: "type", platformID: "youtube", entryID: "fixture", creatorID: "creator",
            subjects: [ResearchSubject(kind: .term, subject: name)!]) }
        _ = await queue.enqueue(item("active"))
        await research.waitUntilEntered()
        _ = await queue.enqueue(item("waiting"))
        model.classificationCoalescer.enqueue(platformID: "youtube", items: [.init(entryID: "active", creatorID: "creator", title: "Games")])
        await inference.waitUntilEntered()
        let closing = Task { await model.shutdown() }
        let deadline = Date().addingTimeInterval(2)
        while await queue.pendingCount != 0, Date() < deadline { await Task.yield() }
        let pending = await queue.pendingCount
        XCTAssertEqual(pending, 0, "research is stopped before the held native-like call returns")
        let accepted = await queue.enqueue(item("late"))
        XCTAssertFalse(accepted)
        await research.release()
        await inference.release()
        await closing.value
    }

    func testWorkerShutdownFlushesAndRefusesLaterRequests() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("worker-shutdown-\(UUID().uuidString)")
        defer { LocalStateFile.flushAllPendingWrites(); try? FileManager.default.removeItem(at: directory) }
        let service = try VaultClassifierWorkerService(testingDirectory: directory, emit: { _ in })
        await service.shutdown()
        await service.shutdown()
        do { _ = try await service.handle(operation: "snapshot", data: [:]); XCTFail("worker is closed") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
