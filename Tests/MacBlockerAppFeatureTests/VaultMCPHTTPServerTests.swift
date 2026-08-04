#if os(macOS)
import XCTest
@testable import MacBlockerAppFeature
import MacBlockerCore

final class VaultMCPHTTPServerTests: XCTestCase {
    private func vaultServer(token: String? = nil) -> VaultMCPHTTPServer {
        let tool = MCPTool(name: "ping_tool", description: "", inputSchema: ["type": "object"]) { _ in .ok("pong") }
        return VaultMCPHTTPServer(server: MCPServer(tools: [tool]), port: 0, requiredToken: token)
    }

    // MARK: HTTP parsing

    func testParsesCompleteRequest() throws {
        let body = "{\"jsonrpc\":\"2.0\"}"
        let raw = "POST /mcp HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        let parsed = try XCTUnwrap(VaultMCPHTTPServer.parseHTTPRequest(Data(raw.utf8)))
        XCTAssertEqual(parsed.method, "POST")
        XCTAssertEqual(parsed.path, "/mcp")
        XCTAssertEqual(parsed.headers["content-type"], "application/json")
        XCTAssertEqual(String(data: parsed.body, encoding: .utf8), body)
    }

    func testParseReturnsNilWhenHeadersNotTerminated() {
        XCTAssertNil(VaultMCPHTTPServer.parseHTTPRequest(Data("POST /mcp HTTP/1.1\r\nHost: x".utf8)))
    }

    func testParseReturnsNilWhenBodyShorterThanContentLength() {
        XCTAssertNil(VaultMCPHTTPServer.parseHTTPRequest(Data("POST /mcp HTTP/1.1\r\nContent-Length: 50\r\n\r\nshort".utf8)))
    }

    // MARK: Routing / auth

    func testNonMcpPathIs404() {
        let req = VaultMCPHTTPServer.ParsedHTTPRequest(method: "GET", path: "/", headers: [:], body: Data())
        let out = String(data: vaultServer().response(for: req), encoding: .utf8) ?? ""
        XCTAssertTrue(out.hasPrefix("HTTP/1.1 404"))
    }

    func testPostMcpDispatchesJSONRPC() {
        let body = Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}".utf8)
        let req = VaultMCPHTTPServer.ParsedHTTPRequest(method: "POST", path: "/mcp", headers: [:], body: body)
        let out = String(data: vaultServer().response(for: req), encoding: .utf8) ?? ""
        XCTAssertTrue(out.hasPrefix("HTTP/1.1 200"))
        XCTAssertTrue(out.contains("application/json"))
        XCTAssertTrue(out.contains("ping_tool"))
    }

    func testUnauthorizedWhenTokenRequiredButMissing() {
        let body = Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}".utf8)
        let req = VaultMCPHTTPServer.ParsedHTTPRequest(method: "POST", path: "/mcp", headers: [:], body: body)
        let out = String(data: vaultServer(token: "secret").response(for: req), encoding: .utf8) ?? ""
        XCTAssertTrue(out.hasPrefix("HTTP/1.1 401"))
    }

    func testAuthorizedWithMatchingBearerToken() {
        let body = Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}".utf8)
        let req = VaultMCPHTTPServer.ParsedHTTPRequest(
            method: "POST", path: "/mcp", headers: ["authorization": "Bearer secret"], body: body
        )
        let out = String(data: vaultServer(token: "secret").response(for: req), encoding: .utf8) ?? ""
        XCTAssertTrue(out.hasPrefix("HTTP/1.1 200"))
    }

    // MARK: JSON-RPC body handling

    func testNotificationYields202EmptyBody() {
        let (data, status) = vaultServer().handleJSONRPC(Data("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}".utf8))
        XCTAssertEqual(status, 202)
        XCTAssertTrue(data.isEmpty)
    }

    func testBatchProducesArrayOfResponses() throws {
        let batch = "[{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"},{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"ping\"}]"
        let (data, status) = vaultServer().handleJSONRPC(Data(batch.utf8))
        XCTAssertEqual(status, 200)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: data) as? [[String: Any]])?.count, 2)
    }

    func testParseErrorYieldsJSONRPCParseError() throws {
        let (data, _) = vaultServer().handleJSONRPC(Data("not json".utf8))
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual((obj?["error"] as? [String: Any])?["code"] as? Int, -32700)
    }

    // MARK: Live loopback round-trip (exercises the NWListener socket path)

    func testLiveLoopbackRoundTripServesToolsList() throws {
        let port: UInt16 = 18_799
        let tool = MCPTool(name: "ping_tool", description: "", inputSchema: ["type": "object"]) { _ in .ok("pong") }
        let server = VaultMCPHTTPServer(server: MCPServer(tools: [tool]), port: port)
        server.start()
        defer { server.stop() }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}".utf8)

        let expectation = expectation(description: "MCP HTTP response")
        var statusCode: Int?
        var bodyText: String?
        URLSession.shared.dataTask(with: request) { data, response, _ in
            statusCode = (response as? HTTPURLResponse)?.statusCode
            bodyText = data.flatMap { String(data: $0, encoding: .utf8) }
            expectation.fulfill()
        }.resume()

        wait(for: [expectation], timeout: 5)
        XCTAssertEqual(statusCode, 200)
        XCTAssertEqual(bodyText?.contains("ping_tool"), true)
    }
}
#endif
