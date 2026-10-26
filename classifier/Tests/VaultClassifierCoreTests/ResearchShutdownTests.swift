import Foundation
import XCTest
@testable import VaultClassifierCore

private actor ResearchShutdownGate {
    var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    func hold() async { started = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
    func wait() async { while !started { await Task.yield() } }
}
final class ResearchShutdownTests: XCTestCase {
    func testShutdownJoinsActiveResearchAndDiscardsWaitingWithoutMutations() async {
        let gate = ResearchShutdownGate()
        actor Sink { var writes = 0; var requests = 0; func write() { writes += 1 }; func request() { requests += 1 } }
        let sink = Sink()
        let queue = GroundedResearchQueue(configurationProvider: { _ in .init(providers: .init(
            llmProfile: .init(id: "llm", type: .openAI), llmCredential: .init(values: [.apiKey: "fixture-not-real"]), llmModelIdentifier: "fixture", maximumOutputTokens: 100),
            requestsPerMinute: 6000, dailyTokenLimit: 1000) }, snapshotProvider: { _ in .init() },
            mutationWriter: { _ in await sink.write() }, researcher: { subject, _ in
                await sink.request(); await gate.hold()
                return .init(knowledge: .init(kind: subject.kind, subject: subject.subject, meaning: "late"), chargedTokenCount: 1)
            }, sleeper: { _ in })
        func item(_ name: String) -> ResearchTask { .init(classifierTypeID: "type", platformID: "youtube", entryID: "fixture", creatorID: "creator",
            subjects: [ResearchSubject(kind: .term, subject: name)!]) }
        _ = await queue.enqueue(item("active"))
        await gate.wait()
        _ = await queue.enqueue(item("waiting"))
        let closing = Task { await queue.shutdown() }
        while await queue.pendingCount != 0 { await Task.yield() }
        let accepted = await queue.enqueue(item("too-late"))
        XCTAssertFalse(accepted)
        await gate.release()
        await closing.value
        let requests = await sink.requests, writes = await sink.writes, retry = await queue.retryFailedNow()
        XCTAssertEqual(requests, 1); XCTAssertEqual(writes, 0); XCTAssertEqual(retry, 0)
        await queue.shutdown()
    }
}
