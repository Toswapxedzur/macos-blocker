import Foundation
import XCTest
@testable import VaultClassifierCore

final class LocalModelBackupTests: XCTestCase {
    func testPrivateSnapshotsRetainCurrentAndThreePriorModels() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let seed = try SeedPackageLoader.bundled()
        var state = LocalClassifierState()
        XCTAssertTrue(state.workspaceCatalog.datasets[0].upsertCollectedEntry(.init(
            id: "entry-1",
            platformID: "youtube",
            entryID: "video-1",
            creatorID: "creator-1",
            creatorName: "Creator",
            entryType: "video",
            title: "Local test title"
        )))
        let backup = LocalModelBackup()
        for index in 1...5 {
            _ = try backup.backup(
                state: state,
                package: seed,
                in: root,
                at: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }

        let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.hasDirectoryPath && $0.lastPathComponent.hasPrefix("model-") }
        XCTAssertEqual(folders.count, LocalBackupConfiguration.retainedSnapshotCount)
        let newest = try XCTUnwrap(folders.compactMap { folder -> LocalModelBackupManifest? in
            try? JSONDecoder().decode(LocalModelBackupManifest.self, from: Data(contentsOf: folder.appendingPathComponent("manifest.json")))
        }.max(by: { $0.createdAtMilliseconds < $1.createdAtMilliseconds }))
        XCTAssertEqual(newest.createdAtMilliseconds, 5_000)
        XCTAssertEqual(newest.collectedEntryCount, 1)
        XCTAssertEqual(newest.videoClassificationCount, 0)
        XCTAssertEqual(newest.packageChecksum, seed.checksum)
        let payload = try JSONDecoder().decode(
            LocalModelBackupPayload.self,
            from: Data(contentsOf: try XCTUnwrap(folders.first).appendingPathComponent("model-state.json"))
        )
        XCTAssertEqual(payload.workspaceCatalog.datasets[0].collectedEntries.count, 1)
        let payloadObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as! [String: Any]
        // Retired fields are absent; the supported creatorMode value "cache" is valid.
        for retired in ["cache", "ledger", "trainingCorpus", "personalModel"] {
            XCTAssertNil(payloadObject[retired])
        }

        #if !os(Windows)
        let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
        let permissions = try XCTUnwrap((attributes[.posixPermissions] as? NSNumber)?.intValue)
        XCTAssertEqual(permissions & 0o777, 0o700)
        #endif
    }

    func testBackupConfigurationRejectsRootAndAcceptsAnOwnedPath() throws {
        XCTAssertThrowsError(try LocalBackupConfiguration(isEnabled: true, directoryPath: "/").directoryURL())
        #if os(Windows)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("vault-classifier-backups").path
        XCTAssertEqual(try LocalBackupConfiguration(isEnabled: true, directoryPath: path).directoryURL().path, path)
        #else
        XCTAssertEqual(
            try LocalBackupConfiguration(isEnabled: true, directoryPath: "/tmp/vault-classifier-backups").directoryURL().path,
            "/tmp/vault-classifier-backups"
        )
        #endif
    }
    func testFutureBackupManifestAndPayloadAreRefusedWithoutCleanup() throws {
        let metadata = #""storageMetadata":{"format":"classifier.backup-manifest","schemaVersion":99,"product":"mac","writtenByAppVersion":"9.0.0"}"#
        let raw = Data(("{" + metadata + ",\"createdAtMilliseconds\":1,\"packageChecksum\":\"keep\"}").utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(LocalModelBackupManifest.self, from: raw))
        XCTAssertThrowsError(try JSONDecoder().decode(LocalModelBackupPayload.self, from: Data(#"{"schemaVersion":99}"#.utf8)))
        let state = LocalClassifierState()
        let decoded = try JSONDecoder().decode(LocalModelBackupPayload.self, from: JSONEncoder().encode(LocalModelBackupPayload(state: state)))
        XCTAssertEqual(decoded.storageMetadata, state.storageMetadata)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let futureFolder = root.appendingPathComponent("model-future", isDirectory: true)
        try FileManager.default.createDirectory(at: futureFolder, withIntermediateDirectories: true)
        let manifestURL = futureFolder.appendingPathComponent("manifest.json")
        try raw.write(to: manifestURL)
        let payloadFolder = root.appendingPathComponent("model-future-payload", isDirectory: true)
        try FileManager.default.createDirectory(at: payloadFolder, withIntermediateDirectories: true)
        let currentManifest = LocalModelBackupManifest(createdAtMilliseconds: 0, activeModelIdentity: nil,
            packageChecksum: "keep", collectedEntryCount: 0, videoClassificationCount: 0)
        try JSONEncoder().encode(currentManifest).write(to: payloadFolder.appendingPathComponent("manifest.json"))
        let payloadURL = payloadFolder.appendingPathComponent("model-state.json")
        let futurePayload = Data(#"{"schemaVersion":99}"#.utf8)
        try futurePayload.write(to: payloadURL)
        let seed = try SeedPackageLoader.bundled()
        for index in 1...5 {
            _ = try LocalModelBackup().backup(state: state, package: seed, in: root,
                at: Date(timeIntervalSince1970: TimeInterval(index)))
        }
        XCTAssertEqual(try Data(contentsOf: manifestURL), raw)
        XCTAssertEqual(try Data(contentsOf: payloadURL), futurePayload)
        let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.hasDirectoryPath && $0.lastPathComponent.hasPrefix("model-") }
        XCTAssertEqual(folders.count, LocalBackupConfiguration.retainedSnapshotCount + 2)
    }

}
