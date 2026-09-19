import XCTest
import VaultClassifierCore
@testable import VaultClassifierBridge

final class NativeMessagingHostRegistrationTests: XCTestCase {
    private var root: URL!
    private var support: URL!
    private var appBundle: Bundle!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("nm-\(UUID().uuidString)")
        support = root.appendingPathComponent("Application Support")
        let macOS = root.appendingPathComponent("Vault.app/Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let host = macOS.appendingPathComponent("VaultLocalHubNativeHost")
        try Data("#!/bin/sh\n".utf8).write(to: host)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: host.path)
        appBundle = try XCTUnwrap(Bundle(url: root.appendingPathComponent("Vault.app")))
        // Chrome and Brave are "installed"; Edge is not.
        for browser in ["Google/Chrome", "BraveSoftware/Brave-Browser"] {
            try FileManager.default.createDirectory(at: support.appendingPathComponent(browser), withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func register(_ environment: VaultRuntimeEnvironment = .production) -> [URL] {
        NativeMessagingHostRegistration.registerBundledHost(environment: environment, bundle: appBundle, applicationSupport: support)
    }

    func testRegistersOnlyInstalledBrowsersWithTheBundledHostAndProductionOrigin() throws {
        let written = register()
        XCTAssertEqual(written.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.appendingPathComponent("Microsoft Edge").path))

        let manifest = support.appendingPathComponent("Google/Chrome/NativeMessagingHosts/com.adamancia.vault.local_hub.json")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        XCTAssertEqual(json["name"] as? String, "com.adamancia.vault.local_hub")
        XCTAssertEqual(json["type"] as? String, "stdio")
        XCTAssertEqual(json["allowed_origins"] as? [String], [VaultRuntimeEnvironment.production.chromeExtensionOrigin])
        XCTAssertEqual(json["path"] as? String, appBundle.bundleURL.appendingPathComponent("Contents/MacOS/VaultLocalHubNativeHost").path)
    }

    func testIsIdempotentAndRepairsAStaleManifest() throws {
        XCTAssertEqual(register().count, 2)
        XCTAssertEqual(register().count, 0, "unchanged manifests are not rewritten")

        let manifest = support.appendingPathComponent("Google/Chrome/NativeMessagingHosts/com.adamancia.vault.local_hub.json")
        try Data("{\"path\":\"/old/place\"}".utf8).write(to: manifest)
        XCTAssertEqual(register(), [manifest], "a manifest pointing at a moved app is rewritten")
    }

    func testDoesNothingInDevelopmentOrWithoutABundledHost() throws {
        XCTAssertTrue(register(.development).isEmpty)
        try FileManager.default.removeItem(at: appBundle.bundleURL.appendingPathComponent("Contents/MacOS/VaultLocalHubNativeHost"))
        XCTAssertTrue(register().isEmpty)
    }
}
