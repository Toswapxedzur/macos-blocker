import Foundation
import XCTest
@testable import VaultClassifierCore

final class BundledResourceTests: XCTestCase {
    func testRelocatedMacAndWindowsResourceDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for suffix in ["bundle", "resources"] {
            let parent = root.appendingPathComponent(suffix, isDirectory: true)
            let resources = parent.appendingPathComponent("VaultClassifier_VaultClassifierCore." + suffix, isDirectory: true).appendingPathComponent("Resources", isDirectory: true)
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            XCTAssertEqual(VaultBundledResources.directory(target: "VaultClassifierCore", subdirectory: "Resources", roots: [parent]), resources)
        }
        XCTAssertNil(VaultBundledResources.directory(target: "VaultClassifierCore", subdirectory: "Resources", roots: [root]))
        XCTAssertNil(VaultBundledResources.directory(target: "../VaultClassifierCore", subdirectory: "Resources", roots: [root]))
    }

    func testBundledSeedPackageUsesCurrentRuntimeResources() throws {
        XCTAssertFalse(try SeedPackageLoader.bundled().package.taxonomy.isEmpty)
    }

    func testStorageProductVersionUsesPackagedResources() throws {
        let directory = try XCTUnwrap(VaultBundledResources.directory(target: "VaultClassifierCore", subdirectory: "Resources"))
        let data = try Data(contentsOf: directory.appendingPathComponent("storage-product-versions.json"))
        let versions = try JSONDecoder().decode([String: String].self, from: data)
        #if os(Windows)
        let product = "windows"
        #else
        let product = "mac"
        #endif
        let bundleVersion = Bundle.main.bundleIdentifier?.hasPrefix("com.adamancia.vault.mac") == true
            ? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String : nil
        XCTAssertEqual(StorageProduct.current.appVersion,
                       ProcessInfo.processInfo.environment["VAULT_STORAGE_APP_VERSION"] ?? bundleVersion ?? versions[product])
        XCTAssertGreaterThanOrEqual(StorageProduct.current.major, 0)
    }
}
