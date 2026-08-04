#if os(macOS)
import Foundation
import MacBlockerCore
import Network

/// Loopback HTTP transport for the Mac Vault MCP server (MCP "Streamable HTTP":
/// a single `POST /mcp` endpoint carrying JSON-RPC). The protocol logic lives in
/// `MCPServer`; this is the thin socket shell, hardened loopback-only like the
/// hub. It is instantiable and unit-tested at the request/response layer but is
/// NOT started until the integration goes live (auth + launch wiring).
public final class VaultMCPHTTPServer: @unchecked Sendable {
    private static let maxRequestBytes = 4 * 1_048_576

    public struct ParsedHTTPRequest: Equatable {
        public let method: String
        public let path: String
        public let headers: [String: String]   // keys lowercased
        public let body: Data
    }

    private let server: MCPServer
    private let port: UInt16
    /// Optional bearer token gate. When set, requests must carry a matching
    /// `Authorization: Bearer <token>`. Nil for now (the server isn't exposed
    /// until the consent/auth layer lands); the check is ready for it.
    private let requiredToken: String?

    private let queue = DispatchQueue(label: "macosBlocker.VaultMCPHTTPServer")
    private let lock = NSLock()
    private var listener: NWListener?

    public init(
        server: MCPServer,
        port: UInt16 = VaultRuntimeEnvironment.current.mcpPort,
        requiredToken: String? = nil
    ) {
        self.server = server
        self.port = port
        self.requiredToken = requiredToken
    }

    /// Convenience: a server exposing the Vault group tools, gated by `token`.
    public static func vault(
        port: UInt16 = VaultRuntimeEnvironment.current.mcpPort,
        token: String? = nil
    ) -> VaultMCPHTTPServer {
        VaultMCPHTTPServer(server: MCPServer(tools: VaultMCPTools.groupTools()), port: port, requiredToken: token)
    }

    // MARK: Lifecycle

    public func start() {
        lock.lock(); defer { lock.unlock() }
        guard listener == nil, let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        do {
            let listener = try NWListener(using: .tcp, on: nwPort)
            self.listener = listener
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
        } catch {
            listener = nil
        }
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        listener?.cancel()
        listener = nil
    }

    // MARK: Connection handling

    private func accept(_ connection: NWConnection) {
        guard Self.isLoopback(connection) else {
            connection.cancel()
            return
        }
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private static func isLoopback(_ connection: NWConnection) -> Bool {
        guard case let .hostPort(host, _) = connection.endpoint else { return false }
        switch host.debugDescription.lowercased() {
        case "127.0.0.1", "::1", "[::1]":
            return true
        default:
            return false
        }
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var accumulated = buffer
            if let data { accumulated.append(data) }

            if accumulated.count > Self.maxRequestBytes {
                self.respond(connection, Self.httpResponse(status: 413, body: Data()))
                return
            }
            if let request = Self.parseHTTPRequest(accumulated) {
                self.respond(connection, self.response(for: request))
                return
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receive(connection, buffer: accumulated)
        }
    }

    private func respond(_ connection: NWConnection, _ data: Data) {
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }

    /// Builds the HTTP response for a parsed request. Public-of-behavior so the
    /// routing/auth/JSON-RPC path is testable without a socket.
    func response(for request: ParsedHTTPRequest) -> Data {
        guard request.method == "POST", request.path.hasPrefix("/mcp") else {
            return Self.httpResponse(status: 404, body: Data("Not Found".utf8))
        }
        if let requiredToken {
            let presented = request.headers["authorization"]
            guard presented == "Bearer \(requiredToken)" else {
                return Self.httpResponse(status: 401, body: Data("Unauthorized".utf8))
            }
        }
        let (body, status) = handleJSONRPC(request.body)
        return Self.httpResponse(
            status: status,
            headers: ["Content-Type": "application/json"],
            body: body
        )
    }

    /// Parses the JSON-RPC body (single object or batch array), dispatches each
    /// through `MCPServer`, and returns the response body plus HTTP status. A
    /// batch of pure notifications yields 202 with an empty body.
    func handleJSONRPC(_ body: Data) -> (Data, Int) {
        guard let json = try? JSONSerialization.jsonObject(with: body) else {
            let error = Self.encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
            return (error, 200)
        }
        if let object = json as? [String: Any] {
            guard let responseObject = server.handle(object) else { return (Data(), 202) }
            return (Self.encode(responseObject), 200)
        }
        if let batch = json as? [[String: Any]] {
            let responses = batch.compactMap { server.handle($0) }
            if responses.isEmpty { return (Data(), 202) }
            return (Self.encode(responses), 200)
        }
        let error = Self.encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32600, "message": "Invalid Request"]])
        return (error, 200)
    }

    // MARK: Pure HTTP helpers (tested)

    /// Parses an HTTP/1.1 request, returning nil when the buffer is not yet a
    /// complete request (headers not terminated, or body shorter than
    /// Content-Length) so the caller keeps reading.
    static func parseHTTPRequest(_ data: Data) -> ParsedHTTPRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = data.range(of: separator) else { return nil }
        let headerData = data.subdata(in: data.startIndex..<headerEnd.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }

        var lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count >= 2 else { return nil }
        let method = String(requestLine[0])
        let path = String(requestLine[1])

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        let bodyStart = headerEnd.upperBound
        let available = data.subdata(in: bodyStart..<data.endIndex)
        let contentLength = headers["content-length"].flatMap { Int($0) } ?? 0
        guard available.count >= contentLength else { return nil }
        let body = available.subdata(in: available.startIndex..<available.index(available.startIndex, offsetBy: contentLength))
        return ParsedHTTPRequest(method: method, path: path, headers: headers, body: body)
    }

    static func httpResponse(status: Int, headers: [String: String] = [:], body: Data) -> Data {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 202: reason = "Accepted"
        case 401: reason = "Unauthorized"
        case 404: reason = "Not Found"
        case 413: reason = "Payload Too Large"
        default: reason = "OK"
        }
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n"
        for (key, value) in headers { head += "\(key): \(value)\r\n" }
        head += "\r\n"
        var response = Data(head.utf8)
        response.append(body)
        return response
    }

    private static func encode(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    }
}
#endif
