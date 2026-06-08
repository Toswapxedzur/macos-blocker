import XCTest
@testable import MacBlockerCore

final class CustomJavaScriptPolicyRuntimeTests: XCTestCase {
    func testCustomRuleCanShieldTarget() throws {
        let runtime = try CustomJavaScriptPolicyRuntime()
        try runtime.load(
            groupID: "group-1",
            source: """
            (event, helpers) => {
              event.registerUsageThresholdReached("limit", (ev, h) => {
                ev.block("Daily limit reached");
                ev.setShieldMessage("Go back to work");
              });
            }
            """
        )

        let target = BlockTarget(
            id: "app.tiktok",
            kind: .application,
            displayName: "TikTok",
            normalizedValue: "com.zhiliaoapp.musically"
        )
        let result = try runtime.dispatch(
            CustomRuleEvent(
                type: "usageThresholdReached",
                groupID: "group-1",
                target: target
            )
        )

        XCTAssertEqual(result.decisions.first?.action, .shield)
        XCTAssertEqual(result.decisions.first?.shieldMessage, "Go back to work")
        XCTAssertEqual(result.decisions.first?.targetIDs, [target.id])
    }
}
