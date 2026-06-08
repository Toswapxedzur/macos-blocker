import XCTest
@testable import MacBlockerCore

final class CustomJavaScriptPolicyRuntimeTests: XCTestCase {
    func testCustomRuleCanBlockTarget() throws {
        let runtime = try CustomJavaScriptPolicyRuntime()
        try runtime.load(
            groupID: "group-1",
            source: """
            (event, helpers) => {
              event.registerUsageThresholdReached("limit", (ev, h) => {
                ev.block("com.zhiliaoapp.musically");
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

        let blockIntents = result.intents.filter { $0.action == "blockApp" }
        XCTAssertEqual(blockIntents.count, 1)
        XCTAssertEqual(blockIntents.first?.target, "com.zhiliaoapp.musically")
    }
}
