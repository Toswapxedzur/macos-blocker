#if os(macOS)
import XCTest
@testable import MacBlockerAppFeature

final class ConnectionHubProtocolTests: XCTestCase {
    func testPublicBrokerHelloAcceptsAValidBrowserPeer() {
        let hello: [String: Any] = [
            "kind": "hello",
            "v": ConnectionHub.protocolVersion,
            "program": "chrome"
        ]
        XCTAssertNil(ConnectionHub.helloRejectionReason(hello))
    }

    func testOldProtocolIsRejected() {
        let hello: [String: Any] = [
            "kind": "hello",
            "v": 1,
            "program": "chrome"
        ]
        XCTAssertEqual(
            ConnectionHub.helloRejectionReason(hello),
            "protocol-mismatch"
        )
    }

    func testRemoteCannotClaimDesktopIdentity() {
        let hello: [String: Any] = [
            "kind": "hello",
            "v": ConnectionHub.protocolVersion,
            "program": ConnectionHub.localProgram
        ]
        XCTAssertEqual(
            ConnectionHub.helloRejectionReason(hello),
            "invalid-program"
        )
    }

    func testClassifierPeerMayJoinTheSharedBroker() {
        let hello: [String: Any] = [
            "kind": "hello",
            "v": ConnectionHub.protocolVersion,
            "program": "classifier"
        ]
        XCTAssertNil(ConnectionHub.helloRejectionReason(hello))
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
