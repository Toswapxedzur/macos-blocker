#if os(macOS)
import XCTest
@testable import MacBlockerCore

final class MCPConnectorRegistryTests: XCTestCase {
    private var home: URL!
    private let servers: [MCPConnectorRegistry.ServerTarget] = [
        .init(key: "vault-mac", displayName: "Mac Vault", httpURL: "http://127.0.0.1:8788/mcp"),
        .init(key: "vault-classifier", displayName: "Vault Classifier", httpURL: "http://127.0.0.1:8789/mcp"),
    ]

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-registry-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        UserDefaults.standard.removeObject(forKey: "MCPConnectorRegistry.userDisconnected.v1")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
        UserDefaults.standard.removeObject(forKey: "MCPConnectorRegistry.userDisconnected.v1")
    }

    private func registry() -> MCPConnectorRegistry {
        MCPConnectorRegistry(home: home, servers: servers)
    }

    private func touch(_ path: String, _ contents: String = "") throws {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func mkdir(_ path: String) throws {
        try FileManager.default.createDirectory(at: home.appendingPathComponent(path), withIntermediateDirectories: true)
    }

    private func read(_ path: String) throws -> String {
        try String(contentsOf: home.appendingPathComponent(path), encoding: .utf8)
    }

    // MARK: Detection — only what the user has

    func testOnlyInstalledConnectorsAreListed() throws {
        try mkdir(".codex")
        try touch(".claude.json", "{}")
        let installed = registry().installedConnectors().map(\.id)
        XCTAssertTrue(installed.contains("codex"))
        XCTAssertTrue(installed.contains("claude-code"))
        XCTAssertFalse(installed.contains("cursor"), "cursor is not installed and must not be listed")
        XCTAssertFalse(installed.contains("vscode"))
    }

    // MARK: JSON strategy (pure)

    func testJSONConnectAddsKeysPreservingEverythingElse() throws {
        let existing = Data(#"{"mcpServers":{"other":{"type":"http","url":"http://x"}},"unrelated":true}"#.utf8)
        let out = try MCPConnectorRegistry.applyJSON(
            existing: existing, serversKey: "mcpServers", servers: servers, transport: .http, connect: true
        )
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: out) as? [String: Any])
        let map = try XCTUnwrap(obj["mcpServers"] as? [String: Any])
        XCTAssertNotNil(map["other"], "existing server preserved")
        XCTAssertNotNil(map["vault-mac"])
        XCTAssertNotNil(map["vault-classifier"])
        XCTAssertEqual(obj["unrelated"] as? Bool, true, "unrelated top-level key preserved")
        let entry = try XCTUnwrap(map["vault-mac"] as? [String: Any])
        XCTAssertEqual(entry["type"] as? String, "http")
        XCTAssertEqual(entry["url"] as? String, "http://127.0.0.1:8788/mcp")
    }

    func testJSONDisconnectRemovesOnlyOurKeys() throws {
        let existing = Data(#"{"mcpServers":{"other":{"url":"http://x"},"vault-mac":{},"vault-classifier":{}}}"#.utf8)
        let out = try MCPConnectorRegistry.applyJSON(
            existing: existing, serversKey: "mcpServers", servers: servers, transport: .http, connect: false
        )
        let map = try XCTUnwrap((try JSONSerialization.jsonObject(with: out) as? [String: Any])?["mcpServers"] as? [String: Any])
        XCTAssertNotNil(map["other"])
        XCTAssertNil(map["vault-mac"])
        XCTAssertNil(map["vault-classifier"])
    }

    func testJSONDisconnectDropsNowEmptyServersKey() throws {
        let existing = Data(#"{"mcpServers":{"vault-mac":{},"vault-classifier":{}},"keep":1}"#.utf8)
        let out = try MCPConnectorRegistry.applyJSON(
            existing: existing, serversKey: "mcpServers", servers: servers, transport: .http, connect: false
        )
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: out) as? [String: Any])
        XCTAssertNil(obj["mcpServers"], "empty servers map removed rather than left as {}")
        XCTAssertEqual(obj["keep"] as? Int, 1)
    }

    func testJSONConnectOnEmptyUsesGivenServersKey() throws {
        let out = try MCPConnectorRegistry.applyJSON(
            existing: nil, serversKey: "servers", servers: servers, transport: .http, connect: true
        )
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: out) as? [String: Any])
        XCTAssertNotNil((obj["servers"] as? [String: Any])?["vault-mac"])
    }

    func testJSONThrowsOnUnparseableExistingConfig() {
        XCTAssertThrowsError(try MCPConnectorRegistry.applyJSON(
            existing: Data("not json {".utf8), serversKey: "mcpServers", servers: servers, transport: .http, connect: true
        ))
    }

    func testStdioTransportWritesShimCommand() {
        let entry = MCPConnectorRegistry.serverEntry(for: servers[0], transport: .stdio)
        XCTAssertEqual(entry["command"] as? String, "npx")
        XCTAssertEqual(entry["args"] as? [String], ["-y", "mcp-remote", "http://127.0.0.1:8788/mcp"])
    }

    // MARK: Codex TOML strategy (pure)

    func testCodexConnectAppendsMarkedBlockPreservingExisting() {
        let out = MCPConnectorRegistry.applyCodexToml(
            existing: "[mcp_servers.other]\ncommand = \"foo\"\n", servers: servers, connect: true
        )
        XCTAssertTrue(out.contains("[mcp_servers.other]"), "user's own TOML preserved")
        XCTAssertTrue(out.contains(MCPConnectorRegistry.codexMarkerStart))
        XCTAssertTrue(out.contains("[mcp_servers.vault-mac]"))
        XCTAssertTrue(out.contains("mcp-remote"))
        XCTAssertTrue(out.contains(MCPConnectorRegistry.codexMarkerEnd))
    }

    func testCodexConnectIsIdempotent() {
        let once = MCPConnectorRegistry.applyCodexToml(existing: "", servers: servers, connect: true)
        let twice = MCPConnectorRegistry.applyCodexToml(existing: once, servers: servers, connect: true)
        let blockCount = twice.components(separatedBy: MCPConnectorRegistry.codexMarkerStart).count - 1
        XCTAssertEqual(blockCount, 1, "connecting twice leaves exactly one managed block")
    }

    func testCodexDisconnectRemovesOnlyManagedBlock() {
        let connected = MCPConnectorRegistry.applyCodexToml(
            existing: "[mcp_servers.other]\ncommand = \"foo\"\n", servers: servers, connect: true
        )
        let disconnected = MCPConnectorRegistry.applyCodexToml(existing: connected, servers: servers, connect: false)
        XCTAssertTrue(disconnected.contains("[mcp_servers.other]"))
        XCTAssertFalse(disconnected.contains(MCPConnectorRegistry.codexMarkerStart))
        XCTAssertFalse(disconnected.contains("vault-mac"))
    }

    // MARK: End-to-end on disk

    func testConnectThenDisconnectRoundTripsOnDisk() throws {
        try touch(".cursor/mcp.json", "{}")
        let registry = registry()
        let cursor = try XCTUnwrap(registry.connector(id: "cursor"))

        XCTAssertFalse(registry.isConnected(cursor))
        XCTAssertEqual(registry.connect(cursor), .connected)
        XCTAssertTrue(registry.isConnected(cursor))
        XCTAssertTrue(try read(".cursor/mcp.json").contains("vault-mac"))

        XCTAssertEqual(registry.disconnect(cursor), .disconnected)
        XCTAssertFalse(registry.isConnected(cursor))
    }

    func testConnectCreatesMissingConfigFileAndDirectories() throws {
        try mkdir(".cursor") // installed, but no mcp.json yet
        let registry = registry()
        XCTAssertEqual(registry.connect(try XCTUnwrap(registry.connector(id: "cursor"))), .connected)
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent(".cursor/mcp.json").path))
    }

    func testConnectFailsGracefullyAndLeavesUnparseableConfigUntouched() throws {
        try touch(".cursor/mcp.json", "not valid json")
        let registry = registry()
        XCTAssertEqual(registry.connect(try XCTUnwrap(registry.connector(id: "cursor"))), .failed("existing-config-unreadable"))
        XCTAssertEqual(try read(".cursor/mcp.json"), "not valid json", "a config we cannot parse is never overwritten")
    }

    // MARK: Default-to-connect

    func testApplyDefaultConnectionsIsInertUntilIntegrationLive() throws {
        try touch(".cursor/mcp.json", "{}")
        let registry = registry()
        let cursor = try XCTUnwrap(registry.connector(id: "cursor"))
        MCPConnectorRegistry.isLaunchAutoConnectEnabled = false
        registry.applyDefaultConnections()
        XCTAssertFalse(registry.isConnected(cursor), "no launch auto-write before the integration is live")
    }

    func testApplyDefaultConnectionsConnectsInstalledButRespectsExplicitDisconnect() throws {
        MCPConnectorRegistry.isLaunchAutoConnectEnabled = true
        defer { MCPConnectorRegistry.isLaunchAutoConnectEnabled = false }
        try touch(".cursor/mcp.json", "{}")
        try mkdir(".codex")
        let registry = registry()
        let cursor = try XCTUnwrap(registry.connector(id: "cursor"))
        let codex = try XCTUnwrap(registry.connector(id: "codex"))

        // User explicitly turns Codex off; Cursor is left at its default.
        registry.disconnect(codex)
        registry.applyDefaultConnections()

        XCTAssertTrue(registry.isConnected(cursor), "installed + undecided defaults to connected")
        XCTAssertFalse(registry.isConnected(codex), "an explicit disconnect is not silently re-connected")
    }

    // MARK: WebView projection

    func testStateJSONListsOnlyInstalledWithLiveConnectedFlag() throws {
        try touch(".cursor/mcp.json", "{}")
        let registry = registry()
        registry.connect(try XCTUnwrap(registry.connector(id: "cursor")))
        let json = registry.stateJSON()
        XCTAssertTrue(json.contains("\"cursor\""))
        XCTAssertTrue(json.contains("\"connected\":true"))
        XCTAssertFalse(json.contains("\"vscode\""), "a client the user does not have is never surfaced")
    }
}
#endif
