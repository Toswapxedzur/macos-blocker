import Foundation
import XCTest
@testable import VaultClassifierApp
@testable import VaultClassifierCore

final class SharedHubBrokerTests: XCTestCase {
    func testClassifierUsesTheFixedLocalHubContract() {
        XCTAssertEqual(SharedBrowserBridgeProtocol.version, 3)
        XCTAssertEqual(SharedBrowserBridgeProtocol.address, "ws://127.0.0.1:8787")
        XCTAssertTrue(SharedBrowserBridgeProtocol.isAcceptedHubProgram("macapp"))
        XCTAssertTrue(SharedBrowserBridgeProtocol.isAcceptedHubProgram("classifier"))
        XCTAssertFalse(SharedBrowserBridgeProtocol.isAcceptedHubProgram("vault-broker"))
    }

    func testWebStateDeliveryUsesUTF8ForCollectedMetadata() throws {
        let title = "It’s Official: Marco Rubio is Running Venezuela"
        let script = try XCTUnwrap(VaultClassifierWebShell.stateUpdateJavaScript(payload: ["title": title]))
        XCTAssertTrue(script.contains("new TextDecoder()"))

        let prefix = "atob('"
        let encodedStart = try XCTUnwrap(script.range(of: prefix)?.upperBound)
        let encodedEnd = try XCTUnwrap(script[encodedStart...].firstIndex(of: "'"))
        let encoded = String(script[encodedStart..<encodedEnd])
        let data = try XCTUnwrap(Data(base64Encoded: encoded))
        let restored = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        XCTAssertEqual(restored["title"], title)
    }
}
