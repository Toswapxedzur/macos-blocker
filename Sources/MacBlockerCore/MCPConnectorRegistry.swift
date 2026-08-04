#if os(macOS)
import Foundation

/// Registers the local Vault MCP server(s) into the configuration of whichever
/// third-party MCP clients (Claude Code, Codex, Cursor, …) are installed on this
/// Mac, so a user can enable the integration with one toggle instead of hand
/// editing JSON/TOML.
///
/// Discovery reality: none of these clients auto-scan loopback for a running
/// server, so "connect" means writing our entry into that client's own config.
/// Every write is **non-destructive and idempotent** — we only ever add or remove
/// entries under our own stable server keys, and we never touch a config we
/// cannot parse (so a hand-tuned file is never corrupted).
public final class MCPConnectorRegistry: @unchecked Sendable {
    public static let shared = MCPConnectorRegistry()

    /// A Vault MCP endpoint we advertise to clients.
    public struct ServerTarget: Sendable, Equatable {
        public let key: String          // stable server name written into configs
        public let displayName: String
        public let httpURL: String

        public init(key: String, displayName: String, httpURL: String) {
            self.key = key
            self.displayName = displayName
            self.httpURL = httpURL
        }
    }

    public enum Transport: String, Sendable, Equatable {
        case http    // client dials the loopback URL directly
        case stdio   // client spawns a shim that bridges to the loopback URL
    }

    /// How a client stores its MCP servers on disk.
    enum ConfigFormat: Sendable, Equatable {
        case json(serversKey: String)   // JSON object; servers under this top-level key
        case codexToml                  // ~/.codex/config.toml, managed marker block
    }

    /// A known MCP client and where/how to register into it.
    public struct Connector: Sendable, Equatable, Identifiable {
        public let id: String
        public let displayName: String
        public let transport: Transport
        /// Installed if ANY of these home-relative paths exists.
        let detectionPaths: [String]
        /// Home-relative config file to write.
        let configPath: String
        let format: ConfigFormat
    }

    public enum ActionResult: Sendable, Equatable {
        case connected
        case disconnected
        case failed(String)
    }

    private let home: URL
    private let fileManager = FileManager.default
    private let servers: [ServerTarget]
    let catalog: [Connector]
    private let lock = NSLock()

    private static let userDisconnectedDefaultsKey = "MCPConnectorRegistry.userDisconnected.v1"

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        servers: [ServerTarget] = MCPConnectorRegistry.defaultServers(),
        catalog: [Connector] = MCPConnectorRegistry.defaultCatalog
    ) {
        self.home = home
        self.servers = servers
        self.catalog = catalog
    }

    // MARK: Detection

    /// The connectors actually installed on this Mac — the only ones ever shown.
    public func installedConnectors() -> [Connector] {
        catalog.filter { isInstalled($0) }
    }

    func isInstalled(_ connector: Connector) -> Bool {
        connector.detectionPaths.contains {
            fileManager.fileExists(atPath: home.appendingPathComponent($0).path)
        }
    }

    /// True when every Vault server key is present in the client's config.
    public func isConnected(_ connector: Connector) -> Bool {
        let url = home.appendingPathComponent(connector.configPath)
        switch connector.format {
        case .json(let serversKey):
            guard let data = try? Data(contentsOf: url),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let servers = object[serversKey] as? [String: Any] else {
                return false
            }
            return self.servers.allSatisfy { servers[$0.key] != nil }
        case .codexToml:
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
            return text.contains(Self.codexMarkerStart)
        }
    }

    // MARK: Connect / disconnect

    @discardableResult
    public func connect(_ connector: Connector) -> ActionResult {
        lock.lock(); defer { lock.unlock() }
        let result = write(connector, connect: true)
        if case .connected = result { setUserDisconnected(connector.id, false) }
        return result
    }

    @discardableResult
    public func disconnect(_ connector: Connector) -> ActionResult {
        lock.lock(); defer { lock.unlock() }
        let result = write(connector, connect: false)
        if case .disconnected = result { setUserDisconnected(connector.id, true) }
        return result
    }

    @discardableResult
    public func connectByID(_ id: String) -> ActionResult {
        guard let connector = connector(id: id) else { return .failed("unknown-connector") }
        return connect(connector)
    }

    @discardableResult
    public func disconnectByID(_ id: String) -> ActionResult {
        guard let connector = connector(id: id) else { return .failed("unknown-connector") }
        return disconnect(connector)
    }

    /// Gates the launch-time mass registration. It stays off until the Vault MCP
    /// server actually ships, so the app never writes dead-endpoint entries into
    /// the user's real AI-tool configs before there is a server to reach. Manual
    /// per-tool toggles in Settings are unaffected and always work. Flip to true
    /// (with the server) to make "default to connect" fire at launch.
    public static var isLaunchAutoConnectEnabled = false

    /// Connects every installed client the user has not explicitly turned off.
    /// New/undecided clients default to connected. No-op until the integration is
    /// live (see `isLaunchAutoConnectEnabled`).
    public func applyDefaultConnections() {
        guard Self.isLaunchAutoConnectEnabled else { return }
        let disconnected = userDisconnectedIDs()
        for connector in installedConnectors() where !disconnected.contains(connector.id) {
            if !isConnected(connector) { connect(connector) }
        }
    }

    private func write(_ connector: Connector, connect: Bool) -> ActionResult {
        let url = home.appendingPathComponent(connector.configPath)
        do {
            switch connector.format {
            case .json(let serversKey):
                let existing = try? Data(contentsOf: url)
                let updated = try Self.applyJSON(
                    existing: existing,
                    serversKey: serversKey,
                    servers: servers,
                    transport: connector.transport,
                    connect: connect
                )
                try writeAtomically(updated, to: url)
            case .codexToml:
                let existing = (try? String(contentsOf: url, encoding: .utf8))
                let updated = Self.applyCodexToml(existing: existing, servers: servers, connect: connect)
                try writeAtomically(Data(updated.utf8), to: url)
            }
        } catch {
            return .failed(Self.describe(error))
        }
        return connect ? .connected : .disconnected
    }

    private func writeAtomically(_ data: Data, to url: URL) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: [.atomic])
    }

    // MARK: JSON strategy (pure, testable)

    /// Merges (connect) or removes (disconnect) our server keys under `serversKey`
    /// in a JSON config, preserving every other key. Throws if a non-empty file
    /// is present but cannot be parsed, so we never overwrite an unreadable config.
    static func applyJSON(
        existing: Data?,
        serversKey: String,
        servers: [ServerTarget],
        transport: Transport,
        connect: Bool
    ) throws -> Data {
        var root: [String: Any] = [:]
        if let existing, !existing.isEmpty {
            guard let parsed = (try? JSONSerialization.jsonObject(with: existing)) as? [String: Any] else {
                throw RegistryError.unparseableConfig
            }
            root = parsed
        }
        var serverMap = root[serversKey] as? [String: Any] ?? [:]
        for target in servers {
            if connect {
                serverMap[target.key] = serverEntry(for: target, transport: transport)
            } else {
                serverMap.removeValue(forKey: target.key)
            }
        }
        if serverMap.isEmpty {
            root.removeValue(forKey: serversKey)
        } else {
            root[serversKey] = serverMap
        }
        return try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )
    }

    static func serverEntry(for target: ServerTarget, transport: Transport) -> [String: Any] {
        switch transport {
        case .http:
            return ["type": "http", "url": target.httpURL]
        case .stdio:
            // mcp-remote bridges a stdio client to a loopback HTTP MCP server.
            return ["command": "npx", "args": ["-y", "mcp-remote", target.httpURL]]
        }
    }

    // MARK: Codex TOML strategy (pure, testable)

    static let codexMarkerStart = "# >>> vault-mcp (managed by Mac Vault) >>>"
    static let codexMarkerEnd = "# <<< vault-mcp (managed by Mac Vault) <<<"

    /// Appends (connect) or removes (disconnect) a single managed marker block in
    /// `~/.codex/config.toml`, leaving all other TOML untouched. Codex launches
    /// stdio servers, so each target is written as an mcp-remote shim command.
    static func applyCodexToml(existing: String?, servers: [ServerTarget], connect: Bool) -> String {
        var base = stripCodexBlock(existing ?? "")
        guard connect else { return base }

        var block = codexMarkerStart + "\n"
        for target in servers {
            block += "[mcp_servers.\(target.key)]\n"
            block += "command = \"npx\"\n"
            block += "args = [\"-y\", \"mcp-remote\", \"\(target.httpURL)\"]\n\n"
        }
        block += codexMarkerEnd + "\n"

        if !base.isEmpty && !base.hasSuffix("\n") { base += "\n" }
        if !base.isEmpty { base += "\n" }
        return base + block
    }

    /// Removes exactly the managed marker block (and its trailing blank lines).
    private static func stripCodexBlock(_ text: String) -> String {
        guard let startRange = text.range(of: codexMarkerStart),
              let endRange = text.range(of: codexMarkerEnd, range: startRange.upperBound..<text.endIndex) else {
            return text
        }
        var lower = endRange.upperBound
        // Consume the newline that ends the marker line and any following blank lines.
        while lower < text.endIndex, text[lower] == "\n" { lower = text.index(after: lower) }
        var result = String(text[text.startIndex..<startRange.lowerBound])
        result += String(text[lower..<text.endIndex])
        // Collapse a trailing run of blank lines the removal may have left behind.
        while result.hasSuffix("\n\n") { result.removeLast() }
        return result
    }

    // MARK: User-choice persistence (default-to-connect)

    private func userDisconnectedIDs() -> Set<String> {
        let stored = UserDefaults.standard.stringArray(forKey: Self.userDisconnectedDefaultsKey) ?? []
        return Set(stored)
    }

    private func setUserDisconnected(_ id: String, _ disconnected: Bool) {
        var ids = userDisconnectedIDs()
        if disconnected { ids.insert(id) } else { ids.remove(id) }
        UserDefaults.standard.set(Array(ids).sorted(), forKey: Self.userDisconnectedDefaultsKey)
    }

    // MARK: WebView projection

    /// JSON for the Settings UI: only installed connectors, each with its live
    /// connected state and transport. Never lists a client the user does not have.
    public func stateJSON() -> String {
        let entries: [[String: Any]] = installedConnectors().map { connector in
            [
                "id": connector.id,
                "name": connector.displayName,
                "transport": connector.transport.rawValue,
                "connected": isConnected(connector),
            ]
        }
        let payload: [String: Any] = ["connectors": entries]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return "{\"connectors\":[]}"
        }
        return json
    }

    public func connector(id: String) -> Connector? {
        catalog.first { $0.id == id }
    }

    // MARK: Defaults

    /// The Vault MCP endpoints, per environment so development never collides with
    /// a production install's registered servers.
    public static func defaultServers(environment: VaultRuntimeEnvironment = .current) -> [ServerTarget] {
        let development = environment == .development
        let macPort = development ? 18_788 : 8_788
        let classifierPort = development ? 18_789 : 8_789
        let suffix = development ? "-dev" : ""
        return [
            ServerTarget(
                key: "vault-mac\(suffix)",
                displayName: "Mac Vault",
                httpURL: "http://127.0.0.1:\(macPort)/mcp"
            ),
            ServerTarget(
                key: "vault-classifier\(suffix)",
                displayName: "Vault Classifier",
                httpURL: "http://127.0.0.1:\(classifierPort)/mcp"
            ),
        ]
    }

    /// Curated catalog of desktop MCP clients. Detection paths and config
    /// locations are macOS defaults; verify against each client's current docs
    /// before shipping, as they evolve. Only installed clients are ever surfaced.
    public static let defaultCatalog: [Connector] = [
        Connector(
            id: "claude-code",
            displayName: "Claude Code",
            transport: .http,
            detectionPaths: [".claude.json", ".claude"],
            configPath: ".claude.json",
            format: .json(serversKey: "mcpServers")
        ),
        Connector(
            id: "claude-desktop",
            displayName: "Claude Desktop",
            transport: .stdio,
            detectionPaths: ["Library/Application Support/Claude"],
            configPath: "Library/Application Support/Claude/claude_desktop_config.json",
            format: .json(serversKey: "mcpServers")
        ),
        Connector(
            id: "codex",
            displayName: "Codex CLI",
            transport: .stdio,
            detectionPaths: [".codex"],
            configPath: ".codex/config.toml",
            format: .codexToml
        ),
        Connector(
            id: "cursor",
            displayName: "Cursor",
            transport: .http,
            detectionPaths: [".cursor", "Library/Application Support/Cursor"],
            configPath: ".cursor/mcp.json",
            format: .json(serversKey: "mcpServers")
        ),
        Connector(
            id: "vscode",
            displayName: "VS Code",
            transport: .http,
            detectionPaths: ["Library/Application Support/Code"],
            configPath: "Library/Application Support/Code/User/mcp.json",
            format: .json(serversKey: "servers")
        ),
        Connector(
            id: "vscode-insiders",
            displayName: "VS Code Insiders",
            transport: .http,
            detectionPaths: ["Library/Application Support/Code - Insiders"],
            configPath: "Library/Application Support/Code - Insiders/User/mcp.json",
            format: .json(serversKey: "servers")
        ),
        Connector(
            id: "windsurf",
            displayName: "Windsurf",
            transport: .stdio,
            detectionPaths: [".codeium/windsurf", "Library/Application Support/Windsurf"],
            configPath: ".codeium/windsurf/mcp_config.json",
            format: .json(serversKey: "mcpServers")
        ),
        Connector(
            id: "cline",
            displayName: "Cline",
            transport: .http,
            detectionPaths: ["Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev"],
            configPath: "Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json",
            format: .json(serversKey: "mcpServers")
        ),
        Connector(
            id: "zed",
            displayName: "Zed",
            transport: .stdio,
            detectionPaths: [".config/zed", "Library/Application Support/Zed"],
            configPath: ".config/zed/mcp.json",
            format: .json(serversKey: "context_servers")
        ),
    ]

    enum RegistryError: Error {
        case unparseableConfig
    }

    private static func describe(_ error: Error) -> String {
        if case RegistryError.unparseableConfig = error {
            return "existing-config-unreadable"
        }
        return (error as NSError).localizedDescription
    }
}
#endif
