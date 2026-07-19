import XCTest
@testable import VaultClassifierCore

final class SharedHubBrokerTests: XCTestCase {
    func testClassifierUsesTheFixedLocalHubContract() {
        XCTAssertEqual(SharedBrowserBridgeProtocol.version, 3)
        XCTAssertEqual(SharedBrowserBridgeProtocol.address, "ws://127.0.0.1:8787")
        XCTAssertTrue(SharedBrowserBridgeProtocol.isAcceptedHubProgram("macapp"))
        XCTAssertTrue(SharedBrowserBridgeProtocol.isAcceptedHubProgram("classifier"))
        XCTAssertFalse(SharedBrowserBridgeProtocol.isAcceptedHubProgram("vault-broker"))
    }
}
