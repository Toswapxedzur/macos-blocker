import CryptoKit
import Foundation
import XCTest
@testable import VaultClassifierCore

final class CacheBackfillTests: XCTestCase {
    private func seed() throws -> VerifiedSeedPackage { try SeedPackageLoader.bundled() }

    private func entry(
        id: String,
        title: String,
        sourceID: String = "youtube:channel:backfill"
    ) -> EntryEvidence {
        .init(
            requestID: "request-\(id)",
            platform: "youtube",
            entryID: id,
            sourceID: sourceID,
            surface: .feed,
            evidence: .init(title: title),
            policyIDs: [StarterPolicies.clashRoyale.id]
        )
    }

    private func verifiedReplacement(
        modelVersion: String = "vault-model-backfill",
        releaseSequence: Int64 = 2
    ) throws -> VerifiedModelPackage {
        var package = try seed().package
        package.modelVersion = modelVersion
        let payload = try JSONEncoder().encode(package)
        let privateKey = Curve25519.Signing.PrivateKey()
        let manifest = ModelPackageManifest(
            packageID: package.packageID,
            releaseSequence: releaseSequence,
            releaseVersion: try .init(major: 1, minor: Int(releaseSequence - 1), patch: 0),
            taxonomyVersion: package.taxonomyVersion,
            modelVersion: package.modelVersion,
            payloadSHA256: PackageDigest.sha256Hex(payload),
            payloadByteCount: payload.count,
            publishedAtMilliseconds: 1_700_000_000_000,
            signingKeyID: "backfill-test-key"
        )
        let signature = try privateKey.signature(for: PackageManifestCodec.canonicalData(for: manifest))
        let candidate = ModelPackageCandidate(
            signedManifest: .init(manifest: manifest, signature: signature),
            payload: payload
        )
        let keyring = try PackageSigningKeyring([
            .init(keyID: "backfill-test-key", publicKey: privateKey.publicKey.rawRepresentation)
        ])
        return try PackageManifestValidator(keyring: keyring).verify(candidate)
    }

    private func temporaryStateFile() -> (root: URL, file: LocalStateFile) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        return (root, LocalStateFile(url: root.appendingPathComponent("state.json")))
    }

    func testDirectRefreshesNewestFirstThenCausalReplayRebuildsFIFOSourcePrior() throws {
        let fixture = temporaryStateFile()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.file.save(.init(settings: .init(cacheCapacity: 2)))
        let coordinator = try LocalClassifierCoordinator(
            verifiedPackage: seed(),
            stateFile: fixture.file,
            defaultPolicies: [StarterPolicies.clashRoyale]
        )

        // The first item proves that normal FIFO retention already evicts only
        // on capacity. The two retained rows share a source and are replayed
        // in their stable retained order.
        _ = try coordinator.classify(entry(id: "oldest", title: "Clash Royale ranked match"))
        _ = try coordinator.classify(entry(id: "retained-first", title: "Clash Royale deck guide"))
        _ = try coordinator.classify(entry(id: "retained-second", title: "Clash Royale gameplay"))
        let beforeActivation = coordinator.snapshot()
        XCTAssertEqual(beforeActivation.cache.count, 2)
        XCTAssertEqual(beforeActivation.cache.map(\.key), [
            LocalClassifierState.cacheKey(for: entry(id: "retained-first", title: "Clash Royale deck guide")),
            LocalClassifierState.cacheKey(for: entry(id: "retained-second", title: "Clash Royale gameplay")),
        ])
        let preservedLedger = beforeActivation.ledger
        let preservedCacheKeys = beforeActivation.cache.map(\.key)
        let preservedCacheDates = beforeActivation.cache.map(\.savedAt)
        let preservedCacheEvidence = beforeActivation.cache.map(\.evidence)

        try coordinator.activateVerifiedModelPackage(try verifiedReplacement())
        let afterActivation = coordinator.snapshot()
        XCTAssertEqual(afterActivation.cache.map(\.key), preservedCacheKeys, "Activation must not auto-run cache work or evict rows.")
        XCTAssertEqual(afterActivation.cache.map(\.savedAt), preservedCacheDates)
        XCTAssertEqual(afterActivation.cache.map(\.evidence), preservedCacheEvidence)
        XCTAssertTrue(afterActivation.cache.allSatisfy { $0.replayState == .awaitingCausalReplay })
        XCTAssertEqual(afterActivation.ledger, preservedLedger, "The historical ledger is immutable during package activation/backfill.")
        XCTAssertFalse(try XCTUnwrap(afterActivation.cacheBackfill).isStarted)

        // Stage one intentionally starts from the newest retained row. Its
        // direct-only result cannot see the older row's stale source profile.
        let firstBatch = try coordinator.backfillCachedEntries(try .init(maximumEntries: 1), at: Date(timeIntervalSince1970: 100))
        XCTAssertTrue(firstBatch.startedBackfill)
        XCTAssertEqual(firstBatch.reclassifiedEntries, 1)
        XCTAssertEqual(firstBatch.directRefreshedEntries, 1)
        XCTAssertEqual(firstBatch.causallyReplayedEntries, 0)
        XCTAssertEqual(firstBatch.phase, .directRefresh)
        XCTAssertEqual(firstBatch.remainingEntries, 3)
        XCTAssertFalse(firstBatch.isComplete)

        let afterFirstBatch = coordinator.snapshot()
        XCTAssertEqual(afterFirstBatch.cache.count, 2)
        XCTAssertEqual(afterFirstBatch.cache.map(\.key), preservedCacheKeys, "Backfill must retain FIFO order exactly.")
        XCTAssertEqual(afterFirstBatch.cache.map(\.savedAt), preservedCacheDates, "Backfill must retain timestamps exactly.")
        XCTAssertEqual(afterFirstBatch.cache.map(\.evidence), preservedCacheEvidence, "Backfill must retain evidence exactly.")
        XCTAssertEqual(afterFirstBatch.ledger, preservedLedger, "Backfill must not append or rewrite decision-ledger history.")
        XCTAssertEqual(afterFirstBatch.cache[0].result.modelVersion, beforeActivation.cache[0].result.modelVersion)
        XCTAssertEqual(afterFirstBatch.cache[1].result.modelVersion, "vault-model-backfill")
        XCTAssertEqual(afterFirstBatch.cache[1].replayState, .awaitingCausalReplay)
        let newestDirectScore = try XCTUnwrap(afterFirstBatch.cache[1].result.scores.first { $0.tagID == "content.entities.clash-royale" })
        XCTAssertNil(newestDirectScore.sourceScore, "Newest-first direct refresh must not reuse an old or future source profile.")

        let secondBatch = try coordinator.backfillCachedEntries(try .init(maximumEntries: 1), at: Date(timeIntervalSince1970: 101))
        XCTAssertFalse(secondBatch.startedBackfill)
        XCTAssertEqual(secondBatch.reclassifiedEntries, 1)
        XCTAssertEqual(secondBatch.directRefreshedEntries, 1)
        XCTAssertEqual(secondBatch.phase, .causalReplay)
        XCTAssertEqual(secondBatch.remainingEntries, 2)
        XCTAssertFalse(secondBatch.isComplete)

        let afterDirectStage = coordinator.snapshot()
        XCTAssertEqual(afterDirectStage.cache.map(\.key), preservedCacheKeys)
        XCTAssertTrue(afterDirectStage.cache.allSatisfy { $0.result.modelVersion == "vault-model-backfill" })
        XCTAssertTrue(afterDirectStage.cache.allSatisfy { $0.replayState == .awaitingCausalReplay })
        XCTAssertTrue(afterDirectStage.cache.allSatisfy { cached in
            cached.result.scores.first(where: { $0.tagID == "content.entities.clash-royale" })?.sourceScore == nil
        })

        let firstCausalBatch = try coordinator.backfillCachedEntries(try .init(maximumEntries: 1), at: Date(timeIntervalSince1970: 102))
        XCTAssertEqual(firstCausalBatch.phase, .causalReplay)
        XCTAssertEqual(firstCausalBatch.causallyReplayedEntries, 1)
        XCTAssertEqual(firstCausalBatch.remainingEntries, 1)
        let afterFirstCausalBatch = coordinator.snapshot()
        XCTAssertEqual(afterFirstCausalBatch.cache[0].replayState, .causallyReplayed)
        XCTAssertEqual(afterFirstCausalBatch.cache[1].replayState, .awaitingCausalReplay)
        let firstCausalScore = try XCTUnwrap(afterFirstCausalBatch.cache[0].result.scores.first { $0.tagID == "content.entities.clash-royale" })
        XCTAssertNil(firstCausalScore.sourceScore, "The oldest causal row must score before adding its own source observation.")

        let finalBatch = try coordinator.backfillCachedEntries(try .init(maximumEntries: 1), at: Date(timeIntervalSince1970: 103))
        XCTAssertEqual(finalBatch.causallyReplayedEntries, 1)
        XCTAssertEqual(finalBatch.remainingEntries, 0)
        XCTAssertTrue(finalBatch.isComplete)

        let completed = coordinator.snapshot()
        XCTAssertNil(completed.cacheBackfill)
        XCTAssertEqual(completed.ledger, preservedLedger)
        XCTAssertEqual(completed.cache.map(\.key), preservedCacheKeys)
        XCTAssertEqual(completed.cache.map(\.savedAt), preservedCacheDates)
        XCTAssertEqual(completed.cache.map(\.evidence), preservedCacheEvidence)
        XCTAssertTrue(completed.cache.allSatisfy { $0.result.modelVersion == "vault-model-backfill" })
        XCTAssertTrue(completed.cache.allSatisfy { $0.replayState == .causallyReplayed })
        let secondClashScore = try XCTUnwrap(completed.cache[1].result.scores.first { $0.tagID == "content.entities.clash-royale" })
        XCTAssertNotNil(secondClashScore.sourceScore, "Later retained evidence may use only the earlier replayed source observation.")
        XCTAssertEqual(completed.sourceProfiles["youtube:channel:backfill"]?.observations.count, 2)
    }

    func testBackfillRequiresAVerifiedActivationAndRollsBackTheWholeBatchOnFailure() throws {
        let fixture = temporaryStateFile()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let valid = entry(id: "valid", title: "Clash Royale ranked match")
        var originalEngine = try LocalClassifierEngine(verifiedPackage: seed(), policies: [StarterPolicies.clashRoyale])
        let validResult = try originalEngine.classify(valid)
        let invalid = EntryEvidence(
            requestID: "request-invalid",
            platform: "youtube",
            entryID: "invalid",
            sourceID: "youtube:channel:backfill",
            surface: .feed,
            evidence: .init(),
            policyIDs: [StarterPolicies.clashRoyale.id]
        )
        let invalidResult = validResult
        let validKey = LocalClassifierState.cacheKey(for: valid)
        let invalidKey = LocalClassifierState.cacheKey(for: invalid)
        let initialState = LocalClassifierState(
            policies: [StarterPolicies.clashRoyale],
            sourceProfiles: originalEngine.sourceProfiles,
            cache: [
                .init(key: validKey, savedAt: Date(timeIntervalSince1970: 1), evidence: valid, result: validResult),
                .init(key: invalidKey, savedAt: Date(timeIntervalSince1970: 2), evidence: invalid, result: invalidResult),
            ],
            ledger: [DecisionLedgerEntry(cacheKey: validKey, result: validResult)]
        )
        try fixture.file.save(initialState)
        let coordinator = try LocalClassifierCoordinator(verifiedPackage: seed(), stateFile: fixture.file)

        XCTAssertThrowsError(try coordinator.backfillCachedEntries(try .init(maximumEntries: 2))) { error in
            XCTAssertEqual(error as? CacheBackfillError, .noEligibleVerifiedPackage)
        }

        try coordinator.activateVerifiedModelPackage(try verifiedReplacement(modelVersion: "vault-model-atomic"))
        let beforeFailedBatch = coordinator.snapshot()
        XCTAssertThrowsError(try coordinator.backfillCachedEntries(try .init(maximumEntries: 2))) { error in
            guard case .invalidEvidence(.missing("evidence")) = error as? ClassifierEngineError else {
                return XCTFail("Expected invalid cached evidence to abort atomically, got \(error)")
            }
        }
        XCTAssertEqual(coordinator.snapshot(), beforeFailedBatch, "A failed item must not publish a partially replayed cache/profile batch.")
        XCTAssertEqual(try fixture.file.load(), beforeFailedBatch, "A failed batch must not persist a partial update.")
    }

    func testMutationRestartsBothStages() throws {
        let fixture = temporaryStateFile()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = try LocalClassifierCoordinator(
            verifiedPackage: seed(),
            stateFile: fixture.file,
            defaultPolicies: [StarterPolicies.clashRoyale]
        )
        _ = try coordinator.classify(entry(id: "first-allow", title: "A general update"))
        _ = try coordinator.classify(entry(id: "second-allow", title: "Another general update"))
        try coordinator.activateVerifiedModelPackage(try verifiedReplacement(modelVersion: "vault-model-backfill-restart"))

        // Direct stage is newest-first.
        _ = try coordinator.backfillCachedEntries(try .init(maximumEntries: 1))
        let directStage = try coordinator.backfillCachedEntries(try .init(maximumEntries: 1))
        XCTAssertEqual(directStage.phase, .causalReplay)

        // The oldest FIFO result becomes final while the newer row is still
        // awaiting causal replay.
        let firstCausal = try coordinator.backfillCachedEntries(try .init(maximumEntries: 1))
        XCTAssertEqual(firstCausal.causallyReplayedEntries, 1)
        XCTAssertFalse(firstCausal.isComplete)

        // A settings change invalidates both partial stages, marks every row
        // provisional again, and requires a fresh explicit replay.
        var changedSettings = coordinator.snapshot().settings
        changedSettings.cacheCapacity = max(1, changedSettings.cacheCapacity - 1)
        try coordinator.updateSettings(changedSettings)
        let restarted = coordinator.snapshot()
        let progress = try XCTUnwrap(restarted.cacheBackfill)
        XCTAssertFalse(progress.isStarted)
        XCTAssertEqual(progress.phase, .directRefresh)
        XCTAssertTrue(progress.directRefreshPendingCacheKeys.isEmpty)
        XCTAssertTrue(progress.causalReplayPendingCacheKeys.isEmpty)
        XCTAssertTrue(restarted.cache.allSatisfy { $0.replayState == .awaitingCausalReplay })

        // An ordinary cache mutation follows the same restart contract; the
        // next explicit batch begins a new newest-first direct phase.
        _ = try coordinator.classify(entry(id: "third-allow", title: "A third general update"))
        XCTAssertFalse(try XCTUnwrap(coordinator.snapshot().cacheBackfill).isStarted)
        let resumed = try coordinator.backfillCachedEntries(try .init(maximumEntries: 1))
        XCTAssertEqual(resumed.phase, .directRefresh)
        XCTAssertEqual(resumed.directRefreshedEntries, 1)
    }

    func testSingleCachedEntryKeepsDirectAndCausalWorkSeparatelyBounded() throws {
        let fixture = temporaryStateFile()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = try LocalClassifierCoordinator(
            verifiedPackage: seed(),
            stateFile: fixture.file,
            defaultPolicies: [StarterPolicies.clashRoyale]
        )
        _ = try coordinator.classify(entry(id: "only", title: "Clash Royale ranked match"))
        try coordinator.activateVerifiedModelPackage(try verifiedReplacement(modelVersion: "vault-model-one-row"))

        let direct = try coordinator.backfillCachedEntries(try .init(maximumEntries: 1))
        XCTAssertEqual(direct.reclassifiedEntries, 1)
        XCTAssertEqual(direct.directRefreshedEntries, 1)
        XCTAssertEqual(direct.causallyReplayedEntries, 0)
        XCTAssertEqual(direct.phase, .causalReplay)
        XCTAssertEqual(direct.remainingEntries, 1)
        XCTAssertFalse(direct.isComplete)
        XCTAssertEqual(coordinator.snapshot().cache.first?.replayState, .awaitingCausalReplay)

        let causal = try coordinator.backfillCachedEntries(try .init(maximumEntries: 1))
        XCTAssertEqual(causal.reclassifiedEntries, 1)
        XCTAssertEqual(causal.directRefreshedEntries, 0)
        XCTAssertEqual(causal.causallyReplayedEntries, 1)
        XCTAssertTrue(causal.isComplete)
        XCTAssertEqual(coordinator.snapshot().cache.first?.replayState, .causallyReplayed)
    }

    func testCorruptDirectAndCausalQueueOrderRestartsFromCanonicalFIFO() throws {
        let fixture = temporaryStateFile()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = try LocalClassifierCoordinator(
            verifiedPackage: seed(),
            stateFile: fixture.file,
            defaultPolicies: [StarterPolicies.clashRoyale]
        )
        _ = try coordinator.classify(entry(id: "oldest", title: "Clash Royale ranked match"))
        _ = try coordinator.classify(entry(id: "middle", title: "Clash Royale deck guide"))
        _ = try coordinator.classify(entry(id: "newest", title: "Clash Royale gameplay"))
        let replacement = try verifiedReplacement(modelVersion: "vault-model-canonical-queues")
        try coordinator.activateVerifiedModelPackage(replacement)

        _ = try coordinator.backfillCachedEntries(try .init(maximumEntries: 1))
        var malformedDirect = try fixture.file.load()
        var directProgress = try XCTUnwrap(malformedDirect.cacheBackfill)
        XCTAssertEqual(directProgress.phase, .directRefresh)
        directProgress.directRefreshPendingCacheKeys.swapAt(0, 1)
        malformedDirect.cacheBackfill = directProgress
        try fixture.file.save(malformedDirect)

        let recoveredDirect = try LocalClassifierCoordinator(
            verifiedModelPackage: replacement,
            stateFile: fixture.file,
            defaultPolicies: [StarterPolicies.clashRoyale]
        )
        let freshDirect = try XCTUnwrap(recoveredDirect.snapshot().cacheBackfill)
        XCTAssertFalse(freshDirect.isStarted)
        XCTAssertEqual(freshDirect.phase, .directRefresh)
        XCTAssertTrue(freshDirect.directRefreshPendingCacheKeys.isEmpty)
        XCTAssertTrue(freshDirect.causalReplayPendingCacheKeys.isEmpty)

        let directAll = try recoveredDirect.backfillCachedEntries(try .init(maximumEntries: 3))
        XCTAssertEqual(directAll.reclassifiedEntries, 3)
        XCTAssertEqual(directAll.causallyReplayedEntries, 0)
        XCTAssertEqual(directAll.phase, .causalReplay)
        var malformedCausal = try fixture.file.load()
        var causalProgress = try XCTUnwrap(malformedCausal.cacheBackfill)
        XCTAssertEqual(causalProgress.phase, .causalReplay)
        causalProgress.causalReplayPendingCacheKeys.swapAt(0, 2)
        malformedCausal.cacheBackfill = causalProgress
        try fixture.file.save(malformedCausal)

        let recoveredCausal = try LocalClassifierCoordinator(
            verifiedModelPackage: replacement,
            stateFile: fixture.file,
            defaultPolicies: [StarterPolicies.clashRoyale]
        )
        let freshCausal = try XCTUnwrap(recoveredCausal.snapshot().cacheBackfill)
        XCTAssertFalse(freshCausal.isStarted)
        XCTAssertEqual(freshCausal.phase, .directRefresh)
        XCTAssertTrue(freshCausal.directRefreshPendingCacheKeys.isEmpty)
        XCTAssertTrue(freshCausal.causalReplayPendingCacheKeys.isEmpty)

        let canonicalFIFO = recoveredCausal.snapshot().cache.map(\.key)
        _ = try recoveredCausal.backfillCachedEntries(try .init(maximumEntries: 1))
        let resumed = try XCTUnwrap(recoveredCausal.snapshot().cacheBackfill)
        XCTAssertEqual(
            resumed.directRefreshPendingCacheKeys,
            Array(canonicalFIFO.reversed().dropFirst()),
            "Recovery must reconstruct newest-first direct work from the retained FIFO cache."
        )
    }

    func testInterruptedBackfillRequiresTheExactVerifiedManifestToResume() throws {
        let fixture = temporaryStateFile()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = try LocalClassifierCoordinator(
            verifiedPackage: seed(),
            stateFile: fixture.file,
            defaultPolicies: [StarterPolicies.clashRoyale]
        )
        _ = try coordinator.classify(entry(id: "first", title: "Clash Royale ranked match"))
        _ = try coordinator.classify(entry(id: "second", title: "Clash Royale gameplay"))

        let firstRelease = try verifiedReplacement(modelVersion: "vault-model-same-name", releaseSequence: 2)
        try coordinator.activateVerifiedModelPackage(firstRelease)
        _ = try coordinator.backfillCachedEntries(try .init(maximumEntries: 1))
        XCTAssertTrue(try XCTUnwrap(coordinator.snapshot().cacheBackfill).isStarted)

        // The payload/model display names are intentionally the same. A newer
        // signed manifest must still not resume the old release's continuation.
        let differentRelease = try verifiedReplacement(modelVersion: "vault-model-same-name", releaseSequence: 3)
        let reopened = try LocalClassifierCoordinator(
            verifiedModelPackage: differentRelease,
            stateFile: fixture.file,
            defaultPolicies: [StarterPolicies.clashRoyale]
        )
        let recovery = try XCTUnwrap(reopened.snapshot().cacheBackfill)
        XCTAssertFalse(recovery.isStarted)
        XCTAssertEqual(recovery.releaseSequence, differentRelease.manifest.releaseSequence)
        XCTAssertEqual(recovery.payloadSHA256, differentRelease.manifest.payloadSHA256)
        let firstRecoveryBatch = try reopened.backfillCachedEntries(try .init(maximumEntries: 1))
        XCTAssertTrue(firstRecoveryBatch.startedBackfill)
        XCTAssertEqual(firstRecoveryBatch.directRefreshedEntries, 1)
    }

    func testLegacyUnboundContinuationDecodesButCannotResume() throws {
        let legacyState = Data("""
        {
          "packageID": "vault-seed-1",
          "modelVersion": "vault-model-1",
          "pendingCacheKeys": ["youtube:legacy"],
          "completedEntryCount": 1
        }
        """.utf8)

        let progress = try JSONDecoder().decode(CacheBackfillProgress.self, from: legacyState)
        XCTAssertEqual(progress.releaseSequence, 0)
        XCTAssertEqual(progress.payloadSHA256, "")
        XCTAssertFalse(progress.isStarted)
    }
}
