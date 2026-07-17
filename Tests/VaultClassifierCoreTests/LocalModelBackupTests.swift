import Foundation
import XCTest
@testable import VaultClassifierCore

final class LocalModelBackupTests: XCTestCase {
    func testPrivateSnapshotsRetainCurrentAndThreePriorModels() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let seed = try SeedPackageLoader.bundled()
        var state = LocalClassifierState()
        state.trainingCorpus.examples = [
            .init(
                cacheKey: "youtube:video-1",
                evidence: .init(platform: "youtube", entryID: "video-1", surface: .feed, evidence: .init(title: "Local test title")),
                positiveLeafTagIDs: ["content.entities.clash-royale"],
                origin: .explicitUser,
                taxonomyVersion: seed.package.taxonomyVersion,
                createdAtMilliseconds: 1,
                updatedAtMilliseconds: 1
            )
        ]
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
        XCTAssertEqual(newest.trainingExampleCount, 1)
        XCTAssertEqual(newest.packageChecksum, seed.checksum)
        let payload = try JSONDecoder().decode(
            LocalModelBackupPayload.self,
            from: Data(contentsOf: try XCTUnwrap(folders.first).appendingPathComponent("model-state.json"))
        )
        XCTAssertEqual(payload.trainingCorpus.examples.count, 1)
        let payloadText = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
        XCTAssertFalse(payloadText.contains("\"cache\""))
        XCTAssertFalse(payloadText.contains("\"ledger\""))

        let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
        let permissions = try XCTUnwrap((attributes[.posixPermissions] as? NSNumber)?.intValue)
        XCTAssertEqual(permissions & 0o777, 0o700)
    }

    func testBackupConfigurationRejectsRootAndAcceptsAnOwnedPath() throws {
        XCTAssertThrowsError(try LocalBackupConfiguration(isEnabled: true, directoryPath: "/").directoryURL())
        XCTAssertEqual(
            try LocalBackupConfiguration(isEnabled: true, directoryPath: "/tmp/vault-classifier-backups").directoryURL().path,
            "/tmp/vault-classifier-backups"
        )
    }
}
