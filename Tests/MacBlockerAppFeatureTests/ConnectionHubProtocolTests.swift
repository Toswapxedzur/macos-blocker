#if os(macOS)
import Network
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
        XCTAssertNil(ConnectionHub.classifierRequestRejectionReason([
            "requestID": "classifier-source-tags-1",
            "operation": "source-tags",
            "body": [
                "platformID": "youtube",
                "sourceID": "youtube:channel:UC123"
            ]
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

    func testExpiredClassifierResponseIsDiscardedWithoutBecomingAMismatch() {
        XCTAssertEqual(ConnectionHub.classifierRelayTimeoutSeconds, 30)
        XCTAssertEqual(
            ConnectionHub.classifierResponseCorrelation(
                pending: nil,
                classifierPeerID: "classifier-peer",
                sourcePeerID: "browser-peer",
                operation: "collection-info"
            ),
            .expired
        )
    }

    func testClassifierResponseCorrelationMustMatchEveryRoutedField() {
        let pending = ConnectionHub.ClassifierRequest(
            sourcePeerID: "browser-peer",
            classifierPeerID: "classifier-peer",
            operation: "collection-info"
        )
        XCTAssertEqual(
            ConnectionHub.classifierResponseCorrelation(
                pending: pending,
                classifierPeerID: "classifier-peer",
                sourcePeerID: "browser-peer",
                operation: "collection-info"
            ),
            .matched
        )
        XCTAssertEqual(
            ConnectionHub.classifierResponseCorrelation(
                pending: pending,
                classifierPeerID: "classifier-peer",
                sourcePeerID: "other-browser-peer",
                operation: "collection-info"
            ),
            .mismatched
        )
    }

    func testWebSocketCloseMetadataIsRecognized() {
        let closeMetadata = NWProtocolWebSocket.Metadata(opcode: .close)
        let closeContext = NWConnection.ContentContext(
            identifier: "close",
            metadata: [closeMetadata]
        )
        let textMetadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let textContext = NWConnection.ContentContext(
            identifier: "text",
            metadata: [textMetadata]
        )

        XCTAssertTrue(ConnectionHub.isWebSocketClose(closeContext))
        XCTAssertFalse(ConnectionHub.isWebSocketClose(textContext))
        XCTAssertFalse(ConnectionHub.isWebSocketClose(nil))
    }

    // MARK: Browser relay (MCP → browser)

    func testBrowserRequestStaysSchemaBounded() {
        XCTAssertNil(ConnectionHub.browserRequestRejectionReason(
            operation: "get_groups", body: ["scope": "site"]
        ))
        // Empty body is valid — many reads take no arguments.
        XCTAssertNil(ConnectionHub.browserRequestRejectionReason(operation: "list_tabs", body: [:]))
        // A blank or over-long operation namespace is rejected.
        XCTAssertEqual(
            ConnectionHub.browserRequestRejectionReason(operation: "", body: [:]),
            "invalid-browser-operation"
        )
        XCTAssertEqual(
            ConnectionHub.browserRequestRejectionReason(
                operation: String(repeating: "x", count: 65), body: [:]
            ),
            "invalid-browser-operation"
        )
        // A body larger than the browser cap is rejected.
        let huge = ["blob": String(repeating: "a", count: 900_000)]
        XCTAssertEqual(
            ConnectionHub.browserRequestRejectionReason(operation: "read_page", body: huge),
            "invalid-browser-request"
        )
    }

    func testBrowserResponseRejectionReasonAcceptsBodyOrError() {
        XCTAssertNil(ConnectionHub.browserResponseRejectionReason([
            "requestID": "req-1", "operation": "get_groups", "body": ["groups": []],
        ]))
        XCTAssertNil(ConnectionHub.browserResponseRejectionReason([
            "requestID": "req-1", "operation": "get_groups", "error": "browser-unavailable",
        ]))
        // Neither a valid body nor a valid error present.
        XCTAssertEqual(
            ConnectionHub.browserResponseRejectionReason(["requestID": "req-1", "operation": "get_groups"]),
            "invalid-browser-response"
        )
        // Missing identifiers.
        XCTAssertEqual(
            ConnectionHub.browserResponseRejectionReason(["operation": "get_groups", "body": [:]]),
            "invalid-browser-response"
        )
    }

    func testBrowserResponseCorrelationMustMatchPeerAndOperation() {
        let pending = ConnectionHub.BrowserRequest(
            requestID: "req-1",
            browserPeerID: "peer-chrome",
            operation: "get_groups",
            completion: { _ in }
        )
        XCTAssertEqual(
            ConnectionHub.browserResponseCorrelation(
                pending: pending, browserPeerID: "peer-chrome", operation: "get_groups"
            ),
            .matched
        )
        // A different browser peer must not be able to answer this request.
        XCTAssertEqual(
            ConnectionHub.browserResponseCorrelation(
                pending: pending, browserPeerID: "peer-edge", operation: "get_groups"
            ),
            .mismatched
        )
        // Operation must match the routed one.
        XCTAssertEqual(
            ConnectionHub.browserResponseCorrelation(
                pending: pending, browserPeerID: "peer-chrome", operation: "close_tab"
            ),
            .mismatched
        )
        // A response after the timeout (no pending) is expired, not a violation.
        XCTAssertEqual(
            ConnectionHub.browserResponseCorrelation(
                pending: nil, browserPeerID: "peer-chrome", operation: "get_groups"
            ),
            .expired
        )
    }

    func testBrowserRelayFailsFastWhenNotHosting() {
        // The shared hub is not hosting in a unit-test process, so a relay call
        // must invoke its completion with a failure rather than hang.
        let expectation = expectation(description: "browser relay completes")
        var result: ConnectionHub.BrowserRelayResult?
        ConnectionHub.shared.sendBrowserRequest(operation: "get_groups", body: [:]) {
            result = $0
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
        guard case .failure(let reason)? = result else {
            return XCTFail("expected a failure result")
        }
        XCTAssertTrue(
            ["browser-relay-requires-host", "browser-unavailable"].contains(reason),
            "unexpected reason: \(reason)"
        )
    }
}
#endif
