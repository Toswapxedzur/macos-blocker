#if os(macOS)
import XCTest
@testable import MacBlockerAppFeature
import MacBlockerCore

final class ExtensionMCPToolsTests: XCTestCase {
    private struct Relayed { let operation: String; let body: [String: Any]; let target: String? }

    private func makeServer(answer: @escaping (String, [String: Any]) -> ExtensionMCPTools.RelayOutcome) -> (MCPServer, () -> [Relayed]) {
        var relayed: [Relayed] = []
        let bridge = ExtensionMCPTools.Bridge { operation, body, target, completion in
            relayed.append(.init(operation: operation, body: body, target: target))
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.01) { completion(answer(operation, body)) }
        }
        return (MCPServer(tools: ExtensionMCPTools.tools(bridge: bridge)), { relayed })
    }

    private func call(_ server: MCPServer, _ name: String, _ arguments: [String: Any]) throws -> (text: String, isError: Bool) {
        let res = try XCTUnwrap(server.handle(["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": name, "arguments": arguments]]))
        let result = try XCTUnwrap(res["result"] as? [String: Any])
        return (try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String), result["isError"] as? Bool ?? false)
    }

    func testAmbiguousBrowserErrorListsTheChoices() {
        let text = ExtensionMCPTools.explain("browser-ambiguous: chrome AAAA, chrome BBBB")
        XCTAssertEqual(text, "more than one browser is connected; pass 'browser' as one of: chrome AAAA, chrome BBBB.")
        XCTAssertEqual(ExtensionMCPTools.explain("browser-unavailable"), "no browser with the Vault extension is connected to Mac Vault.")
    }

    func testToolsAreAdvertised() throws {
        let (server, _) = makeServer { _, _ in .success([:]) }
        let res = try XCTUnwrap(server.handle(["jsonrpc": "2.0", "id": 1, "method": "tools/list"]))
        let names = try XCTUnwrap((res["result"] as? [String: Any])?["tools"] as? [[String: Any]]).compactMap { $0["name"] as? String }
        XCTAssertEqual(Set(names), ["extension_state", "extension_create_group", "extension_set_group", "extension_delete_group", "extension_set_classifier", "extension_set_global",
                                      "extension_lock_group", "extension_unlock_group", "extension_move_group"])
    }

    func testLockToolsRelayTheirOperationsAndExplainTheGates() throws {
        let (server, relayed) = makeServer { _, _ in .failure("pin-wrong:4") }
        let out = try call(server, "extension_unlock_group", ["id": "g1", "pin": "000000"])
        XCTAssertTrue(out.isError)
        XCTAssertTrue(out.text.contains("wrong PIN; the next try waits 4 s."), out.text)
        XCTAssertEqual(relayed().last?.operation, "settings-unlock-group")
        XCTAssertEqual(ExtensionMCPTools.explain("strict-wait:2026-09-27T10:00:00.000Z"), "strict lock: it opens at 2026-09-27T10:00:00.000Z.")
        XCTAssertEqual(ExtensionMCPTools.explain("confirm-wait:3"), "confirm again in 3 s (the popup's confirmation waits 5 s).")
    }

    func testStateRelaysSettingsGetAndReturnsTheBrowserBody() throws {
        let (server, relayed) = makeServer { _, _ in .success(["groups": [["id": "g1", "groupType": "twitter"]]]) }
        let out = try call(server, "extension_state", ["browser": "chrome"])
        XCTAssertFalse(out.isError); XCTAssertTrue(out.text.contains("\"groupType\":\"twitter\""))
        XCTAssertEqual(relayed().first?.operation, "settings-get")
        XCTAssertEqual(relayed().first?.target, "chrome")
    }

    func testCreateAndSetGroupCarryTheirPayloads() throws {
        let (server, relayed) = makeServer { _, body in .success(["group": body]) }
        let created = try call(server, "extension_create_group", ["groupType": "twitter", "patch": ["name": "X tags", "platformTagMode": "include", "platformTags": [["name": "Gaming"]]]])
        XCTAssertFalse(created.isError)
        XCTAssertEqual(relayed()[0].operation, "settings-create-group")
        XCTAssertEqual(relayed()[0].body["groupType"] as? String, "twitter")
        XCTAssertEqual(((relayed()[0].body["patch"] as? [String: Any])?["platformTags"] as? [[String: Any]])?.first?["name"] as? String, "Gaming")
        let patched = try call(server, "extension_set_group", ["id": "g1", "patch": ["enabled": false]])
        XCTAssertFalse(patched.isError)
        XCTAssertEqual(relayed()[1].body["id"] as? String, "g1")
        XCTAssertEqual((relayed()[1].body["patch"] as? [String: Any])?["enabled"] as? Bool, false)
        XCTAssertTrue(try call(server, "extension_set_group", ["id": "g1"]).isError, "patch is required")
        XCTAssertTrue(try call(server, "extension_create_group", [:]).isError, "groupType is required")
    }

    func testBrowserFailuresBecomeReadableErrors() throws {
        let (server, _) = makeServer { operation, _ in
            operation == "settings-delete-group" ? .failure("group-locked") : .failure("browser-unavailable")
        }
        let state = try call(server, "extension_state", [:])
        XCTAssertTrue(state.isError); XCTAssertTrue(state.text.contains("no browser with the Vault extension is connected"))
        let deleted = try call(server, "extension_delete_group", ["id": "g1"])
        XCTAssertTrue(deleted.isError); XCTAssertTrue(deleted.text.contains("frozen, strict or parental-locked"))
    }

    func testSetGlobalRelaysThePatch() throws {
        let (server, relayed) = makeServer { _, body in .success(["globalSettings": body["patch"] ?? [:]]) }
        XCTAssertTrue(try call(server, "extension_set_global", [:]).isError)
        let out = try call(server, "extension_set_global", ["patch": ["debugMode": true]])
        XCTAssertFalse(out.isError)
        XCTAssertEqual((relayed().first?.body["patch"] as? [String: Any])?["debugMode"] as? Bool, true)
    }

    func testSetClassifierRequiresSomethingToSet() throws {
        let (server, relayed) = makeServer { _, body in .success(["classifierSettings": body]) }
        XCTAssertTrue(try call(server, "extension_set_classifier", [:]).isError)
        let out = try call(server, "extension_set_classifier", ["taggingMode": "always"])
        XCTAssertFalse(out.isError)
        XCTAssertEqual(relayed().first?.body["taggingMode"] as? String, "always")
    }

    func testNoReplyTimesOutInsteadOfHanging() throws {
        // A bridge that never calls back: the tool must still return.
        let bridge = ExtensionMCPTools.Bridge { _, _, _, _ in }
        let server = MCPServer(tools: ExtensionMCPTools.tools(bridge: bridge))
        let original = ExtensionMCPTools.waitSeconds
        XCTAssertGreaterThan(original, 30)
        // Exercise the helper directly with a short wait through a stub semaphore path.
        let result = ExtensionMCPTools.relayWithWait(bridge, "settings-get", [:], [:], seconds: 0.05)
        XCTAssertTrue(result.isError); XCTAssertTrue(result.text.contains("did not answer in time"))
        _ = server
    }
}
#endif
