#if os(macOS)
import XCTest
@testable import MacBlockerAppFeature

final class ConnectionHubProtocolTests: XCTestCase {
    private let secret = Data(repeating: 7, count: 32)
    private let challenge = String(repeating: "a", count: 43)

    private func authenticatedHello(program: String) throws -> [String: Any] {
        [
            "kind": "hello",
            "v": ConnectionHub.protocolVersion,
            "program": program,
            "challenge": challenge,
            "proof": try LocalHubAuthentication.makeProof(
                program: program,
                challenge: challenge,
                secret: secret
            )
        ]
    }

    func testAuthenticatedBrowserHelloIsAccepted() throws {
        XCTAssertEqual(
            try LocalHubAuthentication.makeProof(program: "chrome", challenge: challenge, secret: secret),
            "KdU7-EvPwn1g60PF6bYZsqVfl-AD19TbQmtaLmHbyQc"
        )
        XCTAssertNil(ConnectionHub.helloRejectionReason(
            try authenticatedHello(program: "chrome"),
            challenge: challenge,
            secret: secret
        ))
    }

    func testOldProtocolIsRejected() {
        var hello = try! authenticatedHello(program: "chrome")
        hello["v"] = 1
        XCTAssertEqual(
            ConnectionHub.helloRejectionReason(hello, challenge: challenge, secret: secret),
            "protocol-mismatch"
        )
    }

    func testRemoteCannotClaimDesktopIdentity() {
        let hello = try! authenticatedHello(program: ConnectionHub.localProgram)
        XCTAssertEqual(
            ConnectionHub.helloRejectionReason(hello, challenge: challenge, secret: secret),
            "invalid-program"
        )
    }

    func testAuthenticatedClassifierPeerMayJoinTheSharedBroker() throws {
        XCTAssertNil(ConnectionHub.helloRejectionReason(
            try authenticatedHello(program: "classifier"),
            challenge: challenge,
            secret: secret
        ))
    }

    func testUnauthenticatedHelloIsRejected() {
        XCTAssertEqual(
            ConnectionHub.helloRejectionReason([
                "kind": "hello",
                "v": ConnectionHub.protocolVersion,
                "program": "chrome"
            ], challenge: challenge, secret: secret),
            "authentication-failed"
        )
    }

    func testClassifierRequestsStaySchemaBounded() {
        let valid: [String: Any] = [
            "requestID": "classifier-request-1",
            "operation": "bridge-info",
            "body": [:]
        ]
        XCTAssertNil(ConnectionHub.classifierRequestRejectionReason(valid))
        XCTAssertNil(ConnectionHub.classifierRequestRejectionReason([
            "requestID": "classifier-collection-1",
            "operation": "collection-info",
            "body": [:]
        ]))
        XCTAssertNil(ConnectionHub.classifierRequestRejectionReason([
            "requestID": "classifier-diagnostic-1",
            "operation": "diagnostic",
            "body": ["platformID": "youtube", "event": "collector-started"]
        ]))
        XCTAssertNil(ConnectionHub.classifierRequestRejectionReason([
            "requestID": "classifier-collection-2",
            "operation": "collect",
            "body": ["entry": ["platform": "youtube"]]
        ]))
        XCTAssertEqual(
            ConnectionHub.classifierRequestRejectionReason([
                "requestID": "classifier-request-2",
                "operation": "unknown",
                "body": [:]
            ]),
            "invalid-classifier-request"
        )
        XCTAssertEqual(
            ConnectionHub.classifierRequestRejectionReason([
                "requestID": "classifier-request-3",
                "operation": "classify",
                "body": ["payload": String(repeating: "x", count: 90_000)]
            ]),
            "invalid-classifier-request"
        )
    }
}
#endif
