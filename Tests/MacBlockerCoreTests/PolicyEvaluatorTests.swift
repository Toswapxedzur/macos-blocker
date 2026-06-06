import XCTest
@testable import MacBlockerCore

final class PolicyEvaluatorTests: XCTestCase {
    func testInstantGroupShieldsMatchingTarget() {
        let target = BlockTarget(
            id: "app.tiktok",
            kind: .application,
            displayName: "TikTok",
            normalizedValue: "com.zhiliaoapp.musically"
        )
        let group = BlockGroup(
            id: "group-1",
            name: "Short Video Block",
            mode: .instant,
            targets: [target]
        )
        let context = ActivityContext(
            target: target,
            activeTargetIDs: [target.id],
            platform: .iOS
        )

        let result = PolicyEvaluator().evaluate(
            groups: [group],
            usage: UsageSnapshot(),
            context: context
        )

        XCTAssertEqual(result.decisions.first?.action, .shield)
        XCTAssertEqual(result.decisions.first?.targetIDs, [target.id])
    }

    func testTimedGroupShowsStatusUntilLimitThenShields() {
        let target = BlockTarget(
            id: "app.youtube",
            kind: .application,
            displayName: "YouTube",
            normalizedValue: "com.google.ios.youtube"
        )
        let group = BlockGroup(
            id: "group-1",
            name: "YouTube Budget",
            mode: .afterMinutes,
            allowedMinutes: 10,
            targets: [target]
        )
        let context = ActivityContext(
            target: target,
            activeTargetIDs: [target.id],
            platform: .iOS
        )

        let status = PolicyEvaluator().evaluate(
            groups: [group],
            usage: UsageSnapshot(usageByGroupSeconds: [group.id: 60]),
            context: context
        )
        XCTAssertEqual(status.decisions.first?.action, .showStatus)

        let blocked = PolicyEvaluator().evaluate(
            groups: [group],
            usage: UsageSnapshot(usageByGroupSeconds: [group.id: 600]),
            context: context
        )
        XCTAssertEqual(blocked.decisions.first?.action, .shield)
    }

    func testSnoozedGroupDoesNotShield() {
        let target = BlockTarget(
            id: "app.reddit",
            kind: .application,
            displayName: "Reddit",
            normalizedValue: "com.reddit.Reddit"
        )
        let group = BlockGroup(
            id: "group-1",
            name: "Reddit Block",
            mode: .instant,
            targets: [target]
        )
        let now = Date()
        let usage = UsageSnapshot(
            snoozesByGroup: [
                group.id: SnoozeState(
                    startsAt: now.addingTimeInterval(-60),
                    until: now.addingTimeInterval(60)
                )
            ]
        )
        let context = ActivityContext(
            now: now,
            target: target,
            activeTargetIDs: [target.id],
            platform: .iOS
        )

        let result = PolicyEvaluator().evaluate(groups: [group], usage: usage, context: context)

        XCTAssertTrue(result.decisions.isEmpty)
    }
}
