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

    func testLocalFileEventExposesNormalizedResultFields() throws {
        let runtime = try CustomJavaScriptPolicyRuntime()
        try runtime.load(
            groupID: "local-file-group",
            source: """
            (event) => {
              event.registerLocalFileEvent("consume-file-result", (ev) => {
                if (ev.ok && ev.eventName === "read" && ev.action === "readJson" &&
                    ev.value && ev.value.enabled === true && ev.entries.length === 1 &&
                    ev.entries[0].kind === "file" && ev.exists === true && ev.bytes === 17) {
                  ev.block("com.example.localfile");
                }
              });
            }
            """
        )

        let result = try runtime.dispatch(
            CustomRuleEvent(
                type: "localFileEvent",
                groupID: "local-file-group",
                data: [
                    "ok": "true",
                    "eventName": "read",
                    "action": "readJson",
                    "path": "config/focus.json",
                    "valueJSON": #"{"enabled":true}"#,
                    "entriesJSON": #"[{"name":"focus.json","kind":"file"}]"#,
                    "exists": "true",
                    "bytes": "17"
                ]
            )
        )

        XCTAssertEqual(result.intents.first(where: { $0.action == "blockApp" })?.target, "com.example.localfile")
    }

    func testLocalFolderHelperAcceptsOnlySafeSupportedRequests() throws {
        let runtime = try CustomJavaScriptPolicyRuntime()
        try runtime.load(
            groupID: "local-file-helper-group",
            source: """
            (event) => {
              event.registerTickEvent("request-files", (ev, h) => {
                const files = h.getLocalFolderHelper();
                files.requestWrite("notes/focus.txt", "start");
                files.requestAppend("notes/focus.txt", "+more");
                files.requestReadJson("config/focus.json");
                files.requestList();
                files.requestRead("../private.txt");
                files.requestWrite("notes/focus.md", "nope");
              });
            }
            """
        )

        let result = try runtime.dispatch(CustomRuleEvent(type: "tickEvent", groupID: "local-file-helper-group"))
        let localIntents = result.intents.filter { $0.kind == "localFile" }
        XCTAssertEqual(localIntents.map(\.action), ["write", "append", "readJson", "list"])
        XCTAssertEqual(localIntents.map(\.path), ["notes/focus.txt", "notes/focus.txt", "config/focus.json", ""])
    }
}
