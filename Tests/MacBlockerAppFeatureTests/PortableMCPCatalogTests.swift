#if os(macOS)
import XCTest
import MacBlockerCore
@testable import MacBlockerAppFeature

final class PortableMCPCatalogTests: XCTestCase {
    func testCompleteToolCatalogHasUniqueNamesAndPortableSchemas() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tools = VaultMCPTools.groupTools()
            + ClassifierMCPTools.tools()
            + ExtensionMCPTools.tools()
            + LinkMCPTools.tools()
            + ActivityMCPTools.tools(store: ActivityStore(directory: directory))
        let response = try XCTUnwrap(MCPServer(tools: tools).handle([
            "jsonrpc": "2.0", "id": 1, "method": "tools/list"
        ]))
        let catalog = try XCTUnwrap((response["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let names = catalog.compactMap { $0["name"] as? String }
        XCTAssertEqual(names.count, tools.count)
        XCTAssertEqual(Set(names).count, names.count)
        for name in ["set_group", "add_application", "classifier_action", "classifier_actions", "extension_state", "save_activity_group"] {
            XCTAssertTrue(names.contains(name), name)
        }
        for definition in catalog {
            XCTAssertFalse((definition["description"] as? String ?? "").isEmpty)
            XCTAssertEqual((definition["inputSchema"] as? [String: Any])?["type"] as? String, "object")
        }
        // Export only public definitions for the Windows build. No handler is
        // invoked, so this cannot inspect state, credentials or connected peers.
        if let path = ProcessInfo.processInfo.environment["VAULT_MCP_CATALOG_EXPORT"] {
            let data = try JSONSerialization.data(withJSONObject: catalog, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
}
#endif
