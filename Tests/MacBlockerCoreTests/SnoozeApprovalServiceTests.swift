import XCTest
@testable import MacBlockerCore

final class SnoozeApprovalServiceTests: XCTestCase {
    private func group(
        id: String,
        allowSnooze: Bool = true,
        minutes: Int = 30,
        confirmations: Int = 0,
        cooldown: Int = 0,
        delay: Int = 0,
        type: BlockGroupType = .site
    ) -> BlockGroup {
        BlockGroup(
            id: id,
            groupType: type,
            name: id,
            allowSnooze: allowSnooze,
            snoozeMinutes: minutes,
            snoozeActivationDelayMinutes: delay,
            snoozeCooldownMinutes: cooldown,
            snoozeConfirmations: confirmations
        )
    }

    func testApprovesEligibleRequest() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let (usage, result) = SnoozeApprovalService.process(
            requests: [SnoozeRequest(groupID: "g1")],
            groups: [group(id: "g1", minutes: 30)],
            usage: UsageSnapshot(),
            now: now
        )

        XCTAssertEqual(result.approvedGroupIDs, ["g1"])
        let snooze = usage.snoozesByGroup["g1"]
        XCTAssertEqual(snooze?.phase(at: now), .active)
        XCTAssertEqual(snooze?.until, now.addingTimeInterval(30 * 60))
    }

    func testRejectsWhenSnoozeDisabled() {
        let (_, result) = SnoozeApprovalService.process(
            requests: [SnoozeRequest(groupID: "g1")],
            groups: [group(id: "g1", allowSnooze: false)],
            usage: UsageSnapshot()
        )
        XCTAssertEqual(result.rejectedGroupIDs, ["g1"])
    }

    func testCustomGroupCannotSnooze() {
        let (_, result) = SnoozeApprovalService.process(
            requests: [SnoozeRequest(groupID: "c")],
            groups: [group(id: "c", type: .custom)],
            usage: UsageSnapshot()
        )
        XCTAssertEqual(result.rejectedGroupIDs, ["c"])
    }

    func testConfirmationsRequireMultiplePresses() {
        let g = group(id: "g1", confirmations: 2)
        let onePress = SnoozeApprovalService.process(
            requests: [SnoozeRequest(groupID: "g1")],
            groups: [g],
            usage: UsageSnapshot()
        )
        XCTAssertEqual(onePress.result.rejectedGroupIDs, ["g1"])

        let twoPresses = SnoozeApprovalService.process(
            requests: [SnoozeRequest(groupID: "g1"), SnoozeRequest(groupID: "g1")],
            groups: [g],
            usage: UsageSnapshot()
        )
        XCTAssertEqual(twoPresses.result.approvedGroupIDs, ["g1"])
    }

    func testActivationDelayDefersStart() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let (usage, _) = SnoozeApprovalService.process(
            requests: [SnoozeRequest(groupID: "g1")],
            groups: [group(id: "g1", delay: 5)],
            usage: UsageSnapshot(),
            now: now
        )
        XCTAssertEqual(usage.snoozesByGroup["g1"]?.phase(at: now), .pending)
        XCTAssertEqual(usage.snoozesByGroup["g1"]?.phase(at: now.addingTimeInterval(6 * 60)), .active)
    }

    func testUnmatchedRequestRecorded() {
        let req = SnoozeRequest(groupID: nil)
        let (_, result) = SnoozeApprovalService.process(
            requests: [req],
            groups: [group(id: "g1")],
            usage: UsageSnapshot()
        )
        XCTAssertEqual(result.unmatchedRequestIDs, [req.id])
    }

    func testNativeTargetsMergeIntoPlan() {
        let groups = [BlockGroup(id: "g1", name: "G1", enabled: true)]
        let native = [
            "g1": [BlockTarget(id: "app1", kind: .application, displayName: "A", normalizedValue: "app1")]
        ]
        let plan = EnforcementPlanBuilder.build(from: groups, nativeTargetsByGroup: native)
        XCTAssertEqual(plan.entry(forGroupID: "g1")?.applicationTargetIDs, ["app1"])
    }
}
