#if os(macOS)
import XCTest
@testable import MacBlockerCore

final class MCPServerTests: XCTestCase {
    private func server(tools: [MCPTool] = []) -> MCPServer {
        MCPServer(serverName: "Vault", serverVersion: "1.2.3", tools: tools)
    }

    // MARK: JSON-RPC / MCP protocol

    func testInitializeEchoesProtocolVersionAndServerInfo() throws {
        let res = try XCTUnwrap(server().handle([
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": "2025-06-18"],
        ]))
        XCTAssertEqual(res["id"] as? Int, 1)
        let result = try XCTUnwrap(res["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-06-18")
        XCTAssertEqual((result["serverInfo"] as? [String: Any])?["name"] as? String, "Vault")
        XCTAssertNotNil(result["capabilities"])
    }

    func testNotificationProducesNoResponse() {
        XCTAssertNil(server().handle(["jsonrpc": "2.0", "method": "notifications/initialized"]))
    }

    func testPingReturnsEmptyResult() throws {
        let res = try XCTUnwrap(server().handle(["jsonrpc": "2.0", "id": "a", "method": "ping"]))
        XCTAssertEqual(res["id"] as? String, "a")
        XCTAssertNotNil(res["result"])
    }

    func testUnknownMethodIsMethodNotFound() throws {
        let res = try XCTUnwrap(server().handle(["jsonrpc": "2.0", "id": 2, "method": "bogus"]))
        XCTAssertEqual((res["error"] as? [String: Any])?["code"] as? Int, -32601)
    }

    func testRequestWithoutMethodIsInvalidRequest() throws {
        let res = try XCTUnwrap(server().handle(["jsonrpc": "2.0", "id": 3]))
        XCTAssertEqual((res["error"] as? [String: Any])?["code"] as? Int, -32600)
    }

    func testToolsListReflectsRegisteredTools() throws {
        let tool = MCPTool(name: "echo", description: "d", inputSchema: ["type": "object"]) { _ in .ok("hi") }
        let res = try XCTUnwrap(server(tools: [tool]).handle(["jsonrpc": "2.0", "id": 1, "method": "tools/list"]))
        let tools = try XCTUnwrap((res["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.first?["name"] as? String, "echo")
    }

    func testToolsCallSuccessAndToolErrorAreBothResults() throws {
        let ok = MCPTool(name: "ok", description: "", inputSchema: ["type": "object"]) { _ in .ok("done") }
        let bad = MCPTool(name: "bad", description: "", inputSchema: ["type": "object"]) { _ in .failure("nope") }
        let s = server(tools: [ok, bad])

        let okRes = try XCTUnwrap(s.handle([
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": "ok", "arguments": [String: Any]()],
        ]))
        let okResult = try XCTUnwrap(okRes["result"] as? [String: Any])
        XCTAssertEqual(okResult["isError"] as? Bool, false)
        XCTAssertEqual(((okResult["content"] as? [[String: Any]])?.first?["text"]) as? String, "done")

        let badRes = try XCTUnwrap(s.handle([
            "jsonrpc": "2.0", "id": 2, "method": "tools/call",
            "params": ["name": "bad", "arguments": [String: Any]()],
        ]))
        // A tool failure is reported in the result (isError), not a JSON-RPC error.
        XCTAssertNil(badRes["error"])
        XCTAssertEqual((badRes["result"] as? [String: Any])?["isError"] as? Bool, true)
    }

    func testToolsCallUnknownToolIsInvalidParams() throws {
        let res = try XCTUnwrap(server().handle([
            "jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "nope"],
        ]))
        XCTAssertEqual((res["error"] as? [String: Any])?["code"] as? Int, -32602)
    }

    // MARK: Vault group tools over GroupStore

    func testGroupToolsListAndMutateThroughGroupStore() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-tools-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let shared = SharedAppGroupStore(baseDirectory: dir)
        let seed = try JSONSerialization.data(withJSONObject: [
            "blockedGroups": [[
                "id": "g1", "groupType": "site", "name": "Focus",
                "enabled": true, "mode": "instant", "sites": ["example.com"],
            ]],
        ])
        shared.writeData(seed, to: SharedAppGroupStore.webStoreFileName)
        let store = GroupStore(shared: shared)
        let s = MCPServer(tools: VaultMCPTools.groupTools(store: store))

        // list_groups reflects the seeded group.
        let listRes = try XCTUnwrap(s.handle([
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": "list_groups", "arguments": [String: Any]()],
        ]))
        let listText = try XCTUnwrap((((listRes["result"] as? [String: Any])?["content"]) as? [[String: Any]])?.first?["text"] as? String)
        XCTAssertTrue(listText.contains("Focus"))

        // set_group_enabled false actually flips the stored group.
        let disableRes = try XCTUnwrap(s.handle([
            "jsonrpc": "2.0", "id": 2, "method": "tools/call",
            "params": ["name": "set_group_enabled", "arguments": ["id": "g1", "enabled": false]],
        ]))
        XCTAssertEqual((disableRes["result"] as? [String: Any])?["isError"] as? Bool, false)
        XCTAssertEqual(store.loadGroups().first?.enabled, false)

        // add_website mutates the underlying store.
        _ = s.handle([
            "jsonrpc": "2.0", "id": 3, "method": "tools/call",
            "params": ["name": "add_website", "arguments": ["id": "g1", "host": "news.ycombinator.com"]],
        ])
        XCTAssertEqual((store.load().group(id: "g1")?["sites"] as? [String])?.contains("news.ycombinator.com"), true)

        // An unknown group id is a tool error (isError), not a protocol error.
        let errRes = try XCTUnwrap(s.handle([
            "jsonrpc": "2.0", "id": 4, "method": "tools/call",
            "params": ["name": "set_group_enabled", "arguments": ["id": "nope", "enabled": true]],
        ]))
        XCTAssertEqual((errRes["result"] as? [String: Any])?["isError"] as? Bool, true)
    }
}
#endif
