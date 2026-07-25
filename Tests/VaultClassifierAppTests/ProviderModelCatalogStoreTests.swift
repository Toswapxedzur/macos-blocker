import Foundation
import XCTest
@testable import VaultClassifierApp
import VaultClassifierCore

@MainActor
final class ProviderModelCatalogStoreTests: XCTestCase {
    func testSuccessfulProbeCatalogsSurviveRelaunchAndDiscardRemovedProfiles() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("provider-model-catalogs.json")
        let firstLaunch = ProviderModelCatalogStore(fileURL: fileURL)
        firstLaunch.save(
            [
                "active-profile": [
                    .init(identifier: "gpt-5", supportsTools: true),
                    .init(identifier: "gpt-5", supportsTools: false),
                    .init(identifier: "gpt-4.1", supportsNativeWebSearch: true),
                ],
                "removed-profile": [.init(identifier: "old-model")],
            ],
            allowedProfileIDs: ["active-profile"]
        )

        let restarted = ProviderModelCatalogStore(fileURL: fileURL)
        XCTAssertEqual(
            restarted.load(allowedProfileIDs: ["active-profile"]),
            [
                "active-profile": [
                    .init(identifier: "gpt-4.1", supportsNativeWebSearch: true),
                    .init(identifier: "gpt-5", supportsTools: true),
                ]
            ]
        )
        XCTAssertEqual(restarted.load(allowedProfileIDs: []), [:])
    }

    func testLegacyIdentifierOnlySnapshotMigratesToUnknownPerModelCapabilities() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("provider-model-catalogs.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(#"{"version":1,"catalogs":{"profile":["model-b","model-a"]}}"#.utf8)
            .write(to: fileURL)

        let store = ProviderModelCatalogStore(fileURL: fileURL)
        XCTAssertEqual(
            store.load(allowedProfileIDs: ["profile"]),
            [
                "profile": [
                    .init(identifier: "model-a"),
                    .init(identifier: "model-b"),
                ]
            ]
        )
        let migrated = try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
        XCTAssertEqual(migrated?["version"] as? Int, 2)
    }
}
