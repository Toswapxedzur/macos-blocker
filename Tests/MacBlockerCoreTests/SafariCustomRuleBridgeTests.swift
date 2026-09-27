import XCTest
@testable import MacBlockerCore

/// Verifies the Safari native bridge boots the browser's engine
/// (rule-core.js + event-sandbox.js) in JavaScriptCore and speaks the
/// extension's event-sandbox-request protocol.
final class SafariCustomRuleBridgeTests: XCTestCase {

    func testBridgeBootsAndReportsReady() throws {
        // If the engine failed to post "ready", the initializer throws.
        _ = try SafariCustomRuleBridge()
    }

    func testLoadSourceReportsHandlersAndTypes() throws {
        let bridge = try SafariCustomRuleBridge()
        let result = try decode(bridge.loadSource(
            groupID: "group-1",
            source: """
            (on, v) => {
              on("tick", () => {});
              on("tab", () => {});
            }
            """
        ))
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual((result["handlers"] as? NSNumber)?.intValue, 2)
        XCTAssertEqual(Set(result["types"] as? [String] ?? []), ["tick", "tab"])
    }

    func testLoadSourceRejectsANonFunction() throws {
        let bridge = try SafariCustomRuleBridge()
        let result = try decode(bridge.loadSource(groupID: "group-1", source: "42"))
        XCTAssertEqual(result["ok"] as? Bool, false)
    }

    func testDispatchReturnsTheBrowsersActions() throws {
        let bridge = try SafariCustomRuleBridge()
        _ = try bridge.loadSource(
            groupID: "group-1",
            source: """
            (on, v) => {
              on("tab", (ev) => { v.cover(ev.data.tabId, true, "no"); v.log("seen"); });
            }
            """
        )
        let payload = """
        {"kind":"dispatch-event","descriptor":{"type":"tab","now":1,"data":{"kind":"navigate","tabId":4,"url":"https://example.com/"}}}
        """
        let result = try decode(bridge.handle(payloadJSON: payload))
        XCTAssertEqual(result["ok"] as? Bool, true)
        let actions = result["actions"] as? [[String: Any]] ?? []
        XCTAssertEqual(actions.first?["kind"] as? String, "cover")
        XCTAssertEqual((actions.first?["tabId"] as? NSNumber)?.intValue, 4)
        XCTAssertEqual((result["logs"] as? [[String: Any]])?.count, 1)
    }

    private func decode(_ json: String) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        return (object as? [String: Any]) ?? [:]
    }
}
