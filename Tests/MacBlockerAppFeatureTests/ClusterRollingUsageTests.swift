import XCTest
@testable import MacBlockerAppFeature
import MacBlockerCore

/// Linked groups with a rolling limit share per-minute usage through the hub.
final class ClusterRollingUsageTests: XCTestCase {
    private func linkedHub() -> ConnectionHub {
        let hub = ConnectionHub()
        hub.setRoster(program: "macapp", groups: [["id": "m1", "name": "Focus"]])
        hub.setRoster(program: "chrome", groups: [["id": "c1", "name": "Focus"]])
        return hub
    }

    func testSeedThenIncrementsAreSummedPerMinute() throws {
        let hub = linkedHub()
        let minute = UsageBudget.bucketStartMs(Date().timeIntervalSince1970 * 1000)
        let key = String(Int64(minute))

        hub.applySync(program: "chrome", groupName: "Focus",
                      contribution: ["usageBucketsSeed": [key: 30_000.0]], ts: 0)
        XCTAssertEqual(try XCTUnwrap(hub.sharedUsage(groupName: "Focus")).buckets[minute], 30_000,
                       "a member's history seeds the shared minutes")

        hub.applySync(program: "macapp", groupName: "Focus",
                      contribution: ["usageBuckets": [key: 20_000.0]], ts: 0)
        XCTAssertEqual(try XCTUnwrap(hub.sharedUsage(groupName: "Focus")).buckets[minute], 50_000,
                       "increments add to the seeded minute")

        hub.applySync(program: "chrome", groupName: "Focus",
                      contribution: ["usageBucketsSeed": [key: 99_000.0]], ts: 0)
        XCTAssertEqual(try XCTUnwrap(hub.sharedUsage(groupName: "Focus")).buckets[minute], 50_000,
                       "a late seed never overrides real increments")
    }

    func testMinutesOlderThanAnyWindowArePruned() throws {
        let hub = linkedHub()
        let old = UsageBudget.bucketStartMs(Date().timeIntervalSince1970 * 1000 - 3 * 86_400_000)
        hub.applySync(program: "chrome", groupName: "Focus",
                      contribution: ["usageBuckets": [String(Int64(old)): 60_000.0]], ts: 0)
        XCTAssertTrue(try XCTUnwrap(hub.sharedUsage(groupName: "Focus")).buckets.isEmpty)
    }
}
