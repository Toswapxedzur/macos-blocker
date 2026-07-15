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

    func testRegistrationDeadlineStopsInfiniteLoopAndRuntimeRecovers() throws {
        let runtime = try CustomJavaScriptPolicyRuntime()
        let started = Date()

        XCTAssertThrowsError(try runtime.load(
            groupID: "deadline-load",
            source: "(event) => { while (true) {} }"
        ))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)

        let loaded = try runtime.load(
            groupID: "deadline-load",
            source: "(event) => { event.on('tickEvent', 'recovered', () => {}); }"
        )
        XCTAssertEqual(loaded.handlers, 1)
    }

    func testDispatchDeadlineStopsInfiniteHandlerAndRuntimeRecovers() throws {
        let runtime = try CustomJavaScriptPolicyRuntime()
        try runtime.load(
            groupID: "deadline-dispatch",
            source: "(event) => { event.on('tickEvent', 'loop', () => { while (true) {} }); }"
        )
        let started = Date()

        XCTAssertThrowsError(try runtime.dispatch(
            CustomRuleEvent(type: "tickEvent", groupID: "deadline-dispatch")
        ))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)

        runtime.unload(groupID: "deadline-dispatch")
        let loaded = try runtime.load(
            groupID: "deadline-dispatch",
            source: "(event) => { event.on('tickEvent', 'recovered', () => {}); }"
        )
        XCTAssertEqual(loaded.handlers, 1)
    }

    func testDynamicAppBlocksAreGroupScopedAndUnloadClearsOwner() throws {
        let runtime = try CustomJavaScriptPolicyRuntime()
        try runtime.load(
            groupID: "owner-a",
            source: """
            (event) => {
              event.on("tickEvent", "block", (ev, h) => h.getWindowHelper().block("com.example.a"));
            }
            """
        )
        _ = try runtime.dispatch(CustomRuleEvent(type: "tickEvent", groupID: "owner-a"))

        try runtime.load(
            groupID: "owner-b",
            source: """
            (event) => {
              event.on("tickEvent", "check", (ev, h) => {
                if (h.getWindowHelper().isBlocked("com.example.a")) ev.block("com.example.leaked");
              });
            }
            """
        )
        let isolated = try runtime.dispatch(CustomRuleEvent(type: "tickEvent", groupID: "owner-b"))
        XCTAssertFalse(isolated.intents.contains { $0.target == "com.example.leaked" })

        runtime.unload(groupID: "owner-a")
        try runtime.load(
            groupID: "owner-a",
            source: """
            (event) => {
              event.on("tickEvent", "check-cleared", (ev, h) => {
                if (h.getWindowHelper().isBlocked("com.example.a")) ev.block("com.example.stale");
              });
            }
            """
        )
        let cleared = try runtime.dispatch(CustomRuleEvent(type: "tickEvent", groupID: "owner-a"))
        XCTAssertFalse(cleared.intents.contains { $0.target == "com.example.stale" })
    }
}
