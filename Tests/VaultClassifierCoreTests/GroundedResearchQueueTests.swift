import Foundation
import XCTest
@testable import VaultClassifierCore

private final class ResearchQueueHarness: @unchecked Sendable {
    private let lock = NSLock()
    private var storedSnapshot = GroundedResearchQueueSnapshot()
    private var storedMutations: [GroundedResearchQueueMutation] = []
    private var storedResearchCount = 0
    private var storedSleepIntervals: [TimeInterval] = []
    private var storedNow: Date

    init(now: Date) { storedNow = now }

    var snapshot: GroundedResearchQueueSnapshot {
        get { lock.withLock { storedSnapshot } }
        set { lock.withLock { storedSnapshot = newValue } }
    }
    var researchCount: Int { lock.withLock { storedResearchCount } }
    var mutationCount: Int { lock.withLock { storedMutations.count } }
    var sleepIntervals: [TimeInterval] { lock.withLock { storedSleepIntervals } }
    var now: Date { lock.withLock { storedNow } }

    func recordResearch() { lock.withLock { storedResearchCount += 1 } }
    func sleep(_ interval: TimeInterval) {
        lock.withLock {
            storedSleepIntervals.append(interval)
            storedNow = storedNow.addingTimeInterval(interval)
        }
    }
    func write(_ mutation: GroundedResearchQueueMutation) {
        lock.withLock {
            storedMutations.append(mutation)
            switch mutation {
            case .succeeded(_, let result, let usage):
                storedSnapshot.existingKnowledgeKeys.insert(result.knowledge.id)
                storedSnapshot.tokenUsage.append(usage)
            case .failed(_, let attempt):
                storedSnapshot.failedAttempts.removeAll {
                    $0.classifierTypeID == attempt.classifierTypeID &&
                        $0.subjectKey == attempt.subjectKey
                }
                storedSnapshot.failedAttempts.append(attempt)
            case .retryRequested(let task, let subjectKey):
                storedSnapshot.failedAttempts.removeAll {
                    $0.classifierTypeID == task.classifierTypeID && $0.subjectKey == subjectKey
                }
            }
        }
    }
    var mutations: [GroundedResearchQueueMutation] { lock.withLock { storedMutations } }
}

private final class FirstResearchGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var didStart = false
    private var didRelease = false

    func run(_ subject: ResearchSubject) async -> GroundedResearchResult {
        let shouldWait = lock.withLock { () -> Bool in
            guard !didStart else { return false }
            didStart = true
            return !didRelease
        }
        if shouldWait {
            await withCheckedContinuation { continuation in
                let resumeNow = lock.withLock { () -> Bool in
                    if didRelease { return true }
                    self.continuation = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }
        return .init(
            knowledge: .init(kind: subject.kind, subject: subject.subject, meaning: "meaning"),
            chargedTokenCount: 1
        )
    }

    func waitUntilStarted() async {
        while !lock.withLock({ didStart }) { await Task.yield() }
    }

    func release() {
        let pending = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            didRelease = true
            defer { continuation = nil }
            return continuation
        }
        pending?.resume()
    }
}

private actor OrderRecorder {
    private var items: [String] = []
    func record(_ subject: String) { items.append(subject) }
    var all: [String] { items }
}

final class GroundedResearchQueueTests: XCTestCase {

    /// RESEARCH-REDESIGN §7: the drain must pull the highest-urgency pending
    /// subject first, not FIFO. Block the first (low-urgency) subject in-flight,
    /// enqueue higher-urgency ones behind it, release, and assert the remainder
    /// drained high→low regardless of insertion order.
    func testDrainsHighestUrgencyFirst() async {
        let harness = ResearchQueueHarness(now: Date(timeIntervalSince1970: 1_000_000))
        let order = OrderRecorder()
        let gate = FirstResearchGate()
        let queue = GroundedResearchQueue(
            configurationProvider: { _ in .init(providers: self.providers(), requestsPerMinute: 6_000, dailyTokenLimit: 1_000_000) },
            snapshotProvider: { _ in harness.snapshot },
            mutationWriter: { harness.write($0) },
            researcher: { subject, _ in
                await order.record(subject.subject)
                return await gate.run(subject)   // only the first call blocks
            },
            now: { harness.now },
            sleeper: { _ in }
        )
        _ = await queue.enqueue(task("low", entryID: "1", urgency: 1))
        await gate.waitUntilStarted()            // "low" is now in-flight, blocked
        _ = await queue.enqueue(task("mid", entryID: "2", urgency: 3))
        _ = await queue.enqueue(task("high", entryID: "3", urgency: 5))
        _ = await queue.enqueue(task("low2", entryID: "4", urgency: 2))
        gate.release()
        await queue.waitUntilIdle()
        let recorded = await order.all
        // "low" ran first (it was alone when picked); the rest drain by urgency.
        XCTAssertEqual(recorded, ["low", "high", "mid", "low2"])
    }

    private func providers(outputTokens: Int = 100) -> GroundedResearchProviderConfiguration {
        .init(
            llmProfile: .init(id: "llm", type: .ollama),
            llmCredential: .init(values: [:]),
            llmModelIdentifier: "model",
            maximumOutputTokens: outputTokens
        )
    }

    private func task(_ name: String, entryID: String = "entry", typeID: String = "type", urgency: Int = ResearchTask.defaultUrgency) -> ResearchTask {
        .init(
            classifierTypeID: typeID,
            platformID: "youtube",
            entryID: entryID,
            creatorID: "creator",
            subjects: [ResearchSubject(kind: .term, subject: name)!],
            urgency: urgency
        )
    }

    func testQueueDeduplicatesAndPersistsSuccessfulUsage() async {
        let harness = ResearchQueueHarness(now: Date(timeIntervalSince1970: 1_700_000_000))
        let queue = GroundedResearchQueue(
            configurationProvider: { _ in .init(providers: self.providers(), requestsPerMinute: 120, dailyTokenLimit: 1_000) },
            snapshotProvider: { _ in harness.snapshot },
            mutationWriter: { harness.write($0) },
            researcher: { subject, _ in
                harness.recordResearch()
                return .init(
                    knowledge: .init(kind: subject.kind, subject: subject.subject, meaning: "meaning"),
                    chargedTokenCount: 40
                )
            },
            now: { harness.now },
            sleeper: { harness.sleep($0) }
        )

        let first = await queue.enqueue(task("HermitCraft"))
        let duplicate = await queue.enqueue(task("HermitCraft"))
        await queue.waitUntilIdle()

        XCTAssertTrue(first)
        XCTAssertFalse(duplicate)
        XCTAssertEqual(harness.researchCount, 1)
        XCTAssertEqual(harness.mutationCount, 1)
        XCTAssertEqual(harness.snapshot.tokenUsage.first?.status, GroundedResearchQueue.researchUsageStatus)
        XCTAssertEqual(harness.snapshot.tokenUsage.first?.tokenCount, 40)
    }

    func testPersistedFailureCooldownSurvivesANewQueue() async {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let harness = ResearchQueueHarness(now: now)
        harness.snapshot = .init(failedAttempts: [
            .init(
                classifierTypeID: "type",
                subjectKey: "term:hermitcraft",
                lastAttemptAtMilliseconds: Int64(now.timeIntervalSince1970 * 1_000),
                retryAfterMilliseconds: Int64(now.addingTimeInterval(3_600).timeIntervalSince1970 * 1_000)
            )
        ])
        let queue = GroundedResearchQueue(
            configurationProvider: { _ in .init(providers: self.providers(), requestsPerMinute: 6, dailyTokenLimit: 1_000) },
            snapshotProvider: { _ in harness.snapshot },
            mutationWriter: { harness.write($0) },
            researcher: { _, _ in
                harness.recordResearch()
                throw GroundedResearchError.emptyMeaning
            },
            now: { harness.now },
            sleeper: { _ in }
        )
        let accepted = await queue.enqueue(task("HermitCraft"))
        XCTAssertTrue(accepted)
        await queue.waitUntilIdle()
        XCTAssertEqual(harness.researchCount, 0)
    }

    func testDailyBudgetBlocksDrainAndRPMSpacesStarts() async {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let harness = ResearchQueueHarness(now: now)
        harness.snapshot = .init(tokenUsage: [
            .init(provider: "llm", model: "model", tokenCount: 100, status: GroundedResearchQueue.researchUsageStatus, classifierTypeID: "type", createdAtMilliseconds: Int64(now.timeIntervalSince1970 * 1_000))
        ])
        let blocked = GroundedResearchQueue(
            configurationProvider: { _ in .init(providers: self.providers(), requestsPerMinute: 6, dailyTokenLimit: 100) },
            snapshotProvider: { _ in harness.snapshot },
            mutationWriter: { harness.write($0) },
            researcher: { _, _ in
                harness.recordResearch()
                throw GroundedResearchError.emptyMeaning
            },
            now: { harness.now },
            sleeper: { harness.sleep($0) }
        )
        let blockedAccepted = await blocked.enqueue(task("One"))
        XCTAssertTrue(blockedAccepted)
        await blocked.waitUntilIdle()
        XCTAssertEqual(harness.researchCount, 0)

        harness.snapshot = .init()
        let spaced = GroundedResearchQueue(
            configurationProvider: { _ in .init(providers: self.providers(), requestsPerMinute: 6, dailyTokenLimit: 1_000) },
            snapshotProvider: { _ in harness.snapshot },
            mutationWriter: { harness.write($0) },
            researcher: { subject, _ in
                harness.recordResearch()
                return .init(knowledge: .init(kind: subject.kind, subject: subject.subject, meaning: "meaning"), chargedTokenCount: 1)
            },
            now: { harness.now },
            sleeper: { harness.sleep($0) }
        )
        let firstAccepted = await spaced.enqueue(task("One", entryID: "1"))
        let secondAccepted = await spaced.enqueue(task("Two", entryID: "2"))
        XCTAssertTrue(firstAccepted)
        XCTAssertTrue(secondAccepted)
        await spaced.waitUntilIdle()
        XCTAssertEqual(harness.researchCount, 2)
        XCTAssertEqual(harness.sleepIntervals, [10])
    }

    func testDailyBudgetCapsRequestedOutputAndPersistsFullProviderCharge() async {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let harness = ResearchQueueHarness(now: now)
        harness.snapshot = .init(tokenUsage: [
            .init(provider: "llm", model: "model", tokenCount: 90, status: GroundedResearchQueue.researchUsageStatus, classifierTypeID: "type", createdAtMilliseconds: Int64(now.timeIntervalSince1970 * 1_000))
        ])
        let queue = GroundedResearchQueue(
            configurationProvider: { _ in .init(providers: self.providers(outputTokens: 100), requestsPerMinute: 120, dailyTokenLimit: 100) },
            snapshotProvider: { _ in harness.snapshot },
            mutationWriter: { harness.write($0) },
            researcher: { subject, configuration in
                XCTAssertEqual(configuration.maximumOutputTokens, 10)
                harness.recordResearch()
                return .init(
                    knowledge: .init(kind: subject.kind, subject: subject.subject, meaning: "meaning"),
                    chargedTokenCount: 25
                )
            },
            now: { harness.now },
            sleeper: { harness.sleep($0) }
        )

        let firstAccepted = await queue.enqueue(task("One", entryID: "1"))
        let secondAccepted = await queue.enqueue(task("Two", entryID: "2"))
        XCTAssertTrue(firstAccepted)
        XCTAssertTrue(secondAccepted)
        await queue.waitUntilIdle()

        XCTAssertEqual(harness.researchCount, 1)
        XCTAssertEqual(harness.snapshot.tokenUsage.last?.tokenCount, 25)
    }

    func testDailyBudgetAndFailureCooldownAreIndependentPerClassifierType() async {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let milliseconds = Int64(now.timeIntervalSince1970 * 1_000)
        let harness = ResearchQueueHarness(now: now)
        harness.snapshot = .init(
            failedAttempts: [
                .init(
                    classifierTypeID: "type-a",
                    subjectKey: "term:shared",
                    lastAttemptAtMilliseconds: milliseconds,
                    retryAfterMilliseconds: milliseconds + 3_600_000
                ),
            ],
            tokenUsage: [
                .init(
                    provider: "llm", model: "model", tokenCount: 100,
                    status: GroundedResearchQueue.researchUsageStatus,
                    classifierTypeID: "type-a", createdAtMilliseconds: milliseconds
                ),
            ]
        )
        let queue = GroundedResearchQueue(
            configurationProvider: { _ in
                .init(providers: self.providers(), requestsPerMinute: 120, dailyTokenLimit: 100)
            },
            snapshotProvider: { _ in harness.snapshot },
            mutationWriter: { harness.write($0) },
            researcher: { subject, _ in
                harness.recordResearch()
                return .init(
                    knowledge: .init(kind: subject.kind, subject: subject.subject, meaning: "meaning"),
                    chargedTokenCount: 1
                )
            },
            now: { harness.now },
            sleeper: { harness.sleep($0) }
        )

        let acceptedA = await queue.enqueue(task("Shared", entryID: "a", typeID: "type-a"))
        let acceptedB = await queue.enqueue(task("Shared", entryID: "b", typeID: "type-b"))
        XCTAssertTrue(acceptedA)
        XCTAssertTrue(acceptedB)
        await queue.waitUntilIdle()

        XCTAssertEqual(harness.researchCount, 1)
        XCTAssertEqual(harness.snapshot.tokenUsage.last?.classifierTypeID, "type-b")
    }

    func testQueueDropsSubjectsBeyondCapacity() async {
        let harness = ResearchQueueHarness(now: Date(timeIntervalSince1970: 1_700_000_000))
        let gate = FirstResearchGate()
        let queue = GroundedResearchQueue(
            configurationProvider: { _ in .init(providers: self.providers(), requestsPerMinute: 120, dailyTokenLimit: 10_000) },
            snapshotProvider: { _ in harness.snapshot },
            mutationWriter: { harness.write($0) },
            researcher: { subject, _ in await gate.run(subject) },
            now: { harness.now },
            sleeper: { harness.sleep($0) }
        )
        var accepted = (await queue.enqueue(task("Subject first", entryID: "first"))) ? 1 : 0
        await gate.waitUntilStarted()
        for index in 0..<(GroundedResearchQueue.maximumPendingSubjects + 5) {
            if await queue.enqueue(task("Subject \(index)", entryID: "\(index)")) { accepted += 1 }
        }
        XCTAssertEqual(accepted, GroundedResearchQueue.maximumPendingSubjects)
        let pendingCount = await queue.pendingCount
        XCTAssertEqual(pendingCount, GroundedResearchQueue.maximumPendingSubjects - 1)
        gate.release()
        await queue.waitUntilIdle()
    }

    func testWorkspaceCatalogPersistsNegativeCache() throws {
        var catalog = WorkspaceCatalog()
        let attempt = ResearchAttemptRecord(subjectKey: "term:missing", lastAttemptAtMilliseconds: 10, retryAfterMilliseconds: 20)
        catalog.upsertResearchAttempt(attempt)
        let decoded = try JSONDecoder().decode(WorkspaceCatalog.self, from: JSONEncoder().encode(catalog))
        XCTAssertEqual(decoded.researchAttempts, [attempt])
    }
}

// MARK: - Failure classification, in-place retries, escalating cooldown, retry-now

private final class FailingResearcher: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCalls = 0
    private let errors: [Error]
    init(errors: [Error]) { self.errors = errors }
    var calls: Int { lock.withLock { storedCalls } }
    func run(_ subject: ResearchSubject) async throws -> GroundedResearchResult {
        let index = lock.withLock { () -> Int in defer { storedCalls += 1 }; return storedCalls }
        if index < errors.count { throw errors[index] }
        return .init(knowledge: .init(kind: subject.kind, subject: subject.subject, meaning: "meaning"), chargedTokenCount: 1)
    }
}

final class GroundedResearchFailureHandlingTests: XCTestCase {
    private let hour: Int64 = 60 * 60 * 1_000

    private func providers() -> GroundedResearchProviderConfiguration {
        .init(
            llmProfile: .init(id: "llm", type: .ollama),
            llmCredential: .init(values: [:]),
            llmModelIdentifier: "model",
            maximumOutputTokens: 100
        )
    }

    private func task(_ name: String) -> ResearchTask {
        .init(classifierTypeID: "type", platformID: "youtube", entryID: "entry", creatorID: "creator",
              subjects: [ResearchSubject(kind: .term, subject: name)!])
    }

    private func makeQueue(
        harness: ResearchQueueHarness,
        researcher: FailingResearcher,
        cooldownHours: Int64 = 24
    ) -> GroundedResearchQueue {
        GroundedResearchQueue(
            configurationProvider: { [providers = providers()] _ in
                .init(providers: providers, requestsPerMinute: 120, dailyTokenLimit: 1_000,
                      failureCooldownMilliseconds: cooldownHours * 60 * 60 * 1_000)
            },
            snapshotProvider: { _ in harness.snapshot },
            mutationWriter: { harness.write($0) },
            researcher: { subject, _ in try await researcher.run(subject) },
            now: { harness.now },
            sleeper: { harness.sleep($0) }
        )
    }

    private func failedAttempt(_ harness: ResearchQueueHarness) -> ResearchAttemptRecord? {
        harness.snapshot.failedAttempts.first
    }

    func testClassifyMapsErrorsToKinds() {
        XCTAssertEqual(GroundedResearchFailureKind.classify(URLError(.timedOut)), .timeout)
        XCTAssertEqual(GroundedResearchFailureKind.classify(URLError(.notConnectedToInternet)), .network)
        XCTAssertEqual(GroundedResearchFailureKind.classify(ProviderTestHTTPError.status(429)), .rateLimited)
        XCTAssertEqual(GroundedResearchFailureKind.classify(ProviderTestHTTPError.status(503)), .serverError)
        XCTAssertEqual(GroundedResearchFailureKind.classify(ProviderTestHTTPError.status(401)), .providerRejected)
        XCTAssertEqual(GroundedResearchFailureKind.classify(GroundedResearchError.emptyMeaning), .emptyResponse)
        XCTAssertEqual(GroundedResearchFailureKind.classify(GroundedResearchError.invalidConfiguration), .invalidConfiguration)
        XCTAssertEqual(GroundedResearchFailureKind.classify(ProviderTestProtocolError.invalidResponse), .unknown)
        XCTAssertTrue(GroundedResearchFailureKind.timeout.isTransient)
        XCTAssertFalse(GroundedResearchFailureKind.providerRejected.isTransient)
    }

    func testTransientFailureRetriesInPlaceThenParksOnShortEscalatingCooldown() async {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let harness = ResearchQueueHarness(now: start)
        let researcher = FailingResearcher(errors: Array(repeating: URLError(.timedOut), count: 10))
        let queue = makeQueue(harness: harness, researcher: researcher)

        await queue.enqueue(task("alpha"))
        await queue.waitUntilIdle()

        // 1 request + 2 in-place retries, spaced by the retry delays.
        XCTAssertEqual(researcher.calls, 3)
        XCTAssertEqual(harness.sleepIntervals, GroundedResearchQueue.transientRetryDelays)
        let first = failedAttempt(harness)
        XCTAssertEqual(first?.failureKind, .timeout)
        XCTAssertEqual(first?.failureCount, 1)
        XCTAssertEqual((first?.retryAfterMilliseconds ?? 0) - (first?.lastAttemptAtMilliseconds ?? 0),
                       GroundedResearchQueue.baseTransientCooldownMilliseconds)
        let status = await queue.currentStatus
        XCTAssertEqual(status.failedCount, 1)
        XCTAssertEqual(status.transientRetryCount, 2)
        XCTAssertEqual(status.retryableFailedCount, 1)
        XCTAssertEqual(status.lastFailure?.kind, .timeout)
        XCTAssertNil(status.inFlightSubjectKey)

        // Still cooling → skipped, not re-requested.
        await queue.enqueue(task("alpha"))
        await queue.waitUntilIdle()
        XCTAssertEqual(researcher.calls, 3)
        let skipped = await queue.currentStatus
        XCTAssertEqual(skipped.skippedForCooldownCount, 1)

        // After the cooldown, a second consecutive transient failure doubles it.
        harness.sleep(TimeInterval(GroundedResearchQueue.baseTransientCooldownMilliseconds / 1_000) + 1)
        await queue.enqueue(task("alpha"))
        await queue.waitUntilIdle()
        XCTAssertEqual(researcher.calls, 6)
        let second = failedAttempt(harness)
        XCTAssertEqual(second?.failureCount, 2)
        XCTAssertEqual((second?.retryAfterMilliseconds ?? 0) - (second?.lastAttemptAtMilliseconds ?? 0),
                       GroundedResearchQueue.baseTransientCooldownMilliseconds * 2)
    }

    func testTransientCooldownNeverExceedsConfiguredCooldown() {
        let configured: Int64 = 1 * hour
        XCTAssertEqual(GroundedResearchQueue.cooldownMilliseconds(for: .timeout, failureCount: 1, configured: configured), 15 * 60 * 1_000)
        XCTAssertEqual(GroundedResearchQueue.cooldownMilliseconds(for: .timeout, failureCount: 3, configured: configured), configured)
        XCTAssertEqual(GroundedResearchQueue.cooldownMilliseconds(for: .timeout, failureCount: 40, configured: configured), configured)
        XCTAssertEqual(GroundedResearchQueue.cooldownMilliseconds(for: .providerRejected, failureCount: 1, configured: configured), configured)
    }

    func testPermanentFailureIsNotRetriedAndUsesConfiguredCooldown() async {
        let harness = ResearchQueueHarness(now: Date(timeIntervalSince1970: 1_700_000_000))
        let researcher = FailingResearcher(errors: [ProviderTestHTTPError.status(401)])
        let queue = makeQueue(harness: harness, researcher: researcher, cooldownHours: 24)

        await queue.enqueue(task("beta"))
        await queue.waitUntilIdle()

        XCTAssertEqual(researcher.calls, 1)
        XCTAssertTrue(harness.sleepIntervals.isEmpty)
        let attempt = failedAttempt(harness)
        XCTAssertEqual(attempt?.failureKind, .providerRejected)
        XCTAssertEqual((attempt?.retryAfterMilliseconds ?? 0) - (attempt?.lastAttemptAtMilliseconds ?? 0), 24 * hour)
    }

    func testRetryFailedNowDropsCooldownAndReResearches() async {
        let harness = ResearchQueueHarness(now: Date(timeIntervalSince1970: 1_700_000_000))
        // Permanent failure first, then success on the user-driven retry.
        let researcher = FailingResearcher(errors: [ProviderTestHTTPError.status(401)])
        let queue = makeQueue(harness: harness, researcher: researcher)

        await queue.enqueue(task("gamma"))
        await queue.waitUntilIdle()
        XCTAssertEqual(harness.snapshot.failedAttempts.count, 1)

        let requeued = await queue.retryFailedNow()
        await queue.waitUntilIdle()

        XCTAssertEqual(requeued, 1)
        XCTAssertEqual(researcher.calls, 2)
        XCTAssertTrue(harness.snapshot.failedAttempts.isEmpty)
        XCTAssertTrue(harness.snapshot.existingKnowledgeKeys.contains("term:gamma"))
        var sawRetryRequest = false
        for mutation in harness.mutations {
            if case .retryRequested(_, let key) = mutation, key == "term:gamma" { sawRetryRequest = true }
        }
        XCTAssertTrue(sawRetryRequest)
        let status = await queue.currentStatus
        XCTAssertEqual(status.retryableFailedCount, 0)
        XCTAssertEqual(status.succeededCount, 1)
        // A second retry-now has nothing left to re-queue.
        let again = await queue.retryFailedNow()
        XCTAssertEqual(again, 0)
    }

    func testStatusObserverReportsPendingAndInFlight() async {
        let harness = ResearchQueueHarness(now: Date(timeIntervalSince1970: 1_700_000_000))
        let researcher = FailingResearcher(errors: [])
        let queue = makeQueue(harness: harness, researcher: researcher)
        final class Sink: @unchecked Sendable {
            let lock = NSLock(); var statuses: [GroundedResearchQueueStatus] = []
            func add(_ s: GroundedResearchQueueStatus) { lock.withLock { statuses.append(s) } }
            var all: [GroundedResearchQueueStatus] { lock.withLock { statuses } }
        }
        let sink = Sink()
        await queue.setStatusObserver { sink.add($0) }
        await queue.enqueue(task("delta"))
        await queue.waitUntilIdle()
        let all = sink.all
        XCTAssertTrue(all.contains { $0.pendingCount == 1 })
        XCTAssertTrue(all.contains { $0.inFlightSubjectKey == "term:delta" })
        XCTAssertEqual(all.last?.succeededCount, 1)
        XCTAssertEqual(all.last?.pendingCount, 0)
        XCTAssertNil(all.last?.inFlightSubjectKey)
    }

    func testAttemptRecordDecodesLegacyShapeAndRoundTripsNewFields() throws {
        let legacy = Data("""
        {"subjectKey":"term:old","lastAttemptAtMilliseconds":10,"retryAfterMilliseconds":20}
        """.utf8)
        let decoded = try JSONDecoder().decode(ResearchAttemptRecord.self, from: legacy)
        XCTAssertEqual(decoded.failureCount, 1)
        XCTAssertNil(decoded.failureKind)
        XCTAssertEqual(decoded.displaySubject, "old")

        let record = ResearchAttemptRecord(classifierTypeID: "t", subjectKey: "creator:@someone",
                                           lastAttemptAtMilliseconds: 5, retryAfterMilliseconds: 9,
                                           failureCount: 3, failureKind: .rateLimited)
        let roundTrip = try JSONDecoder().decode(ResearchAttemptRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(roundTrip, record)
        XCTAssertEqual(roundTrip.displaySubject, "@someone")
        let escaped = ResearchAttemptRecord(subjectKey: "creator:@%e5%ad%99taku", lastAttemptAtMilliseconds: 1, retryAfterMilliseconds: 2)
        XCTAssertEqual(escaped.displaySubject, "@\u{5B59}taku")
    }
}
