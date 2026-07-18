#if os(macOS)
import XCTest
@testable import MacBlockerAppFeature

final class ConnectionHubProtocolTests: XCTestCase {
    private let pairingKey = String(repeating: "a", count: 64)

    func testValidAuthenticatedBrowserHello() {
        let hello: [String: Any] = [
            "kind": "hello",
            "v": ConnectionHub.protocolVersion,
            "program": "chrome",
            "pairingKey": pairingKey
        ]
        XCTAssertNil(ConnectionHub.helloRejectionReason(hello, pairingKey: pairingKey))
    }

    func testWrongPairingKeyIsRejected() {
        let hello: [String: Any] = [
            "kind": "hello",
            "v": ConnectionHub.protocolVersion,
            "program": "firefox",
            "pairingKey": String(repeating: "b", count: 64)
        ]
        XCTAssertEqual(
            ConnectionHub.helloRejectionReason(hello, pairingKey: pairingKey),
            "pairing-key-rejected"
        )
    }

    func testOldProtocolIsRejected() {
        let hello: [String: Any] = [
            "kind": "hello",
            "v": 1,
            "program": "chrome",
            "pairingKey": pairingKey
        ]
        XCTAssertEqual(
            ConnectionHub.helloRejectionReason(hello, pairingKey: pairingKey),
            "protocol-mismatch"
        )
    }

    func testRemoteCannotClaimDesktopIdentity() {
        let hello: [String: Any] = [
            "kind": "hello",
            "v": ConnectionHub.protocolVersion,
            "program": ConnectionHub.localProgram,
            "pairingKey": pairingKey
        ]
        XCTAssertEqual(
            ConnectionHub.helloRejectionReason(hello, pairingKey: pairingKey),
            "invalid-program"
        )
    }

    func testAuthenticatedClassifierPeerMayJoinTheSharedHub() {
        let hello: [String: Any] = [
            "kind": "hello",
            "v": ConnectionHub.protocolVersion,
            "program": "classifier",
            "pairingKey": pairingKey
        ]
        XCTAssertNil(ConnectionHub.helloRejectionReason(hello, pairingKey: pairingKey))
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
