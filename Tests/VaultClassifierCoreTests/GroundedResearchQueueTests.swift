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
            }
        }
    }
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

final class GroundedResearchQueueTests: XCTestCase {
    private func providers(outputTokens: Int = 100) -> GroundedResearchProviderConfiguration {
        .init(
            llmProfile: .init(id: "llm", type: .ollama),
            llmCredential: .init(values: [:]),
            llmModelIdentifier: "model",
            webSearchProfile: .init(id: "search", type: .serper, credential: "key"),
            webSearchCredential: .init(values: [.apiKey: "key"]),
            maximumOutputTokens: outputTokens
        )
    }

    private func task(_ name: String, entryID: String = "entry", typeID: String = "type") -> ResearchTask {
        .init(
            classifierTypeID: typeID,
            platformID: "youtube",
            entryID: entryID,
            creatorID: "creator",
            subjects: [ResearchSubject(kind: .term, subject: name)!]
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
