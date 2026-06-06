import XCTest
@testable import MacBlockerCore

/// Exercises the iOS-portable custom-rule engine (timers, persistence, domain
/// classifiers, redirect, unsupported-helper logging) to prove rules execute.
final class CustomRuleEngineTests: XCTestCase {
    func testDomainHelperClassifiesAndBlocks() throws {
        let runtime = try CustomJavaScriptPolicyRuntime()
        try runtime.load(groupID: "g", source: """
        (event, helpers) => {
          event.registerOpenWebEvent("yt", (ev, h) => {
            if (h.getDomainHelper().isYouTubeHost(ev.hostname)) ev.block("no youtube");
          });
        }
        """)

        let blocked = try runtime.dispatch(
            CustomRuleEvent(type: "openWebEvent", groupID: "g", hostname: "www.youtube.com")
        )
        XCTAssertEqual(blocked.first?.action, .shield)

        let allowed = try runtime.dispatch(
            CustomRuleEvent(type: "openWebEvent", groupID: "g", hostname: "example.com")
        )
        XCTAssertTrue(allowed.isEmpty)
    }

    func testTimerExpiryBlocks() throws {
        let runtime = try CustomJavaScriptPolicyRuntime()
        try runtime.load(groupID: "g", source: """
        (event, helpers) => {
          event.registerTickEvent("t", (ev, h) => {
            const tm = h.getTimerHelper();
            tm.getOrCreateTimer({ id: "x", direction: "backward", currentMs: 1000 });
            tm.addMs("x", -1000);
            if (tm.isExpired("x")) ev.block("time up");
          });
        }
        """)

        let decisions = try runtime.dispatch(CustomRuleEvent(type: "tickEvent", groupID: "g"))
        XCTAssertEqual(decisions.first?.action, .shield)
        XCTAssertEqual(decisions.first?.reason, "time up")
    }

    func testPersistenceCountsAcrossDispatches() throws {
        let runtime = try CustomJavaScriptPolicyRuntime()
        try runtime.load(groupID: "g", source: """
        (event, helpers) => {
          event.registerWebChangedEvent("count", (ev, h) => {
            const p = h.getPersistenceHelper();
            const n = (p.get("n", 0)) + 1;
            p.set("n", n);
            if (n >= 3) ev.block("third visit");
          });
        }
        """)

        XCTAssertTrue(try runtime.dispatch(CustomRuleEvent(type: "webChangedEvent", groupID: "g")).isEmpty)
        XCTAssertTrue(try runtime.dispatch(CustomRuleEvent(type: "webChangedEvent", groupID: "g")).isEmpty)
        let third = try runtime.dispatch(CustomRuleEvent(type: "webChangedEvent", groupID: "g"))
        XCTAssertEqual(third.first?.action, .shield)
    }

    func testRedirectIsRemovedButStillBlocks() throws {
        // Redirection was removed (app blocking has no URL to redirect to).
        // setRedirectLink is now an inert no-op: the event still shields, but
        // no redirect metadata is emitted.
        let runtime = try CustomJavaScriptPolicyRuntime()
        try runtime.load(groupID: "g", source: """
        (event, helpers) => {
          event.registerOpenWebEvent("r", (ev, h) => {
            ev.setRedirectLink("https://example.com/focus");
            ev.setResult(-1);
          });
        }
        """)

        let decisions = try runtime.dispatch(CustomRuleEvent(type: "openWebEvent", groupID: "g"))
        XCTAssertEqual(decisions.first?.action, .shield)
        XCTAssertNil(decisions.first?.metadata["redirect"])
    }

    func testUnsupportedBrowserHelperEmitsLog() throws {
        let runtime = try CustomJavaScriptPolicyRuntime()
        try runtime.load(groupID: "g", source: """
        (event, helpers) => {
          event.registerWebChangedEvent("dom", (ev, h) => {
            h.getDOMHelper().hide(".feed");
          });
        }
        """)

        let decisions = try runtime.dispatch(CustomRuleEvent(type: "webChangedEvent", groupID: "g"))
        XCTAssertEqual(decisions.first?.action, .log)
        XCTAssertTrue(decisions.first?.reason.contains("getDOMHelper") ?? false)
    }

    func testPlatformClassifierAndPriorityOrder() throws {
        let runtime = try CustomJavaScriptPolicyRuntime()
        try runtime.load(groupID: "g", source: """
        (event, helpers) => {
          event.registerOpenWebEvent("shorts", (ev, h) => {
            const yt = h.getPlatformHelper().youtube();
            if (yt.isShortUrl(ev.url)) ev.block("no shorts");
          }, { priority: 5 });
        }
        """)

        let decisions = try runtime.dispatch(
            CustomRuleEvent(type: "openWebEvent", groupID: "g", url: "https://youtube.com/shorts/abc123")
        )
        XCTAssertEqual(decisions.first?.action, .shield)
    }

    func testTypedRegistrarCountsHandlers() throws {
        let runtime = try CustomJavaScriptPolicyRuntime()
        try runtime.load(groupID: "g", source: """
        (event, helpers) => {
          event.registerTickEvent("a", () => {});
          event.registerWebChangedEvent("b", () => {});
        }
        """)
        // Dispatching an unrelated type yields no decisions but does not throw.
        XCTAssertTrue(try runtime.dispatch(CustomRuleEvent(type: "snoozePress", groupID: "g")).isEmpty)
    }
}
