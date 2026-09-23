#if os(macOS)
import XCTest
@testable import MacBlockerAppFeature
import MacBlockerCore
import VaultClassifierApp

final class ClassifierMCPToolsTests: XCTestCase {
    private func makeServer() -> (MCPServer, calls: () -> [(String, [String: Any])]) {
        var calls: [(String, [String: Any])] = []
        let bridge = ClassifierMCPTools.Bridge(
            snapshot: { section in
                if section == "nope" { return nil }
                return ["section": section ?? "overview", "settings": ["localLLM": ["strictness": 3]]]
            },
            perform: { action, data in
                calls.append((action, data))
                return action == "bad" ? .init(rerender: true, issue: "invalid choice") : .init(rerender: true, issue: nil)
            },
            catalog: { [.init(name: "createClassifierType", keys: ["name", "platformID"], summary: "Create a group.")] }
        )
        return (MCPServer(tools: ClassifierMCPTools.tools(bridge: bridge)), { calls })
    }

    private func call(_ server: MCPServer, _ name: String, _ arguments: [String: Any]) throws -> (text: String, isError: Bool) {
        let res = try XCTUnwrap(server.handle(["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": name, "arguments": arguments]]))
        let result = try XCTUnwrap(res["result"] as? [String: Any])
        let content = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        return (content, result["isError"] as? Bool ?? false)
    }

    func testToolsAreAdvertised() throws {
        let (server, _) = makeServer()
        let res = try XCTUnwrap(server.handle(["jsonrpc": "2.0", "id": 1, "method": "tools/list"]))
        let names = try XCTUnwrap((res["result"] as? [String: Any])?["tools"] as? [[String: Any]]).compactMap { $0["name"] as? String }
        XCTAssertEqual(Set(names), ["classifier_state", "classifier_action", "classifier_actions"])
    }

    func testStateReturnsSectionsAndRejectsUnknownOnes() throws {
        let (server, _) = makeServer()
        let overview = try call(server, "classifier_state", [:])
        XCTAssertFalse(overview.isError); XCTAssertTrue(overview.text.contains("\"section\":\"overview\""))
        let settings = try call(server, "classifier_state", ["section": "settings"])
        XCTAssertTrue(settings.text.contains("\"strictness\":3"))
        XCTAssertTrue(try call(server, "classifier_state", ["section": "nope"]).isError)
    }

    func testActionRoutesDataAndReportsTheIssueAsAnError() throws {
        let (server, calls) = makeServer()
        let ok = try call(server, "classifier_action", ["action": "createClassifierType", "data": ["name": "X posts", "platformID": "twitter"]])
        XCTAssertFalse(ok.isError); XCTAssertTrue(ok.text.contains("\"ok\":true"))
        XCTAssertEqual(calls().first?.0, "createClassifierType")
        XCTAssertEqual(calls().first?.1["platformID"] as? String, "twitter")
        let bad = try call(server, "classifier_action", ["action": "bad"])
        XCTAssertTrue(bad.isError); XCTAssertTrue(bad.text.contains("invalid choice"))
        XCTAssertTrue(try call(server, "classifier_action", [:]).isError)
    }

    func testCatalogListsActionsWithKeys() throws {
        let (server, _) = makeServer()
        let catalog = try call(server, "classifier_actions", [:])
        XCTAssertTrue(catalog.text.contains("createClassifierType") && catalog.text.contains("platformID"))
    }

    func testLiveBridgeIsWiredIntoTheVaultServer() throws {
        let server = VaultMCPHTTPServer.vault(port: 0, token: nil, additionalTools: ClassifierMCPTools.tools())
        XCTAssertNotNil(server)
    }
}
#endif
