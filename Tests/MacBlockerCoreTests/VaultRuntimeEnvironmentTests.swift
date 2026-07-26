import XCTest
@testable import MacBlockerCore

final class VaultRuntimeEnvironmentTests: XCTestCase {
    func testProductionAndDevelopmentUseDisjointLocalSurfaces() {
        XCTAssertEqual(VaultRuntimeEnvironment.resolve(nil), .production)
        XCTAssertEqual(VaultRuntimeEnvironment.resolve("development"), .development)

        let production = VaultRuntimeEnvironment.production
        let development = VaultRuntimeEnvironment.development
        XCTAssertNotEqual(production.hubPort, development.hubPort)
        XCTAssertNotEqual(production.hubAddress, development.hubAddress)
        XCTAssertNotEqual(production.appGroupIdentifier, development.appGroupIdentifier)
        XCTAssertNotEqual(production.sharedStoreDirectoryName, development.sharedStoreDirectoryName)
        XCTAssertNotEqual(production.policyDirectoryName, development.policyDirectoryName)
        XCTAssertNotEqual(production.localFilesDirectoryName, development.localFilesDirectoryName)
        XCTAssertNotEqual(
            production.keychainService("com.adamancia.vault.local-hub"),
            development.keychainService("com.adamancia.vault.local-hub")
        )
    }
}
