import XCTest
@testable import VaultClassifierCore

final class SharedHubBrokerTests: XCTestCase {
    func testClassifierUsesThePublicBrokerContract() {
        XCTAssertEqual(SharedBrowserBridgeProtocol.version, 3)
        XCTAssertEqual(SharedBrowserBridgeProtocol.address, "wss://customblocker.com/api/vault-bridge")
        XCTAssertTrue(SharedBrowserBridgeProtocol.isAcceptedHubProgram("vault-broker"))
        XCTAssertFalse(SharedBrowserBridgeProtocol.isAcceptedHubProgram("macapp"))
    }
}
