import XCTest
@testable import MacBlockerCore

/// Mac Vault's custom-rule engine: rule-core.js with Mac Vault's own actions
/// (apps only) in JavaScriptCore.
final class RuleRuntimeTests: XCTestCase {
    func testHandlerErrorsAreDiagnosticsAndOnlyVLogProducesLogOutput() throws {
        let runtime = try RuleRuntime()
        _ = try runtime.load(groupID: "a", source: #"(on,v) => { on("tick", () => { throw Error("test failure"); }); }"#, stateJSON: "{}")
        let failed = try runtime.dispatch(type: "tick", data: [String: Any](), groupID: "a")
        XCTAssertTrue(failed.logs.isEmpty)
        XCTAssertEqual(failed.diagnostics.first?.groupId, "a")
        XCTAssertTrue(failed.diagnostics.first?.message.contains("test failure") == true)
        _ = try runtime.load(groupID: "b", source: #"(on,v) => { on("tick", () => v.log("B output")); }"#, stateJSON: "{}")
        let logged = try runtime.dispatch(type: "tick", data: [String: Any](), groupID: "b")
        XCTAssertEqual(logged.logs.first?.groupId, "b")
        XCTAssertEqual(logged.logs.first?.message, "B output")
        XCTAssertTrue(logged.diagnostics.isEmpty)
    }

    func testRegistrationExportsStateAndCallsCommitOnceBeforeReplacingHandlers() throws {
        let runtime = try RuleRuntime()
        var commits = [[String: String]]()
        let loaded = try runtime.load(groupID: "g", source: #"(on,v)=>{v.state.n=(v.state.n||0)+1;}"#, stateJSON: "{}") { states in commits.append(states) }
        XCTAssertTrue(loaded.ok)
        XCTAssertEqual(loaded.states["g"], #"{"n":1}"#)
        XCTAssertEqual(commits, [loaded.states])
    }

    func testFailedCommitLeavesPreviousHandlersAndStateInMemory() throws {
        let runtime = try RuleRuntime()
        _ = try runtime.load(groupID: "g", source: #"(on,v)=>{on("tick",()=>{v.state.n=(v.state.n||0)+1;});}"#, stateJSON: #"{"n":4}"#)
        let rejected = try runtime.load(groupID: "g", source: #"(on,v)=>{v.state.n=999;on("tick",()=>{v.state.n=999;});}"#, stateJSON: "{}") { _ in throw RuleRuntime.RuleRuntimeError.failed("fixture write failure") }
        XCTAssertFalse(rejected.ok)
        XCTAssertTrue(rejected.states.isEmpty)
        XCTAssertEqual(try runtime.dispatch(type:"tick",data:[String:Any](),groupID:"g").states["g"], #"{"n":5}"#)
    }

    func testALoadedRuleReportsItsHandlersTypesAndLogs() throws {
        let runtime = try RuleRuntime()
        let result = try runtime.load(groupID: "g", source: """
        (on, v) => { on("tick", () => {}); on("app", () => {}); v.log("ready", { n: 1 }); }
        """, stateJSON: "{}")
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.handlers, 2)
        XCTAssertEqual(Set(result.types), ["tick", "app"])
        XCTAssertEqual(result.logs.first?.message, #"ready {"n":1}"#)
    }

    func testTheRuleActsOnAppsOnly() throws {
        let runtime = try RuleRuntime()
        _ = try runtime.load(groupID: "g", source: """
        (on, v) => {
          on("app", (ev) => {
            if (ev.data.kind === "focus" && ev.data.appId === "com.example.Game") { v.block(ev.data.appId, true); v.quit("com.example.Chat"); v.open("com.example.Notes"); }
          });
        }
        """, stateJSON: "{}")
        let result = try runtime.dispatch(type: "app", data: ["kind": "focus", "appId": "com.example.Game", "name": "Game"], groupID: "g")
        XCTAssertEqual(result.actions.map(\.kind), ["block", "quit", "open"])
        XCTAssertEqual(result.actions.first?.appId, "com.example.Game")
        XCTAssertEqual(result.actions.first?.on, true)

        // The browser's actions don't exist here: a rule using them doesn't load.
        let browser = try runtime.load(groupID: "b", source: #"(on, v) => { v.cover(1, true); }"#, stateJSON: "{}")
        XCTAssertFalse(browser.ok)
    }

    func testStateIsKeptAndReportedWhenItChanges() throws {
        let runtime = try RuleRuntime()
        _ = try runtime.load(groupID: "g", source: #"(on, v) => { on("tick", () => { v.state.n = (v.state.n || 0) + 1; }); }"#, stateJSON: #"{"n":4}"#)
        let result = try runtime.dispatch(type: "tick", data: [String: Any](), groupID: "g")
        XCTAssertEqual(result.states["g"], #"{"n":5}"#)
    }

    func testAFileRequestCarriesItsPayloadAsText() throws {
        let runtime = try RuleRuntime()
        _ = try runtime.load(groupID: "g", source: #"(on, v) => { on("tick", () => { v.file("write", "a.json", { x: 1 }); }); }"#, stateJSON: "{}")
        let action = try runtime.dispatch(type: "tick", data: [String: Any](), groupID: "g").actions.first
        XCTAssertEqual(action?.kind, "file")
        XCTAssertEqual(action?.payload, #"{"x":1}"#)
        XCTAssertEqual(action?.requestId, "g:1")
    }

    func testOldPanelColorsDecodeSafelyAndAreNotReencoded() throws {
        let data = Data(##"{"id":"p","groupId":"g","theme":{"background":"#000000","accent":"#ff0000"},"controls":[]}"##.utf8)
        let panel = try JSONDecoder().decode(PanelSnapshot.self, from: data)
        XCTAssertEqual(panel.id, "p")
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(panel)) as? [String: Any]
        XCTAssertNil(encoded?["theme"])
    }

    func testPanelsComeWithTheLoadAndChangesAfter() throws {
        let runtime = try RuleRuntime()
        let loaded = try runtime.load(groupID: "g", source: """
        (on, v) => {
          v.panel("p", { title: "Focus", controls: [{ id: "b", type: "button", label: "Done" }] });
          on("panel", (ev) => { if (ev.data.controlId === "b") v.panel("p", null); });
        }
        """, stateJSON: "{}")
        XCTAssertEqual(loaded.panels?.first?.title, "Focus")
        let result = try runtime.dispatch(type: "panel", data: ["panelId": "p", "controlId": "b", "eventName": "click", "value": "", "values": [String: Any]()], groupID: "g")
        XCTAssertEqual(result.panels["g"], [])
    }

    func testARuleThatFailsToLoadLeavesTheOldOne() throws {
        let runtime = try RuleRuntime()
        _ = try runtime.load(groupID: "g", source: #"(on, v) => { on("tick", () => v.log("old")); }"#, stateJSON: "{}")
        let failed = try runtime.load(groupID: "g", source: "(on, v) => {", stateJSON: "{}")
        XCTAssertFalse(failed.ok)
        let result = try runtime.dispatch(type: "tick", data: [String: Any](), groupID: "g")
        XCTAssertEqual(result.logs.map(\.message), ["old"])
    }

    func testAHungRuleIsCutOffAndTheEngineRecovers() throws {
        let runtime = try RuleRuntime()
        XCTAssertThrowsError(try runtime.load(groupID: "hang", source: "(on) => { while (true) {} }", stateJSON: "{}")) { error in
            XCTAssertEqual(error as? RuleRuntime.RuleRuntimeError, .terminated)
        }
        _ = try runtime.load(groupID: "loop", source: #"(on) => { on("tick", () => { while (true) {} }); }"#, stateJSON: "{}")
        XCTAssertThrowsError(try runtime.dispatch(type: "tick", data: [String: Any](), groupID: "loop")) { error in
            XCTAssertEqual(error as? RuleRuntime.RuleRuntimeError, .terminated)
        }
        runtime.unload(groupID: "loop")
        let fine = try runtime.load(groupID: "fine", source: #"(on, v) => { v.log("ok"); }"#, stateJSON: "{}")
        XCTAssertTrue(fine.ok)
    }

    func testADisabledGroupsRuleHearsNothingAndResumesAsItWas() throws {
        let runtime = try RuleRuntime()
        _ = try runtime.load(groupID: "g", source: #"(on, v) => { on("tick", () => { v.state.n = (v.state.n || 0) + 1; }); }"#, stateJSON: "{}")
        XCTAssertEqual(try runtime.dispatch(type: "tick", data: [String: Any](), groupID: "g").states["g"], #"{"n":1}"#)
        runtime.suppress(groupID: "g", true)
        XCTAssertTrue(try runtime.dispatch(type: "tick", data: [String: Any](), groupID: "g").states.isEmpty, "suppressed: no handler runs")
        runtime.suppress(groupID: "g", false)
        XCTAssertEqual(try runtime.dispatch(type: "tick", data: [String: Any](), groupID: "g").states["g"], #"{"n":2}"#, "resumed as it was")
    }

    func testTheEventGoesToTheNamedGroupOnly() throws {
        let runtime = try RuleRuntime()
        _ = try runtime.load(groupID: "a", source: #"(on, v) => { on("tick", () => v.log("a")); }"#, stateJSON: "{}")
        _ = try runtime.load(groupID: "b", source: #"(on, v) => { on("tick", () => v.log("b")); }"#, stateJSON: "{}")
        XCTAssertEqual(try runtime.dispatch(type: "tick", data: [String: Any](), groupID: "b").logs.map(\.message), ["b"])
    }
}
