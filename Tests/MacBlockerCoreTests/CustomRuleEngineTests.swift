import XCTest
@testable import MacBlockerCore

/// Exercises the custom-rule engine (timers, persistence, domain classifiers,
/// ev.close/block/unblock/open, unsupported-helper logging) to prove rules execute.
final class CustomRuleEngineTests: XCTestCase {
    func testDomainHelperClassifiesAndBlocks() throws {
        let runtime = try CustomJavaScriptPolicyRuntime()
        try runtime.load(groupID: "g", source: """
        (event, helpers) => {
          event.registerOpenWebEvent("yt", (ev, h) => {
            if (h.getDomainHelper().isYouTubeHost(ev.hostname)) ev.block();
          });
        }
        """)

        let result = try runtime.dispatch(
            CustomRuleEvent(type: "openWebEvent", groupID: "g",
                            hostname: "www.youtube.com",
                            data: ["isBrowser": "true"])
        )
        let blockIntents = result.intents.filter { $0.action == "blockSite" }
        XCTAssertFalse(blockIntents.isEmpty)

        let allowedResult = try runtime.dispatch(
            CustomRuleEvent(type: "openWebEvent", groupID: "g", hostname: "example.com")
        )
        let allowedBlocks = allowedResult.intents.filter { $0.action == "blockSite" || $0.action == "blockApp" }
        XCTAssertTrue(allowedBlocks.isEmpty)
    }

    func testTimerExpiryCloses() throws {
        let runtime = try CustomJavaScriptPolicyRuntime()
        try runtime.load(groupID: "g", source: """
        (event, helpers) => {
          event.registerTickEvent("t", (ev, h) => {
            const tm = h.getTimerHelper();
            tm.getOrCreateTimer({ id: "x", direction: "backward", currentMs: 1000 });
            tm.addMs("x", -1000);
            if (tm.isExpired("x")) ev.close("com.example.app");
          });
        }
        """)

        let result = try runtime.dispatch(CustomRuleEvent(type: "tickEvent", groupID: "g"))
        let closeIntents = result.intents.filter { $0.action == "close" }
        XCTAssertEqual(closeIntents.count, 1)
        XCTAssertEqual(closeIntents.first?.target, "com.example.app")
    }

    func testPersistenceCountsAcrossDispatches() throws {
        let runtime = try CustomJavaScriptPolicyRuntime()
        try runtime.load(groupID: "g", source: """
        (event, helpers) => {
          event.registerWebChangedEvent("count", (ev, h) => {
            const p = h.getPersistenceHelper();
            const n = (p.get("n", 0)) + 1;
            p.set("n", n);
            if (n >= 3) ev.block("example.com");
          });
        }
        """)

        XCTAssertTrue(try runtime.dispatch(CustomRuleEvent(type: "webChangedEvent", groupID: "g")).intents.filter { $0.action == "blockSite" }.isEmpty)
        XCTAssertTrue(try runtime.dispatch(CustomRuleEvent(type: "webChangedEvent", groupID: "g")).intents.filter { $0.action == "blockSite" }.isEmpty)
        let third = try runtime.dispatch(CustomRuleEvent(type: "webChangedEvent", groupID: "g"))
        let blockIntents = third.intents.filter { $0.action == "blockSite" }
        XCTAssertEqual(blockIntents.count, 1)
    }

    func testRedirectIsRemovedButSetResultStillBlocks() throws {
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

    func testPlatformClassifierBlocks() throws {
        let runtime = try CustomJavaScriptPolicyRuntime()
        try runtime.load(groupID: "g", source: """
        (event, helpers) => {
          event.registerOpenWebEvent("shorts", (ev, h) => {
            const yt = h.getPlatformHelper().youtube();
            if (yt.isShortUrl(ev.url)) ev.block("youtube.com");
          }, { priority: 5 });
        }
        """)

        let result = try runtime.dispatch(
            CustomRuleEvent(type: "openWebEvent", groupID: "g", url: "https://youtube.com/shorts/abc123")
        )
        let blockIntents = result.intents.filter { $0.action == "blockSite" }
        XCTAssertFalse(blockIntents.isEmpty)
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
            h.log("timer expired: " + ev.data.timerId);
          });
        }
        """)

        let result = try runtime.dispatch(CustomRuleEvent(type: "tickEvent", groupID: "g"))
        let logDecisions = result.decisions.filter { $0.action == .log && $0.reason.contains("countdown") }
        XCTAssertEqual(logDecisions.count, 1)
    }

    func testWorkHoursTickRuleBlocks() throws {
        let runtime = try CustomJavaScriptPolicyRuntime()
        try runtime.load(groupID: "g", source: """
        (events, helpers) => {
            events.registerTickEvent("work-hours", (ev, h) => {
              const hour = new Date(ev.time.now).getHours();
              if (hour >= 9 && hour < 17) {
                ev.close();
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

        let result = try runtime.dispatch(
            CustomRuleEvent(type: "tickEvent", groupID: "g", now: workTime,
                            data: ["appId": "com.example.app"])
        )
        let closeIntents = result.intents.filter { $0.action == "close" }
        XCTAssertFalse(closeIntents.isEmpty)

        components.hour = 20
        let eveningTime = cal.date(from: components)!
        let eveningResult = try runtime.dispatch(
            CustomRuleEvent(type: "tickEvent", groupID: "g", now: eveningTime,
                            data: ["appId": "com.example.app"])
        )
        let eveningCloseIntents = eveningResult.intents.filter { $0.action == "close" }
        XCTAssertTrue(eveningCloseIntents.isEmpty)
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

    // MARK: - ev.close / ev.block / ev.unblock / ev.open

    func testEvCloseNoArgClosesFocused() throws {
        let runtime = try CustomJavaScriptPolicyRuntime()
        try runtime.load(groupID: "g", source: """
        (event, helpers) => {
          event.registerTickEvent("close-focused", (ev, h) => {
            ev.close();
          });
        }
        """)

        let result = try runtime.dispatch(
            CustomRuleEvent(type: "tickEvent", groupID: "g",
                            data: ["appId": "com.example.app"])
        )
        let closeIntents = result.intents.filter { $0.action == "close" }
        XCTAssertEqual(closeIntents.count, 1)
        XCTAssertEqual(closeIntents.first?.target, "com.example.app")
    }

    func testEvCloseWithIdClosesSpecific() throws {
        let runtime = try CustomJavaScriptPolicyRuntime()
        try runtime.load(groupID: "g", source: """
        (event, helpers) => {
          event.registerTickEvent("close-specific", (ev, h) => {
            ev.close("com.apple.calculator");
          });
        }
        """)

        let result = try runtime.dispatch(CustomRuleEvent(type: "tickEvent", groupID: "g"))
        let closeIntents = result.intents.filter { $0.action == "close" }
        XCTAssertEqual(closeIntents.count, 1)
        XCTAssertEqual(closeIntents.first?.target, "com.apple.calculator")
    }

    func testEvBlockNoArgBlocksFocusedBrowser() throws {
        let runtime = try CustomJavaScriptPolicyRuntime()
        try runtime.load(groupID: "g", source: """
        (event, helpers) => {
          event.registerTickEvent("block-focused", (ev, h) => {
            ev.block();
          });
        }
        """)

        let result = try runtime.dispatch(
            CustomRuleEvent(type: "tickEvent", groupID: "g",
                            hostname: "youtube.com",
                            data: ["isBrowser": "true", "appId": "com.google.Chrome"])
        )
        let siteBlocks = result.intents.filter { $0.action == "blockSite" }
        XCTAssertEqual(siteBlocks.count, 1)
        XCTAssertEqual(siteBlocks.first?.pattern, "youtube.com")
    }

    func testEvBlockWithIdBlocksSpecific() throws {
        let runtime = try CustomJavaScriptPolicyRuntime()
        try runtime.load(groupID: "g", source: """
        (event, helpers) => {
          event.registerTickEvent("block-specific", (ev, h) => {
            ev.block("reddit.com");
          });
        }
        """)

        let result = try runtime.dispatch(CustomRuleEvent(type: "tickEvent", groupID: "g"))
        let blockIntents = result.intents.filter { $0.action == "blockSite" }
        XCTAssertEqual(blockIntents.count, 1)
        XCTAssertEqual(blockIntents.first?.pattern, "reddit.com")
    }

    func testEvUnblock() throws {
        let runtime = try CustomJavaScriptPolicyRuntime()
        try runtime.load(groupID: "g", source: """
        (event, helpers) => {
          event.registerTickEvent("unblock", (ev, h) => {
            ev.unblock("youtube.com");
          });
        }
        """)

        let result = try runtime.dispatch(CustomRuleEvent(type: "tickEvent", groupID: "g"))
        let unblockIntents = result.intents.filter { $0.action == "unblockSite" }
        XCTAssertEqual(unblockIntents.count, 1)
        XCTAssertEqual(unblockIntents.first?.pattern, "youtube.com")
    }

    func testEvOpen() throws {
        let runtime = try CustomJavaScriptPolicyRuntime()
        try runtime.load(groupID: "g", source: """
        (event, helpers) => {
          event.registerTickEvent("open-app", (ev, h) => {
            ev.open("com.apple.calculator");
          });
        }
        """)

        let result = try runtime.dispatch(CustomRuleEvent(type: "tickEvent", groupID: "g"))
        let openIntents = result.intents.filter { $0.action == "openApp" }
        XCTAssertEqual(openIntents.count, 1)
        XCTAssertEqual(openIntents.first?.target, "com.apple.calculator")
    }

    func testEvOpenNoArgIsNoop() throws {
        let runtime = try CustomJavaScriptPolicyRuntime()
        try runtime.load(groupID: "g", source: """
        (event, helpers) => {
          event.registerTickEvent("open-noop", (ev, h) => {
            ev.open();
          });
        }
        """)

        let result = try runtime.dispatch(CustomRuleEvent(type: "tickEvent", groupID: "g"))
        let openIntents = result.intents.filter { $0.action == "openApp" }
        XCTAssertTrue(openIntents.isEmpty)
    }

    // MARK: - Per-group log independence

    func testUnsupportedHelperLogIsPerGroup() throws {
        let runtime = try CustomJavaScriptPolicyRuntime()
        let source = """
        (event, helpers) => {
          event.registerTickEvent("a", (ev, h) => {
            h.getDOMHelper().hide(".x");
          });
        }
        """
        try runtime.load(groupID: "g1", source: source)
        try runtime.load(groupID: "g2", source: source)

        let r1 = try runtime.dispatch(CustomRuleEvent(type: "tickEvent", groupID: "g1"))
        let r2 = try runtime.dispatch(CustomRuleEvent(type: "tickEvent", groupID: "g2"))

        XCTAssertEqual(r1.decisions.filter { $0.reason.contains("getDOMHelper") }.count, 1,
                       "g1 should emit its own unsupported-helper warning")
        XCTAssertEqual(r2.decisions.filter { $0.reason.contains("getDOMHelper") }.count, 1,
                       "g2 should emit its own warning independently of g1")
    }

    func testUnsupportedHelperLogPersistsAcrossDispatches() throws {
        let runtime = try CustomJavaScriptPolicyRuntime()
        try runtime.load(groupID: "g", source: """
        (event, helpers) => {
          event.registerTickEvent("a", (ev, h) => {
            h.getDOMHelper().hide(".x");
          });
        }
        """)

        let first = try runtime.dispatch(CustomRuleEvent(type: "tickEvent", groupID: "g"))
        XCTAssertEqual(first.decisions.filter { $0.reason.contains("getDOMHelper") }.count, 1)

        let second = try runtime.dispatch(CustomRuleEvent(type: "tickEvent", groupID: "g"))
        XCTAssertEqual(second.decisions.filter { $0.reason.contains("getDOMHelper") }.count, 0,
                       "Same warning should not repeat on subsequent dispatch")
    }

    func testUnsupportedHelperLogResetsOnUnloadReload() throws {
        let runtime = try CustomJavaScriptPolicyRuntime()
        let source = """
        (event, helpers) => {
          event.registerTickEvent("a", (ev, h) => {
            h.getDOMHelper().hide(".x");
          });
        }
        """
        try runtime.load(groupID: "g", source: source)
        _ = try runtime.dispatch(CustomRuleEvent(type: "tickEvent", groupID: "g"))

        runtime.unload(groupID: "g")
        try runtime.load(groupID: "g", source: source)

        let afterReload = try runtime.dispatch(CustomRuleEvent(type: "tickEvent", groupID: "g"))
        XCTAssertEqual(afterReload.decisions.filter { $0.reason.contains("getDOMHelper") }.count, 1,
                       "After unload+reload, warning should appear again")
    }

    func testUnknownHelperLogIsPerGroup() throws {
        let runtime = try CustomJavaScriptPolicyRuntime()
        let source = """
        (event, helpers) => {
          event.registerTickEvent("a", (ev, h) => {
            h.getFooBarHelper().doSomething();
          });
        }
        """
        try runtime.load(groupID: "g1", source: source)
        try runtime.load(groupID: "g2", source: source)

        let r1 = try runtime.dispatch(CustomRuleEvent(type: "tickEvent", groupID: "g1"))
        let r2 = try runtime.dispatch(CustomRuleEvent(type: "tickEvent", groupID: "g2"))
        let r1b = try runtime.dispatch(CustomRuleEvent(type: "tickEvent", groupID: "g1"))

        XCTAssertEqual(r1.decisions.filter { $0.reason.contains("does not exist") }.count, 1)
        XCTAssertEqual(r2.decisions.filter { $0.reason.contains("does not exist") }.count, 1,
                       "g2 should get its own warning independently")
        XCTAssertEqual(r1b.decisions.filter { $0.reason.contains("does not exist") }.count, 0,
                       "g1's second dispatch should not repeat the warning")
    }

    // MARK: - No auto-reload on source change

    func testUnloadThenReloadAppliesNewSource() throws {
        let runtime = try CustomJavaScriptPolicyRuntime()
        try runtime.load(groupID: "g", source: """
        (event, helpers) => {
          event.registerTickEvent("v1", (ev, h) => { h.log("old"); });
        }
        """)
        let old = try runtime.dispatch(CustomRuleEvent(type: "tickEvent", groupID: "g"))
        XCTAssertTrue(old.decisions.contains(where: { $0.reason == "old" }))

        runtime.unload(groupID: "g")
        try runtime.load(groupID: "g", source: """
        (event, helpers) => {
          event.registerTickEvent("v2", (ev, h) => { h.log("new"); });
        }
        """)
        let updated = try runtime.dispatch(CustomRuleEvent(type: "tickEvent", groupID: "g"))
        XCTAssertTrue(updated.decisions.contains(where: { $0.reason == "new" }))
        XCTAssertFalse(updated.decisions.contains(where: { $0.reason == "old" }))
    }

    // MARK: - Timer auto-ticking

    func testTimerAutoTicksOnTickEvent() throws {
        let runtime = try CustomJavaScriptPolicyRuntime()
        try runtime.load(groupID: "g", source: """
        (event, helpers) => {
          event.registerTickEvent("setup", (ev, h) => {
            h.getTimerHelper().getOrCreateTimer({
              id: "t", direction: "backward", currentMs: 5000
            });
          });
        }
        """)

        // First dispatch creates the timer (auto-tick runs before handler,
        // so the timer doesn't exist yet — no tick on this round).
        let r0 = try runtime.dispatch(
            CustomRuleEvent(type: "tickEvent", groupID: "g", data: ["intervalMs": "1000"])
        )
        let t0 = r0.timers.first { $0.id == "t" }
        XCTAssertNotNil(t0)
        XCTAssertEqual(t0!.currentMs, 5000, accuracy: 1)

        // Second dispatch: auto-tick decrements 5000 → 4000, then handler
        // getOrCreate is a no-op (already exists).
        let r1 = try runtime.dispatch(
            CustomRuleEvent(type: "tickEvent", groupID: "g", data: ["intervalMs": "1000"])
        )
        let t1 = r1.timers.first { $0.id == "t" }
        XCTAssertEqual(t1!.currentMs, 4000, accuracy: 1)

        // Third dispatch: 4000 → 3000.
        let r2 = try runtime.dispatch(
            CustomRuleEvent(type: "tickEvent", groupID: "g", data: ["intervalMs": "1000"])
        )
        let t2 = r2.timers.first { $0.id == "t" }
        XCTAssertEqual(t2!.currentMs, 3000, accuracy: 1)
    }

    func testPausedTimerDoesNotAutoTick() throws {
        let runtime = try CustomJavaScriptPolicyRuntime()
        try runtime.load(groupID: "g", source: """
        (event, helpers) => {
          event.registerTickEvent("setup", (ev, h) => {
            const tm = h.getTimerHelper();
            tm.getOrCreateTimer({ id: "t", direction: "backward", currentMs: 5000 });
            tm.pause("t");
          });
        }
        """)

        let r1 = try runtime.dispatch(
            CustomRuleEvent(type: "tickEvent", groupID: "g", data: ["intervalMs": "1000"])
        )
        let r2 = try runtime.dispatch(
            CustomRuleEvent(type: "tickEvent", groupID: "g", data: ["intervalMs": "1000"])
        )
        let t1 = r1.timers.first { $0.id == "t" }
        let t2 = r2.timers.first { $0.id == "t" }
        XCTAssertTrue(t1?.isPaused ?? false)
        XCTAssertEqual(t1?.currentMs, t2?.currentMs,
                       "Paused timer should not auto-decrement")
    }

    func testForwardTimerDoesNotAutoTick() throws {
        let runtime = try CustomJavaScriptPolicyRuntime()
        try runtime.load(groupID: "g", source: """
        (event, helpers) => {
          event.registerTickEvent("setup", (ev, h) => {
            h.getTimerHelper().getOrCreateTimer({
              id: "t", direction: "forward", currentMs: 0
            });
          });
        }
        """)

        _ = try runtime.dispatch(
            CustomRuleEvent(type: "tickEvent", groupID: "g", data: ["intervalMs": "1000"])
        )
        let r2 = try runtime.dispatch(
            CustomRuleEvent(type: "tickEvent", groupID: "g", data: ["intervalMs": "1000"])
        )
        let t = r2.timers.first { $0.id == "t" }
        XCTAssertNotNil(t)
        XCTAssertEqual(t!.currentMs, 0, accuracy: 1,
                       "Forward timer should not auto-tick")
    }

    func testAutoTickToZeroFiresTimerEndedOnce() throws {
        let runtime = try CustomJavaScriptPolicyRuntime()
        try runtime.load(groupID: "g", source: """
        (event, helpers) => {
          event.registerTickEvent("setup", (ev, h) => {
            h.getTimerHelper().getOrCreateTimer({
              id: "t", direction: "backward", currentMs: 3000
            });
          });
          event.registerTimerEndedEvent("ended", (ev, h) => {
            h.log("expired:" + ev.data.timerId);
          });
        }
        """)

        // Dispatch 1: creates timer at 3000 (auto-tick is no-op, timer didn't exist)
        let r0 = try runtime.dispatch(
            CustomRuleEvent(type: "tickEvent", groupID: "g", data: ["intervalMs": "1000"])
        )
        XCTAssertFalse(r0.decisions.contains(where: { $0.reason.contains("expired:t") }))

        // Dispatch 2: auto-tick 3000→2000, not expired yet
        let r1 = try runtime.dispatch(
            CustomRuleEvent(type: "tickEvent", groupID: "g", data: ["intervalMs": "1000"])
        )
        XCTAssertFalse(r1.decisions.contains(where: { $0.reason.contains("expired:t") }),
                       "Timer at 2000ms should not fire timerEnded yet")

        // Dispatch 3: auto-tick 2000→1000, not expired yet
        let r2 = try runtime.dispatch(
            CustomRuleEvent(type: "tickEvent", groupID: "g", data: ["intervalMs": "1000"])
        )
        XCTAssertFalse(r2.decisions.contains(where: { $0.reason.contains("expired:t") }),
                       "Timer at 1000ms should not fire timerEnded yet")

        // Dispatch 4: auto-tick 1000→0, timerEnded fires!
        let r3 = try runtime.dispatch(
            CustomRuleEvent(type: "tickEvent", groupID: "g", data: ["intervalMs": "1000"])
        )
        XCTAssertEqual(r3.decisions.filter { $0.reason.contains("expired:t") }.count, 1,
                       "timerEnded should fire exactly once when auto-tick reaches 0")

        // Dispatch 5: already expired, should NOT re-fire
        let r4 = try runtime.dispatch(
            CustomRuleEvent(type: "tickEvent", groupID: "g", data: ["intervalMs": "1000"])
        )
        XCTAssertEqual(r4.decisions.filter { $0.reason.contains("expired:t") }.count, 0,
                       "timerEnded should not re-fire on subsequent ticks")
    }

    func testNonTickEventDoesNotAutoTick() throws {
        let runtime = try CustomJavaScriptPolicyRuntime()
        try runtime.load(groupID: "g", source: """
        (event, helpers) => {
          event.registerTickEvent("setup", (ev, h) => {
            h.getTimerHelper().getOrCreateTimer({
              id: "t", direction: "backward", currentMs: 5000
            });
          });
          event.registerWebChangedEvent("noop", (ev, h) => {});
        }
        """)

        // Create the timer (5000ms)
        _ = try runtime.dispatch(
            CustomRuleEvent(type: "tickEvent", groupID: "g", data: ["intervalMs": "1000"])
        )
        // Tick once to bring it down to 4000ms
        _ = try runtime.dispatch(
            CustomRuleEvent(type: "tickEvent", groupID: "g", data: ["intervalMs": "1000"])
        )
        // webChangedEvent should NOT further decrement
        let r = try runtime.dispatch(
            CustomRuleEvent(type: "webChangedEvent", groupID: "g", data: ["intervalMs": "1000"])
        )
        let t = r.timers.first { $0.id == "t" }
        XCTAssertNotNil(t)
        XCTAssertEqual(t!.currentMs, 4000, accuracy: 1,
                       "Non-tickEvent should not auto-decrement the timer")
    }

    // MARK: - Log surface metadata (popup / screen / all)

    func testLogPopupHasSurfacePopup() throws {
        let runtime = try CustomJavaScriptPolicyRuntime()
        try runtime.load(groupID: "g", source: """
        (event, helpers) => {
          event.registerTickEvent("p", (ev, h) => { h.logPopup("hello popup"); });
        }
        """)

        let result = try runtime.dispatch(CustomRuleEvent(type: "tickEvent", groupID: "g"))
        let logs = result.decisions.filter { $0.action == .log }
        XCTAssertEqual(logs.count, 1)
        XCTAssertEqual(logs.first?.reason, "hello popup")
        XCTAssertEqual(logs.first?.metadata["surface"], "popup")
        XCTAssertEqual(logs.first?.metadata["level"], "log")
    }

    func testWarnPopupHasSurfacePopup() throws {
        let runtime = try CustomJavaScriptPolicyRuntime()
        try runtime.load(groupID: "g", source: """
        (event, helpers) => {
          event.registerTickEvent("wp", (ev, h) => { h.warnPopup("warn msg"); });
        }
        """)

        let result = try runtime.dispatch(CustomRuleEvent(type: "tickEvent", groupID: "g"))
        let logs = result.decisions.filter { $0.action == .log }
        XCTAssertEqual(logs.first?.metadata["level"], "warn")
        XCTAssertEqual(logs.first?.metadata["surface"], "popup")
    }

    func testErrorPopupHasSurfacePopup() throws {
        let runtime = try CustomJavaScriptPolicyRuntime()
        try runtime.load(groupID: "g", source: """
        (event, helpers) => {
          event.registerTickEvent("ep", (ev, h) => { h.errorPopup("bad thing"); });
        }
        """)

        let result = try runtime.dispatch(CustomRuleEvent(type: "tickEvent", groupID: "g"))
        let logs = result.decisions.filter { $0.action == .log }
        XCTAssertEqual(logs.first?.metadata["level"], "error")
        XCTAssertEqual(logs.first?.metadata["surface"], "popup")
    }

    func testLogScreenHasSurfaceScreen() throws {
        let runtime = try CustomJavaScriptPolicyRuntime()
        try runtime.load(groupID: "g", source: """
        (event, helpers) => {
          event.registerTickEvent("sc", (ev, h) => { h.logScreen("screen msg"); });
        }
        """)

        let result = try runtime.dispatch(CustomRuleEvent(type: "tickEvent", groupID: "g"))
        let logs = result.decisions.filter { $0.action == .log }
        XCTAssertEqual(logs.first?.metadata["surface"], "screen")
    }

    func testPlainLogHasSurfaceAll() throws {
        let runtime = try CustomJavaScriptPolicyRuntime()
        try runtime.load(groupID: "g", source: """
        (event, helpers) => {
          event.registerTickEvent("plain", (ev, h) => { h.log("both surfaces"); });
        }
        """)

        let result = try runtime.dispatch(CustomRuleEvent(type: "tickEvent", groupID: "g"))
        let logs = result.decisions.filter { $0.action == .log }
        XCTAssertEqual(logs.first?.metadata["surface"], "all")
    }

    func testLogHelperSurfaceVariants() throws {
        let runtime = try CustomJavaScriptPolicyRuntime()
        try runtime.load(groupID: "g", source: """
        (event, helpers) => {
          event.registerTickEvent("lh", (ev, h) => {
            const lg = h.getLogHelper();
            lg.logPopup("lp");
            lg.warnScreen("ws");
            lg.errorPopup("ep");
            lg.log("plain");
          });
        }
        """)

        let result = try runtime.dispatch(CustomRuleEvent(type: "tickEvent", groupID: "g"))
        let logs = result.decisions.filter { $0.action == .log }
        XCTAssertEqual(logs.count, 4)

        let lp = logs.first { $0.reason == "lp" }
        XCTAssertEqual(lp?.metadata["level"], "log")
        XCTAssertEqual(lp?.metadata["surface"], "popup")

        let ws = logs.first { $0.reason == "ws" }
        XCTAssertEqual(ws?.metadata["level"], "warn")
        XCTAssertEqual(ws?.metadata["surface"], "screen")

        let ep = logs.first { $0.reason == "ep" }
        XCTAssertEqual(ep?.metadata["level"], "error")
        XCTAssertEqual(ep?.metadata["surface"], "popup")

        let plain = logs.first { $0.reason == "plain" }
        XCTAssertEqual(plain?.metadata["level"], "log")
        XCTAssertEqual(plain?.metadata["surface"], "all")
    }
}
