import Foundation
import XCTest
@testable import VaultClassifierApp

@MainActor
final class ProviderModelCatalogStoreTests: XCTestCase {
    func testSuccessfulProbeCatalogsSurviveRelaunchAndDiscardRemovedProfiles() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("provider-model-catalogs.json")
        let firstLaunch = ProviderModelCatalogStore(fileURL: fileURL)
        firstLaunch.save(
            [
                "active-profile": ["gpt-5", "gpt-5", "gpt-4.1"],
                "removed-profile": ["old-model"],
            ],
            allowedProfileIDs: ["active-profile"]
        )

        let restarted = ProviderModelCatalogStore(fileURL: fileURL)
        XCTAssertEqual(
            restarted.load(allowedProfileIDs: ["active-profile"]),
            ["active-profile": ["gpt-4.1", "gpt-5"]]
        )
        XCTAssertEqual(restarted.load(allowedProfileIDs: []), [:])
    }
}
