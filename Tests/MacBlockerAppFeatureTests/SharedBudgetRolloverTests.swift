import XCTest
@testable import MacBlockerAppFeature
import MacBlockerCore

/// Owner 2026-09-25: once a cluster forms, the hub (Mac side) is the only
/// authority over the shared budget's period. A member's anchor only seeds it;
/// the hub starts each new period itself and members adopt the reset total.
final class SharedBudgetRolloverTests: XCTestCase {
    private let hour = 3_600_000.0

    private func linkedHub(intervalHours: Double) -> ConnectionHub {
        let hub = ConnectionHub()
        hub.setRoster(program: "macapp", groups: [["id": "m1", "name": "Focus"]])
        hub.setRoster(program: "chrome", groups: [["id": "c1", "name": "Focus"]])
        hub.applySync(program: "chrome", groupName: "Focus",
                      contribution: ["scalars": ["resetIntervalHours": intervalHours, "resetAtMidnight": false, "rollingLimit": false]],
                      ts: 1)
        return hub
    }

    func testAMemberAnchorOnlySeedsThePeriod() throws {
        let hub = linkedHub(intervalHours: 24)
        let now = (Date().timeIntervalSince1970 * 1000).rounded(.down)
        hub.applySync(program: "chrome", groupName: "Focus",
                      contribution: ["usageResetAtMs": now - hour, "usageMs": 600_000.0], ts: 0)
        var shared = try XCTUnwrap(hub.sharedUsage(groupName: "Focus"))
        XCTAssertEqual(shared.resetAtMs, now - hour, "the first anchor seeds the shared period")
        XCTAssertEqual(shared.ms, 600_000, "and the member's total seeds the budget")

        hub.applySync(program: "macapp", groupName: "Focus",
                      contribution: ["usageResetAtMs": now, "usageDeltaMs": 60_000.0], ts: 0)
        shared = try XCTUnwrap(hub.sharedUsage(groupName: "Focus"))
        XCTAssertEqual(shared.resetAtMs, now - hour, "a member can no longer move the period")
        XCTAssertEqual(shared.ms, 660_000, "…nor wipe the budget")
    }

    func testTheHubStartsTheNextPeriodOnItsOwn() throws {
        let hub = linkedHub(intervalHours: 1)
        let anchor = (Date().timeIntervalSince1970 * 1000).rounded(.down) - 2.5 * hour
        hub.applySync(program: "chrome", groupName: "Focus",
                      contribution: ["usageResetAtMs": anchor + 2 * hour, "usageMs": 3_600_000.0], ts: 0)
        // Nobody reports again; the hub's own clock ends the period.
        hub.rollSharedBudgets(nowMs: anchor + 3.2 * hour)
        let shared = try XCTUnwrap(hub.sharedUsage(groupName: "Focus"))
        XCTAssertEqual(shared.resetAtMs, anchor + 3 * hour, "the new period starts on the grid")
        XCTAssertEqual(shared.ms, 0, "the spent total restarts at zero")

        hub.applySync(program: "macapp", groupName: "Focus",
                      contribution: ["usageMs": 3_600_000.0], ts: 0)
        XCTAssertEqual(try XCTUnwrap(hub.sharedUsage(groupName: "Focus")).ms, 0,
                       "a member's old absolute total cannot seed the new period back")
    }

    func testARollingLimitHasNoPeriodToRoll() throws {
        let hub = ConnectionHub()
        hub.setRoster(program: "macapp", groups: [["id": "m1", "name": "Focus"]])
        hub.setRoster(program: "chrome", groups: [["id": "c1", "name": "Focus"]])
        hub.applySync(program: "chrome", groupName: "Focus",
                      contribution: ["scalars": ["resetIntervalHours": 1.0, "rollingLimit": true]], ts: 1)
        let anchor = (Date().timeIntervalSince1970 * 1000).rounded(.down) - 5 * hour
        hub.applySync(program: "chrome", groupName: "Focus", contribution: ["usageResetAtMs": anchor], ts: 0)
        hub.rollSharedBudgets(nowMs: anchor + 5 * hour)
        XCTAssertEqual(try XCTUnwrap(hub.sharedUsage(groupName: "Focus")).resetAtMs, anchor)
    }
}
