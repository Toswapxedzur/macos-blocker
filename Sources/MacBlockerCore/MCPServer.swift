#if os(macOS)
import Foundation

/// The result of running one MCP tool. MCP reports tool-execution failures in
/// the result (with `isError`) rather than as a protocol error, so the model
/// sees them; protocol-level problems are JSON-RPC errors instead.
public struct MCPToolResult: Sendable {
    public let text: String
    public let isError: Bool

    public init(text: String, isError: Bool = false) {
        self.text = text
        self.isError = isError
    }

    public static func ok(_ text: String) -> MCPToolResult { .init(text: text, isError: false) }
    public static func failure(_ text: String) -> MCPToolResult { .init(text: text, isError: true) }
}

/// A single MCP tool: its advertised name/description/schema and a synchronous
/// handler. Tools are the app's clean, bounded operations — never arbitrary
/// control — so the handler validates its own arguments and returns a result.
public struct MCPTool {
    public let name: String
    public let description: String
    public let inputSchema: [String: Any]
    public let handler: ([String: Any]) -> MCPToolResult

    public init(
        name: String,
        description: String,
        inputSchema: [String: Any],
        handler: @escaping ([String: Any]) -> MCPToolResult
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.handler = handler
    }
}

/// Minimal Model Context Protocol server: JSON-RPC 2.0 dispatch over one abstract
/// message, so the transport (loopback HTTP) is a thin shell and the whole
/// protocol is unit-testable. Mac Vault is the suite's sole MCP host.
public final class MCPServer: @unchecked Sendable {
    /// A protocol revision we speak. `initialize` echoes the client's requested
    /// version when present, which is how MCP negotiates compatibility.
    public static let protocolVersion = "2025-06-18"

    private let serverName: String
    private let serverVersion: String
    private let tools: [MCPTool]
    private let toolsByName: [String: MCPTool]

    public init(serverName: String = "Vault", serverVersion: String = "0.0.0", tools: [MCPTool]) {
        self.serverName = serverName
        self.serverVersion = serverVersion
        self.tools = tools
        self.toolsByName = Dictionary(tools.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Handles one JSON-RPC message. Returns the response object, or nil for a
    /// notification (a message with no `id`), which must not produce a response.
    public func handle(_ message: [String: Any]) -> [String: Any]? {
        let id = message["id"]
        let isNotification = message["id"] == nil

        guard let method = message["method"] as? String else {
            return isNotification ? nil : errorResponse(id: id, code: -32600, message: "Invalid Request")
        }
        let params = message["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String
            return response(id: id, result: [
                "protocolVersion": requested ?? Self.protocolVersion,
                "capabilities": [
                    "tools": [String: Any](),
                    "resources": [String: Any](),
                ],
                "serverInfo": ["name": serverName, "version": serverVersion],
            ])

        case "notifications/initialized", "notifications/cancelled":
            return nil

        case "ping":
            return response(id: id, result: [String: Any]())

        case "tools/list":
            let listed: [[String: Any]] = tools.map {
                ["name": $0.name, "description": $0.description, "inputSchema": $0.inputSchema]
            }
            return response(id: id, result: ["tools": listed])

        case "tools/call":
            guard let name = params["name"] as? String else {
                return errorResponse(id: id, code: -32602, message: "Missing tool name")
            }
            guard let tool = toolsByName[name] else {
                return errorResponse(id: id, code: -32602, message: "Unknown tool: \(name)")
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let result = tool.handler(arguments)
            return response(id: id, result: [
                "content": [["type": "text", "text": result.text]],
                "isError": result.isError,
            ])

        case "resources/list":
            return response(id: id, result: ["resources": [[String: Any]]()])

        default:
            return isNotification
                ? nil
                : errorResponse(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    private func response(id: Any?, result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result]
    }

    private func errorResponse(id: Any?, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
    }
}
#endif
