import Foundation
import XCTest
@testable import VaultClassifierApp
import VaultClassifierCore

@MainActor
final class SharedHubServerTests: XCTestCase {
    func testClassifierCanHostTheSharedLoopbackHub() async throws {
        let pairingKey = String(repeating: "a", count: 64)
        let server = SharedHubServer()
        server.onRequest = { request in
            XCTAssertEqual(request.operation, .bridgeInfo)
            return .success(["policies": []])
        }
        server.start(pairingKey: pairingKey)
        defer { server.stop() }

        for _ in 0..<20 where server.state != .running {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(server.state, .running, server.error)

        let session = URLSession(configuration: .ephemeral)
        let socket = session.webSocketTask(with: URL(string: SharedBrowserBridgeProtocol.address)!)
        defer {
            socket.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
        }
        socket.resume()
        try await socket.send(.string(try jsonString([
            "kind": "hello",
            "v": 2,
            "program": "chrome",
            "pairingKey": pairingKey,
        ])))

        let welcome = try await jsonObject(from: socket.receive())
        XCTAssertEqual(welcome["kind"] as? String, "welcome")
        XCTAssertEqual(welcome["hubProgram"] as? String, "classifier")

        try await socket.send(.string(try jsonString([
            "kind": "classifier-request",
            "requestID": "bridge-test-1",
            "operation": "bridge-info",
            "body": [:],
        ])))
        let response = try await jsonObject(from: socket.receive())
        XCTAssertEqual(response["kind"] as? String, "classifier-response")
        XCTAssertEqual(response["requestID"] as? String, "bridge-test-1")
        XCTAssertEqual(response["operation"] as? String, "bridge-info")
        XCTAssertEqual(((response["body"] as? [String: Any])?["policies"] as? [Any])?.count, 0)
    }

    private func jsonString(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private func jsonObject(from message: URLSessionWebSocketTask.Message) throws -> [String: Any] {
        let data: Data
        switch message {
        case .string(let text): data = Data(text.utf8)
        case .data(let value): data = value
        @unknown default: throw NSError(domain: "SharedHubServerTests", code: 1)
        }
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
