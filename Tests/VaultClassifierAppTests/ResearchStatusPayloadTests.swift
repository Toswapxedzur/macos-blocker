import XCTest
import VaultClassifierCore
@testable import VaultClassifierApp

@MainActor
final class ResearchStatusPayloadTests: XCTestCase {
    func testPayloadCombinesLiveCountersWithDurableCooldowns() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let nowMs = Int64(now.timeIntervalSince1970 * 1_000)
        var queue = GroundedResearchQueueStatus()
        queue.pendingCount = 2
        queue.inFlightSubjectKey = "creator:@someone"
        queue.succeededCount = 5
        queue.failedCount = 1
        queue.transientRetryCount = 3
        queue.skippedForBudgetCount = 4
        queue.retryableFailedCount = 1
        let attempts: [ResearchAttemptRecord] = [
            // Cooling, transient, most recent.
            .init(classifierTypeID: "t", subjectKey: "term:alpha", lastAttemptAtMilliseconds: nowMs - 60_000,
                  retryAfterMilliseconds: nowMs + 14 * 60_000, failureCount: 2, failureKind: .timeout),
            // Cooling, permanent.
            .init(classifierTypeID: "t", subjectKey: "term:beta", lastAttemptAtMilliseconds: nowMs - 3_600_000,
                  retryAfterMilliseconds: nowMs + 3_600_000, failureCount: 1, failureKind: .providerRejected),
            // Expired cooldown: not counted as cooling.
            .init(classifierTypeID: "t", subjectKey: "term:gamma", lastAttemptAtMilliseconds: nowMs - 7_200_000,
                  retryAfterMilliseconds: nowMs - 1, failureCount: 1, failureKind: .network),
        ]
        let payload = VaultClassifierViewModel.researchStatusPayload(queue: queue, attempts: attempts, now: now)
        XCTAssertEqual(payload["pending"] as? Int, 2)
        XCTAssertEqual(payload["inFlight"] as? String, "@someone")
        XCTAssertEqual(payload["succeeded"] as? Int, 5)
        XCTAssertEqual(payload["failed"] as? Int, 1)
        XCTAssertEqual(payload["retries"] as? Int, 3)
        XCTAssertEqual(payload["skippedBudget"] as? Int, 4)
        XCTAssertEqual(payload["retryable"] as? Int, 1)
        XCTAssertEqual(payload["inCooldown"] as? Int, 2)
        XCTAssertEqual(payload["transientInCooldown"] as? Int, 1)
        let failure = try XCTUnwrap(payload["lastFailure"] as? [String: Any])
        XCTAssertEqual(failure["subject"] as? String, "alpha")
        XCTAssertEqual(failure["kind"] as? String, "timeout")
        XCTAssertEqual(failure["agoSeconds"] as? Int64, 60)
        XCTAssertEqual(failure["retryInSeconds"] as? Int64, 14 * 60)
        XCTAssertEqual(failure["failureCount"] as? Int, 2)
    }

    func testPayloadWithoutFailuresIsExplicitlyEmpty() {
        let payload = VaultClassifierViewModel.researchStatusPayload(queue: .init(), attempts: [], now: Date())
        XCTAssertEqual(payload["inCooldown"] as? Int, 0)
        XCTAssertEqual(payload["inFlight"] as? String, "")
        XCTAssertTrue(payload["lastFailure"] is NSNull)
    }
}
