import XCTest
@testable import MacBlockerCore

final class CustomRuleRuntimeStressTests: XCTestCase {
    private func appBlockIntents(_ result: DispatchResult) -> [WindowIntent] {
        result.intents.filter { $0.action == "blockApp" }
    }

    func testBrowserEventHandlerDoesNotRegisterInNativeRuntime() throws {
        let runtime = try CustomJavaScriptPolicyRuntime()
        let loaded = try runtime.load(groupID: "browser-event", source: """
        (events) => {
          events.on("webChangedEvent", "never-register", () => {});
        }
        """)

        XCTAssertEqual(loaded.handlers, 0)
    }

    func testBrowserContextCannotCreateNativeBlockIntent() throws {
        let runtime = try CustomJavaScriptPolicyRuntime()
        try runtime.load(groupID: "browser-context", source: """
        (event) => {
          event.registerAppChangedEvent("block-focused", (ev) => ev.block());
        }
        """)

        let result = try runtime.dispatch(CustomRuleEvent(
            type: "appChangedEvent",
            groupID: "browser-context",
            data: ["appId": "com.google.Chrome", "isBrowser": "true"]
        ))

        XCTAssertTrue(result.intents.isEmpty)
    }

    func testNativeAppURLDoesNotMatchBrowserPlatformClassifier() throws {
        let runtime = try CustomJavaScriptPolicyRuntime()
        try runtime.load(groupID: "native-url", source: """
        (event, helpers) => {
          event.registerAppChangedEvent("only-shorts", (ev, h) => {
            if (h.getPlatformHelper().youtube().isShortUrl(ev.url)) ev.block();
          });
        }
        """)

        let result = try runtime.dispatch(CustomRuleEvent(
            type: "appChangedEvent",
            groupID: "native-url",
            url: "app://com.example.FocusTestApp",
            data: ["appId": "com.example.FocusTestApp", "isBrowser": "false"]
        ))

        XCTAssertTrue(appBlockIntents(result).isEmpty)
    }

    func testForegroundAppIdentityBlocksTheActualFocusedApp() throws {
        let runtime = try CustomJavaScriptPolicyRuntime()
        try runtime.load(groupID: "steam", source: """
        (event) => {
          event.registerAppChangedEvent("pause-steam", (ev) => {
            if (ev.data.appId === "steam.exe") ev.block();
          });
        }
        """)

        let result = try runtime.dispatch(CustomRuleEvent(
            type: "appChangedEvent",
            groupID: "steam",
            data: ["appId": "steam.exe"]
        ))

        XCTAssertEqual(appBlockIntents(result).map(\.target), ["steam.exe"])
    }

    func testStaleTargetDoesNotOverrideFocusedAppIdentity() throws {
        let runtime = try CustomJavaScriptPolicyRuntime()
        try runtime.load(groupID: "identity", source: """
        (event) => {
          event.registerAppChangedEvent("pause-steam", (ev) => {
            if (ev.data.appId === "steam.exe") ev.block();
          });
        }
        """)

        let staleTarget = BlockTarget(
            id: "steam-target",
            kind: .application,
            displayName: "Steam",
            normalizedValue: "steam.exe"
        )
        let result = try runtime.dispatch(CustomRuleEvent(
            type: "appChangedEvent",
            groupID: "identity",
            target: staleTarget,
            data: ["appId": "notes.exe"]
        ))

        XCTAssertTrue(appBlockIntents(result).isEmpty)
    }

    func testHigherPriorityHandlerCanStopLowerPriorityHandler() throws {
        let runtime = try CustomJavaScriptPolicyRuntime()
        try runtime.load(groupID: "priority", source: """
        (event) => {
          event.registerAppChangedEvent("first", (ev) => {
            ev.block("com.example.first");
            ev.stopPropagation();
          }, { priority: 20 });
          event.registerAppChangedEvent("second", (ev) => {
            ev.block("com.example.second");
          }, { priority: 0 });
        }
        """)

        let result = try runtime.dispatch(CustomRuleEvent(type: "appChangedEvent", groupID: "priority"))

        XCTAssertEqual(appBlockIntents(result).map(\.target), ["com.example.first"])
    }

    func testIntervalHandlerDoesNotFireTooEarlyButFiresAgainWhenDue() throws {
        let runtime = try CustomJavaScriptPolicyRuntime()
        try runtime.load(groupID: "interval", source: """
        (event) => {
          event.registerTickEvent("minute-rule", (ev) => {
            ev.block("com.example.minute");
          }, { intervalMs: 60000 });
        }
        """)

        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try runtime.dispatch(CustomRuleEvent(type: "tickEvent", groupID: "interval", now: start))
        let tooSoon = try runtime.dispatch(CustomRuleEvent(
            type: "tickEvent",
            groupID: "interval",
            now: start.addingTimeInterval(30)
        ))
        let dueAgain = try runtime.dispatch(CustomRuleEvent(
            type: "tickEvent",
            groupID: "interval",
            now: start.addingTimeInterval(61)
        ))

        XCTAssertEqual(appBlockIntents(first).count, 1)
        XCTAssertTrue(appBlockIntents(tooSoon).isEmpty)
        XCTAssertEqual(appBlockIntents(dueAgain).count, 1)
    }
}
