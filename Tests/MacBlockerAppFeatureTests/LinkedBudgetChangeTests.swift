import XCTest
@testable import MacBlockerAppFeature
import MacBlockerCore

/// Owner 2026-09-26: linked groups are one group, so a budget change made on
/// any device restarts the shared budget for every device — with the same
/// fields that restart an unlinked group's budget in the editor. Groups link
/// by name regardless of letter case (names are unique that way).
final class LinkedBudgetChangeTests: XCTestCase {
    private func linkedHub(chromeName: String = "Focus") -> ConnectionHub {
        let hub = ConnectionHub()
        hub.setRoster(program: "macapp", groups: [["id": "m1", "name": "Focus"]])
        hub.setRoster(program: "chrome", groups: [["id": "c1", "name": chromeName]])
        hub.applySync(program: "chrome", groupName: chromeName,
                      contribution: ["scalars": ["mode": "after-minutes", "allowedMinutes": 30, "resetIntervalHours": 24.0,
                                                 "resetAtMidnight": false, "rollingLimit": false]],
                      ts: 1)
        hub.applySync(program: "chrome", groupName: chromeName,
                      contribution: ["usageResetAtMs": 1_000.0, "usageDeltaMs": 600_000.0], ts: 0)
        return hub
    }

    func testChangingTheBudgetPeriodRestartsTheSharedBudget() throws {
        let hub = linkedHub()
        XCTAssertEqual(try XCTUnwrap(hub.sharedUsage(groupName: "Focus")).ms, 600_000)
        let before = (Date().timeIntervalSince1970 * 1000).rounded(.down)
        hub.applySync(program: "macapp", groupName: "Focus",
                      contribution: ["scalars": ["mode": "after-minutes", "allowedMinutes": 30, "resetIntervalHours": 12.0,
                                                 "resetAtMidnight": false, "rollingLimit": false]],
                      ts: 2)
        let shared = try XCTUnwrap(hub.sharedUsage(groupName: "Focus"))
        XCTAssertEqual(shared.ms, 0, "every device adopts the restarted total")
        XCTAssertGreaterThanOrEqual(shared.resetAtMs, before, "the new period starts now")
    }

    func testARestartedMidnightBudgetStartsOnTheGrid() throws {
        let hub = linkedHub()
        hub.applySync(program: "macapp", groupName: "Focus",
                      contribution: ["scalars": ["mode": "after-minutes", "allowedMinutes": 30, "resetIntervalHours": 24.0,
                                                 "resetAtMidnight": true, "rollingLimit": false]],
                      ts: 2)
        let anchor = try XCTUnwrap(hub.sharedUsage(groupName: "Focus")).resetAtMs
        let midnight = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 * 1000
        XCTAssertEqual(anchor, midnight, "the period every program computes starts at midnight, not at the edit")
    }

    func testChangingOnlyTheAllowanceKeepsTheSpentTime() throws {
        let hub = linkedHub()
        hub.applySync(program: "macapp", groupName: "Focus",
                      contribution: ["scalars": ["mode": "after-minutes", "allowedMinutes": 45, "resetIntervalHours": 24.0,
                                                 "resetAtMidnight": false, "rollingLimit": false]],
                      ts: 2)
        XCTAssertEqual(try XCTUnwrap(hub.sharedUsage(groupName: "Focus")).ms, 600_000,
                       "the editor keeps the spent time when only the minutes change; so does the link")
    }

    func testAnOlderEditThatLosesChangesNothing() throws {
        let hub = linkedHub()
        hub.applySync(program: "macapp", groupName: "Focus",
                      contribution: ["scalars": ["mode": "instant", "resetIntervalHours": 24.0]],
                      ts: 0)
        XCTAssertEqual(try XCTUnwrap(hub.sharedUsage(groupName: "Focus")).ms, 600_000)
    }

    func testOfflineTimeFromTwoBrowsersAddsUpForTheCurrentPeriodOnly() throws {
        let hub = linkedHub()
        hub.setRoster(program: "firefox", groups: [["id": "f1", "name": "Focus"]])
        let period = try XCTUnwrap(hub.sharedUsage(groupName: "Focus")).resetAtMs
        hub.applySync(program: "chrome", groupName: "Focus",
                      contribution: ["usageDeltaMs": 120_000.0, "usageDeltaAnchorMs": period], ts: 0)
        hub.applySync(program: "firefox", groupName: "Focus",
                      contribution: ["usageDeltaMs": 60_000.0, "usageDeltaAnchorMs": period], ts: 0)
        XCTAssertEqual(try XCTUnwrap(hub.sharedUsage(groupName: "Focus")).ms, 780_000, "600 000 + both browsers' offline time")
        hub.applySync(program: "firefox", groupName: "Focus",
                      contribution: ["usageDeltaMs": 60_000.0, "usageDeltaAnchorMs": period - 1], ts: 0)
        XCTAssertEqual(try XCTUnwrap(hub.sharedUsage(groupName: "Focus")).ms, 780_000, "time from a period that already ended is not added")
    }

    func testPeriodsCompareInWholeMilliseconds() throws {
        // A browser stores whole milliseconds; the hub must never hold a
        // fractional period start the browser can't match (live bug 2026-09-26).
        let hub = linkedHub()
        hub.applySync(program: "macapp", groupName: "Focus",
                      contribution: ["scalars": ["mode": "after-minutes", "allowedMinutes": 30, "resetIntervalHours": 12.0,
                                                 "resetAtMidnight": false, "rollingLimit": false]], ts: 2)
        let period = try XCTUnwrap(hub.sharedUsage(groupName: "Focus")).resetAtMs
        XCTAssertEqual(period, period.rounded(.down), "a restarted period starts on a whole millisecond")
        hub.applySync(program: "chrome", groupName: "Focus",
                      contribution: ["usageDeltaMs": 2_000.0, "usageDeltaAnchorMs": period.rounded(.down)], ts: 0)
        XCTAssertEqual(try XCTUnwrap(hub.sharedUsage(groupName: "Focus")).ms, 2_000)
    }

    func testNamesLinkRegardlessOfLetterCase() throws {
        let hub = linkedHub(chromeName: "focus ")
        XCTAssertEqual(try XCTUnwrap(hub.sharedUsage(groupName: "Focus")).ms, 600_000,
                       "'focus ' in the browser and 'Focus' on the Mac are one linked group")
    }
}
