import Foundation
import XCTest
@testable import VaultClassifierCore

final class LocalTrainingStoreTests: XCTestCase {
    private func makeCoordinator(at url: URL) throws -> LocalClassifierCoordinator {
        try LocalClassifierCoordinator(
            verifiedPackage: SeedPackageLoader.bundled(),
            stateFile: LocalStateFile(url: url),
            defaultPolicies: [StarterPolicies.clashRoyale]
        )
    }

    private func entry(_ id: String, title: String = "Clash Royale arena deck strategy") -> EntryEvidence {
        .init(
            requestID: "request-\(id)",
            platform: "youtube",
            entryID: id,
            surface: .feed,
            evidence: .init(title: title),
            policyIDs: [StarterPolicies.clashRoyale.id]
        )
    }

    func testExplicitLocalLabelsPersistBoundAndRebuildDeterministically() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stateURL = root.appendingPathComponent("state.json")
        let coordinator = try makeCoordinator(at: stateURL)
        var settings = coordinator.snapshot().settings
        settings.cacheCapacity = 2
        try coordinator.updateSettings(settings)

        let first = try coordinator.recordLocalTrainingExample(
            evidence: entry("one"),
            positiveLeafTagIDs: ["content.entities.clash-royale"],
            at: Date(timeIntervalSince1970: 10)
        )
        _ = try coordinator.recordLocalTrainingExample(
            evidence: entry("two", title: "Minecraft survival build"),
            positiveLeafTagIDs: ["content.entities.minecraft"],
            at: Date(timeIntervalSince1970: 20)
        )
        _ = try coordinator.recordLocalTrainingExample(
            evidence: entry("three", title: "Clash Royale tournament match"),
            positiveLeafTagIDs: ["content.entities.clash-royale"],
            negativeLeafTagIDs: ["content.entities.minecraft"],
            at: Date(timeIntervalSince1970: 30)
        )
        let bounded = coordinator.snapshot()
        XCTAssertEqual(bounded.trainingCorpus.examples.count, 2)
        XCTAssertFalse(bounded.trainingCorpus.examples.contains(where: { $0.id == first.id }))

        let run = try coordinator.retrainLocalModel(epochs: 3, at: Date(timeIntervalSince1970: 40))
        XCTAssertEqual(run.exampleCount, 2)
        XCTAssertEqual(run.labelUpdateCount, 9)
        let modelAfterFirstRun = coordinator.snapshot().personalModel
        _ = try coordinator.retrainLocalModel(epochs: 3, at: Date(timeIntervalSince1970: 50))
        XCTAssertEqual(coordinator.snapshot().personalModel, modelAfterFirstRun)

        let reloaded = try LocalStateFile(url: stateURL).load()
        XCTAssertEqual(reloaded.trainingCorpus.examples.count, 2)
        XCTAssertEqual(reloaded.trainingCorpus.lastRun?.exampleCount, 2)
        XCTAssertEqual(reloaded.personalModel, modelAfterFirstRun)
    }

    func testTrainingRejectsUnknownOrOverlappingLabelsWithoutPersisting() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = try makeCoordinator(at: root.appendingPathComponent("state.json"))

        XCTAssertThrowsError(
            try coordinator.recordLocalTrainingExample(
                evidence: entry("unknown"),
                positiveLeafTagIDs: ["content.entities.not-real"]
            )
        ) { error in
            XCTAssertEqual(error as? LocalTrainingError, .unknownLeafTag("content.entities.not-real"))
        }
        XCTAssertThrowsError(
            try coordinator.recordLocalTrainingExample(
                evidence: entry("overlap"),
                positiveLeafTagIDs: ["content.entities.clash-royale"],
                negativeLeafTagIDs: ["content.entities.clash-royale"]
            )
        ) { error in
            XCTAssertEqual(error as? LocalTrainingError, .overlappingLabels)
        }
        XCTAssertTrue(coordinator.snapshot().trainingCorpus.examples.isEmpty)
        XCTAssertTrue(coordinator.snapshot().personalModel.state.isEmpty)
    }

    func testRetrainedModelMovesOnlyTheExplicitPositiveLeaf() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = try makeCoordinator(at: root.appendingPathComponent("state.json"))
        let evidence = entry("training-target", title: "Clash Royale arena deck strategy")
        let before = try coordinator.classify(evidence)
        let beforeClash = try XCTUnwrap(before.scores.first(where: { $0.tagID == "content.entities.clash-royale" }))
        let beforeMinecraft = try XCTUnwrap(before.scores.first(where: { $0.tagID == "content.entities.minecraft" }))

        _ = try coordinator.recordLocalTrainingExample(
            evidence: evidence,
            positiveLeafTagIDs: ["content.entities.clash-royale"]
        )
        _ = try coordinator.retrainLocalModel(epochs: 6)
        let after = try coordinator.classify(entry("training-target-after", title: evidence.evidence.title ?? ""))
        let afterClash = try XCTUnwrap(after.scores.first(where: { $0.tagID == "content.entities.clash-royale" }))
        let afterMinecraft = try XCTUnwrap(after.scores.first(where: { $0.tagID == "content.entities.minecraft" }))

        XCTAssertGreaterThan(afterClash.directScore, beforeClash.directScore)
        XCTAssertEqual(afterMinecraft.directScore, beforeMinecraft.directScore, accuracy: 0.000_000_1)
    }

    func testEnabledLocalBackupSnapshotsACompletedRetrainingRun() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let backupDirectory = root.appendingPathComponent("backups", isDirectory: true)
        let coordinator = try makeCoordinator(at: root.appendingPathComponent("state.json"))
        try coordinator.updateLocalBackupConfiguration(.init(isEnabled: true, directoryPath: backupDirectory.path))
        _ = try coordinator.recordLocalTrainingExample(
            evidence: entry("backup-source"),
            positiveLeafTagIDs: ["content.entities.clash-royale"]
        )
        _ = try coordinator.retrainLocalModel(epochs: 2, at: Date(timeIntervalSince1970: 123))

        let snapshots = try FileManager.default.contentsOfDirectory(at: backupDirectory, includingPropertiesForKeys: nil)
            .filter { $0.hasDirectoryPath && $0.lastPathComponent.hasPrefix("model-") }
        XCTAssertEqual(snapshots.count, 1)
        let manifest = try JSONDecoder().decode(
            LocalModelBackupManifest.self,
            from: Data(contentsOf: try XCTUnwrap(snapshots.first).appendingPathComponent("manifest.json"))
        )
        XCTAssertEqual(manifest.trainingExampleCount, 1)
        XCTAssertEqual(manifest.createdAtMilliseconds, 123_000)
    }
}
