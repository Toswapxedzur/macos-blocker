import XCTest
@testable import MacBlockerCore

/// Verifies the Safari native bridge actually boots the verbatim browser
/// engine (helpers.js + event-sandbox.js) in JavaScriptCore and speaks the
/// extension's event-sandbox-request protocol.
final class SafariCustomRuleBridgeTests: XCTestCase {

    func testBridgeBootsAndReportsReady() throws {
        // Construction performs the ready/init handshake; if the engine failed
        // to post "ready", the initializer throws.
        _ = try SafariCustomRuleBridge()
    }

    func testLoadSourceReportsHandlerCount() throws {
        let bridge = try SafariCustomRuleBridge()
        let resultJSON = try bridge.loadSource(
            groupID: "group-1",
            source: """
            (events, helpers) => {
              events.on("tickEvent", "tick-a", (ev, h) => {});
              events.on("webChangedEvent", "web-a", (ev, h) => {});
            }
            """
        )
        let result = try decode(resultJSON)
        XCTAssertEqual(result["ok"] as? Bool, true, "load-source should succeed: \(resultJSON)")
        // event-sandbox.js reports a handler count for the loaded source.
        if let handlers = result["handlers"] as? Int {
            XCTAssertEqual(handlers, 2)
        } else if let handlers = result["handlers"] as? Double {
            XCTAssertEqual(Int(handlers), 2)
        } else {
            XCTFail("expected a numeric handler count, got \(resultJSON)")
        }
    }

    func testCheckSourceRejectsInvalidRule() throws {
        let bridge = try SafariCustomRuleBridge()
        let resultJSON = try bridge.checkSource("this is not a function")
        let result = try decode(resultJSON)
        XCTAssertEqual(result["ok"] as? Bool, false, "invalid source should fail: \(resultJSON)")
    }

    func testDispatchEventReturnsOk() throws {
        let bridge = try SafariCustomRuleBridge()
        _ = try bridge.loadSource(
            groupID: "group-1",
            source: """
            (events, helpers) => {
              events.on("tickEvent", "tick-a", (ev, h) => { h.getLogHelper().log("tick"); });
            }
            """
        )
        let payload = """
        {"kind":"dispatch-event","descriptor":{"type":"tickEvent","url":"https://example.com","hostname":"example.com","time":{},"tabId":1,"pageId":"p1"}}
        """
        let resultJSON = try bridge.handle(payloadJSON: payload)
        let result = try decode(resultJSON)
        XCTAssertEqual(result["ok"] as? Bool, true, "dispatch should succeed: \(resultJSON)")
    }

    private func decode(_ json: String) throws -> [String: Any] {
        let data = Data(json.utf8)
        let object = try JSONSerialization.jsonObject(with: data)
        return (object as? [String: Any]) ?? [:]
    }
}
