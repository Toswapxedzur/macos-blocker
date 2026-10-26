import Foundation
import XCTest
@testable import VaultClassifierCore

final class ResearchCancellationTests: XCTestCase {
    func testCancelledResearchDoesNotPersistFailureCooldownOrRetry() async {
        actor Mutations {
            var count = 0
            func add() { count += 1 }
        }
        let mutations = Mutations()
        let queue = GroundedResearchQueue(
            configurationProvider: { _ in .init(providers: .init(llmProfile: .init(id: "llm", type: .openAI),
                llmCredential: .init(values: [.apiKey: "fixture-not-real"]), llmModelIdentifier: "fixture", maximumOutputTokens: 100), requestsPerMinute: 6000, dailyTokenLimit: 1000) },
            snapshotProvider: { _ in .init() }, mutationWriter: { _ in await mutations.add() },
            researcher: { _, _ in throw CancellationError() }, sleeper: { _ in })
        _ = await queue.enqueue(.init(classifierTypeID: "type", platformID: "youtube", entryID: "fixture", creatorID: "creator",
            subjects: [ResearchSubject(kind: .term, subject: "cancelled")!]))
        await queue.waitUntilIdle()
        let count = await mutations.count, status = await queue.currentStatus
        XCTAssertEqual(count, 0)
        XCTAssertEqual(status.failedCount, 0)
        XCTAssertEqual(status.retryableFailedCount, 0)
        XCTAssertEqual(status.transientRetryCount, 0)
    }
}
