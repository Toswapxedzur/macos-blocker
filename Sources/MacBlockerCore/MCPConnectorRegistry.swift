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

        /// Detection paths that live OUTSIDE a TCC-guarded app-data container, so
        /// probing them with `fileExists` doesn't pop the "access data from other
        /// apps" dialog.
        var unprotectedDetectionPaths: [String] {
            detectionPaths.filter { !MCPConnectorRegistry.isProtectedAppDataPath($0) }
        }

        /// True when we can BOTH detect and write this client without touching a
        /// real sandbox container — i.e. safe to auto-register at launch with no
        /// prompt. Since this app is not sandboxed and no catalog client lives in a
        /// container, every installed client qualifies.
        var isSilentlyRegisterable: Bool {
            !MCPConnectorRegistry.isProtectedAppDataPath(configPath)
                && !unprotectedDetectionPaths.isEmpty
        }
    }

    /// A home-relative path macOS guards behind the "access data from other apps"
    /// prompt for THIS (non-sandboxed) app: only another app's sandbox container.
    /// Mac Vault ships non-sandboxed (`macosBlockerApp.entitlements` has no
    /// `app-sandbox` key), so writing a client's config under plain
    /// `Library/Application Support/<client>/` pops no prompt — that is exactly how
    /// other MCP installers register silently. Only real sandbox containers
    /// (`Library/Containers/`, `Library/Group Containers/`) still gate access, and
    /// no catalog client lives there, so every installed client auto-registers.
    static func isProtectedAppDataPath(_ relativePath: String) -> Bool {
        let path = relativePath.hasPrefix("/") ? String(relativePath.dropFirst()) : relativePath
        return path.hasPrefix("Library/Containers/")
            || path.hasPrefix("Library/Group Containers/")
    }

    public enum ActionResult: Sendable, Equatable {
        case connected
        case failed(String)
    }

    private let home: URL
    private let fileManager = FileManager.default
    private let servers: [ServerTarget]
    let catalog: [Connector]
    private let lock = NSLock()

    /// Supplies the bearer token written into each client's config (and required
    /// by the MCP server). Set by the app at launch from the hub-derived token.
    /// Nil (the default, and in tests) writes tokenless entries.
    public var authTokenProvider: (() -> String?)?

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

    /// Detection that only probes non-TCC-guarded paths, so it never pops the
    /// App Data dialog. Used by the launch sweep.
    func isInstalledSilently(_ connector: Connector) -> Bool {
        connector.unprotectedDetectionPaths.contains {
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

    // MARK: Connect

    @discardableResult
    public func connect(_ connector: Connector) -> ActionResult {
        lock.lock(); defer { lock.unlock() }
        return write(connector)
    }

    /// Gates the launch-time registration: the app turns it on only once its MCP
    /// server is running with a token, so no tool is ever pointed at a dead or
    /// unauthenticated endpoint.
    public static var isLaunchAutoConnectEnabled = false

    /// Connects, at launch, every installed client (owner 2026-09-23 / 09-27:
    /// connection is automatic, with no per-tool choice). The app is
    /// non-sandboxed and every catalog client's config lives outside a sandbox
    /// container (so `isSilentlyRegisterable` is true for all of them). No-op
    /// until the integration is live (see `isLaunchAutoConnectEnabled`).
    public func applyDefaultConnections() {
        guard Self.isLaunchAutoConnectEnabled else { return }
        for connector in catalog
        where connector.isSilentlyRegisterable && isInstalledSilently(connector) {
            if !isConnected(connector) { connect(connector) }
        }
    }

    private func write(_ connector: Connector) -> ActionResult {
        let url = home.appendingPathComponent(connector.configPath)
        let token = authTokenProvider?()
        do {
            switch connector.format {
            case .json(let serversKey):
                let existing = try? Data(contentsOf: url)
                let updated = try Self.applyJSON(
                    existing: existing,
                    serversKey: serversKey,
                    servers: servers,
                    transport: connector.transport,
                    token: token,
                    connect: true
                )
                try writeAtomically(updated, to: url)
            case .codexToml:
                let existing = (try? String(contentsOf: url, encoding: .utf8))
                let updated = Self.applyCodexToml(existing: existing, servers: servers, token: token, connect: true)
                try writeAtomically(Data(updated.utf8), to: url)
            }
        } catch {
            return .failed(Self.describe(error))
        }
        return .connected
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
        token: String? = nil,
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
                serverMap[target.key] = serverEntry(for: target, transport: transport, token: token)
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

    static func serverEntry(for target: ServerTarget, transport: Transport, token: String? = nil) -> [String: Any] {
        switch transport {
        case .http:
            var entry: [String: Any] = ["type": "http", "url": target.httpURL]
            if let token { entry["headers"] = ["Authorization": "Bearer \(token)"] }
            return entry
        case .stdio:
            // mcp-remote bridges a stdio client to a loopback HTTP MCP server.
            var args = ["-y", "mcp-remote", target.httpURL]
            if let token { args += ["--header", "Authorization: Bearer \(token)"] }
            return ["command": "npx", "args": args]
        }
    }

    // MARK: Codex TOML strategy (pure, testable)

    static let codexMarkerStart = "# >>> vault-mcp (managed by Mac Vault) >>>"
    static let codexMarkerEnd = "# <<< vault-mcp (managed by Mac Vault) <<<"

    /// Appends (connect) or removes (disconnect) a single managed marker block in
    /// `~/.codex/config.toml`, leaving all other TOML untouched. Codex launches
    /// stdio servers, so each target is written as an mcp-remote shim command.
    static func applyCodexToml(existing: String?, servers: [ServerTarget], token: String? = nil, connect: Bool) -> String {
        var base = stripCodexBlock(existing ?? "")
        guard connect else { return base }

        var block = codexMarkerStart + "\n"
        for target in servers {
            block += "[mcp_servers.\(target.key)]\n"
            block += "command = \"npx\"\n"
            if let token {
                block += "args = [\"-y\", \"mcp-remote\", \"\(target.httpURL)\", \"--header\", \"Authorization: Bearer \(token)\"]\n\n"
            } else {
                block += "args = [\"-y\", \"mcp-remote\", \"\(target.httpURL)\"]\n\n"
            }
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

    public func connector(id: String) -> Connector? {
        catalog.first { $0.id == id }
    }

    // MARK: Defaults

    /// The Vault MCP endpoint. Mac Vault is the single MCP host for the whole
    /// suite (Vault Classifier does not host one), so there is exactly one server.
    /// The port is per environment so development never collides with a production
    /// install's registered server.
    public static func defaultServers(environment: VaultRuntimeEnvironment = .current) -> [ServerTarget] {
        let development = environment == .development
        let port = environment.mcpPort
        let suffix = development ? "-dev" : ""
        return [
            ServerTarget(
                key: "vault\(suffix)",
                displayName: "Vault",
                httpURL: "http://127.0.0.1:\(port)/mcp"
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
