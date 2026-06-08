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
        ).decisions
        XCTAssertEqual(blocked.first?.action, .shield)

        let allowed = try runtime.dispatch(
            CustomRuleEvent(type: "openWebEvent", groupID: "g", hostname: "example.com")
        ).decisions
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

        let decisions = try runtime.dispatch(CustomRuleEvent(type: "tickEvent", groupID: "g")).decisions
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

        XCTAssertTrue(try runtime.dispatch(CustomRuleEvent(type: "webChangedEvent", groupID: "g")).decisions.isEmpty)
        XCTAssertTrue(try runtime.dispatch(CustomRuleEvent(type: "webChangedEvent", groupID: "g")).decisions.isEmpty)
        let third = try runtime.dispatch(CustomRuleEvent(type: "webChangedEvent", groupID: "g")).decisions
        XCTAssertEqual(third.first?.action, .shield)
    }

    func testRedirectIsRemovedButStillBlocks() throws {
        let runtime = try CustomJavaScriptPolicyRuntime()
        try runtime.load(groupID: "g", source: """
        (event, helpers) => {
          event.registerOpenWebEvent("r", (ev, h) => {
            ev.setRedirectLink("https://example.com/focus");
            ev.setResult(-1);
          });
        }
        """)

        let decisions = try runtime.dispatch(CustomRuleEvent(type: "openWebEvent", groupID: "g")).decisions
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

        let decisions = try runtime.dispatch(CustomRuleEvent(type: "webChangedEvent", groupID: "g")).decisions
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
        ).decisions
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
        XCTAssertTrue(try runtime.dispatch(CustomRuleEvent(type: "snoozePress", groupID: "g")).decisions.isEmpty)
    }

    func testTimerEndedAutoFires() throws {
        let runtime = try CustomJavaScriptPolicyRuntime()
        try runtime.load(groupID: "g", source: """
        (event, helpers) => {
          event.registerTickEvent("setup", (ev, h) => {
            const tm = h.getTimerHelper();
            const t = tm.getOrCreateTimer({ id: "countdown", direction: "backward", currentMs: 500 });
            tm.addMs("countdown", -500);
          });
          event.registerTimerEndedEvent("react", (ev, h) => {
            ev.block("timer expired: " + ev.data.timerId);
          });
        }
        """)

        let decisions = try runtime.dispatch(CustomRuleEvent(type: "tickEvent", groupID: "g")).decisions
        let shieldDecisions = decisions.filter { $0.action == .shield }
        XCTAssertEqual(shieldDecisions.count, 1)
        XCTAssertTrue(shieldDecisions.first?.reason.contains("countdown") ?? false)
    }

    func testWorkHoursTickRuleRegistersAndBlocks() throws {
        let runtime = try CustomJavaScriptPolicyRuntime()
        try runtime.load(groupID: "g", source: """
        (events, helpers) => {
            events.registerTickEvent("work-hours", (ev, h) => {
              const hour = new Date(ev.time.now).getHours();
              if (hour >= 9 && hour < 17) {
                ev.block("Blocked during work hours (9am-5pm)");
              }
            });
          }
        """)

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        var components = cal.dateComponents([.year, .month, .day], from: Date())
        components.hour = 10
        components.minute = 0
        components.second = 0
        let workTime = cal.date(from: components)!

        let decisions = try runtime.dispatch(
            CustomRuleEvent(type: "tickEvent", groupID: "g", now: workTime)
        ).decisions
        XCTAssertEqual(decisions.first?.action, .shield)
        XCTAssertEqual(decisions.first?.reason, "Blocked during work hours (9am-5pm)")

        components.hour = 20
        let eveningTime = cal.date(from: components)!
        let eveningDecisions = try runtime.dispatch(
            CustomRuleEvent(type: "tickEvent", groupID: "g", now: eveningTime)
        ).decisions
        XCTAssertTrue(eveningDecisions.isEmpty)
    }

    func testTimerEndedDeduplicatesAcrossDispatches() throws {
        let runtime = try CustomJavaScriptPolicyRuntime()
        try runtime.load(groupID: "g", source: """
        (event, helpers) => {
          event.registerTickEvent("drain", (ev, h) => {
            const tm = h.getTimerHelper();
            tm.getOrCreateTimer({ id: "x", direction: "backward", currentMs: 0 });
          });
          event.registerTimerEndedEvent("log", (ev, h) => {
            h.log("fired for " + ev.data.timerId);
          });
        }
        """)

        let first = try runtime.dispatch(CustomRuleEvent(type: "tickEvent", groupID: "g")).decisions
        let firstLogs = first.filter { $0.action == .log && $0.reason.contains("fired for x") }
        XCTAssertEqual(firstLogs.count, 1)

        let second = try runtime.dispatch(CustomRuleEvent(type: "tickEvent", groupID: "g")).decisions
        let secondLogs = second.filter { $0.action == .log && $0.reason.contains("fired for x") }
        XCTAssertEqual(secondLogs.count, 0)
    }

    func testWindowHelperBlockAndUnblock() throws {
        let runtime = try CustomJavaScriptPolicyRuntime()
        try runtime.load(groupID: "g", source: """
        (event, helpers) => {
          event.registerTickEvent("blocker", (ev, h) => {
            const win = h.getWindowHelper();
            win.block("youtube.com");
            win.block("tiktok.com");
            if (win.isBlocked("youtube.com")) {
              h.log("youtube is blocked");
            }
            if (!win.isBlocked("example.com")) {
              h.log("example is not blocked");
            }
          });
        }
        """)

        let result = try runtime.dispatch(CustomRuleEvent(type: "tickEvent", groupID: "g"))
        let logs = result.decisions.filter { $0.action == .log }
        XCTAssertTrue(logs.contains(where: { $0.reason.contains("youtube is blocked") }))
        XCTAssertTrue(logs.contains(where: { $0.reason.contains("example is not blocked") }))

        let blockIntents = result.intents.filter { $0.action == "blockSite" }
        XCTAssertEqual(blockIntents.count, 2)
        XCTAssertTrue(blockIntents.contains(where: { $0.pattern == "youtube.com" }))
        XCTAssertTrue(blockIntents.contains(where: { $0.pattern == "tiktok.com" }))
    }

    func testWindowHelperCloseTab() throws {
        let runtime = try CustomJavaScriptPolicyRuntime()
        try runtime.load(groupID: "g", source: """
        (event, helpers) => {
          event.registerOpenWebEvent("close-yt", (ev, h) => {
            const win = h.getWindowHelper();
            if (ev.hostname.includes("youtube.com")) {
              win.closeTab();
            }
          });
        }
        """)

        let result = try runtime.dispatch(
            CustomRuleEvent(type: "openWebEvent", groupID: "g",
                            url: "https://youtube.com/watch?v=123", hostname: "youtube.com")
        )
        let closeIntents = result.intents.filter { $0.action == "closeTab" }
        XCTAssertEqual(closeIntents.count, 1)
    }

    func testWindowHelperCurrentReadsEventData() throws {
        let runtime = try CustomJavaScriptPolicyRuntime()
        try runtime.load(groupID: "g", source: """
        (event, helpers) => {
          event.registerTickEvent("info", (ev, h) => {
            const win = h.getWindowHelper();
            const cur = win.current();
            h.log("app=" + cur.id + " browser=" + cur.isBrowser);
          });
        }
        """)

        let result = try runtime.dispatch(
            CustomRuleEvent(type: "tickEvent", groupID: "g",
                            url: "https://example.com", hostname: "example.com",
                            data: ["appId": "com.google.Chrome", "isBrowser": "true", "tabTitle": "Test"])
        )
        let logs = result.decisions.filter { $0.action == .log }
        XCTAssertTrue(logs.contains(where: { $0.reason.contains("app=com.google.Chrome") }))
        XCTAssertTrue(logs.contains(where: { $0.reason.contains("browser=true") }))
    }

    func testTickEventFiresLogDecision() throws {
        let runtime = try CustomJavaScriptPolicyRuntime()
        let loadResult = try runtime.load(groupID: "g", source: """
        (event, helpers) => {
          event.registerTickEvent("test", (ev, h) => {
            h.log("nih");
          });
        }
        """)
        XCTAssertEqual(loadResult.handlers, 1)

        let result = try runtime.dispatch(
            CustomRuleEvent(type: "tickEvent", groupID: "g")
        )
        let logs = result.decisions.filter { $0.action == .log }
        XCTAssertEqual(logs.count, 1)
        XCTAssertEqual(logs.first?.reason, "nih")
    }

    func testLoadResultCapturesRegistrationTimeLogs() throws {
        let runtime = try CustomJavaScriptPolicyRuntime()
        let loadResult = try runtime.load(groupID: "g", source: """
        (event, helpers) => {
          helpers.log("registration log");
          event.registerTickEvent("test", (ev, h) => {});
        }
        """)
        XCTAssertEqual(loadResult.handlers, 1)
        XCTAssertTrue(loadResult.decisions.contains(where: { $0.reason == "registration log" }))
    }
}
