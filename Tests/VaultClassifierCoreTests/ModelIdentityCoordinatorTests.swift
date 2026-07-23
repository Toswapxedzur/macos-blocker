import CryptoKit
import Foundation
import XCTest
@testable import VaultClassifierCore

final class ModelIdentityCoordinatorTests: XCTestCase {
    private func seed() throws -> VerifiedSeedPackage { try SeedPackageLoader.bundled() }

    private func signedPackage(
        releaseSequence: Int64,
        releaseVersion: PackageReleaseVersion,
        modelVersion: String,
        privateKey: Curve25519.Signing.PrivateKey
    ) throws -> VerifiedModelPackage {
        var package = try seed().package
        package.modelVersion = modelVersion
        let payload = try JSONEncoder().encode(package)
        let manifest = ModelPackageManifest(
            packageID: package.packageID,
            releaseSequence: releaseSequence,
            releaseVersion: releaseVersion,
            taxonomyVersion: package.taxonomyVersion,
            modelVersion: package.modelVersion,
            payloadSHA256: PackageDigest.sha256Hex(payload),
            payloadByteCount: payload.count,
            publishedAtMilliseconds: 1_700_000_000_000 + releaseSequence,
            signingKeyID: "identity-test-key"
        )
        let signature = try privateKey.signature(for: PackageManifestCodec.canonicalData(for: manifest))
        let candidate = ModelPackageCandidate(
            signedManifest: .init(manifest: manifest, signature: signature),
            payload: payload
        )
        let keyring = try PackageSigningKeyring([
            .init(keyID: "identity-test-key", publicKey: privateKey.publicKey.rawRepresentation)
        ])
        return try PackageManifestValidator(keyring: keyring).verify(candidate)
    }

    private func stateFile() -> (root: URL, file: LocalStateFile) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return (root, .init(url: root.appendingPathComponent("state.json")))
    }

    private func entry(id: String = UUID().uuidString, title: String = "A general update") -> EntryEvidence {
        .init(
            requestID: "identity-request-\(id)",
            platform: "youtube",
            entryID: id,
            sourceID: "youtube:identity-channel",
            surface: .feed,
            evidence: .init(title: title),
            policyIDs: [StarterPolicies.clashRoyale.id]
        )
    }

    func testSeedFallbackInvalidatesDerivedStateButRetainsCacheAndLedger() throws {
        let fixture = stateFile()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let privateKey = Curve25519.Signing.PrivateKey()
        let signed = try signedPackage(
            releaseSequence: 2,
            releaseVersion: try .init(major: 1, minor: 1, patch: 0),
            modelVersion: "identity-signed-model",
            privateKey: privateKey
        )
        let signedCoordinator = try LocalClassifierCoordinator(
            verifiedModelPackage: signed,
            stateFile: fixture.file,
            defaultPolicies: [StarterPolicies.clashRoyale]
        )
        _ = try signedCoordinator.classify(entry(title: "Clash Royale deck guide"))
        _ = try signedCoordinator.classify(entry(title: "A general update"))
        let beforeFallback = signedCoordinator.snapshot()
        XCTAssertFalse(beforeFallback.sourceProfiles.isEmpty)

        let seedCoordinator = try LocalClassifierCoordinator(
            verifiedPackage: seed(),
            stateFile: fixture.file,
            defaultPolicies: [StarterPolicies.clashRoyale]
        )
        let afterFallback = seedCoordinator.snapshot()
        XCTAssertEqual(afterFallback.cache.count, beforeFallback.cache.count)
        XCTAssertEqual(afterFallback.ledger, beforeFallback.ledger)
        XCTAssertTrue(afterFallback.sourceProfiles.isEmpty)
        XCTAssertNil(afterFallback.cacheBackfill)
        XCTAssertEqual(afterFallback.activeModelIdentity?.kind, .seed)
        XCTAssertTrue(afterFallback.cache.allSatisfy { $0.modelIdentity != afterFallback.activeModelIdentity })
    }

    func testVerifiedReopenSchedulesOrphanedProvisionalRowsForExplicitRecovery() throws {
        let fixture = stateFile()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let privateKey = Curve25519.Signing.PrivateKey()
        let signed = try signedPackage(
            releaseSequence: 2,
            releaseVersion: try .init(major: 1, minor: 1, patch: 0),
            modelVersion: "identity-provisional-model",
            privateKey: privateKey
        )
        let evidence = entry(id: "orphaned-provisional")
        var engine = try LocalClassifierEngine(
            verifiedPackage: signed.seedPackage,
            policies: [StarterPolicies.clashRoyale]
        )
        let result = try engine.classify(evidence)
        let identity = ActiveModelIdentity(signed: signed)
        let key = LocalClassifierState.cacheKey(for: evidence)
        let persisted = LocalClassifierState(
            policies: [StarterPolicies.clashRoyale],
            activeModelIdentity: identity,
            highestAcceptedSignedRelease: .init(manifest: signed.manifest),
            cache: [.init(
                key: key,
                savedAt: Date(timeIntervalSince1970: 1),
                evidence: evidence,
                result: result,
                modelIdentity: identity,
                replayState: .awaitingCausalReplay
            )],
            ledger: [.init(cacheKey: key, result: result)]
        )
        try fixture.file.save(persisted)

        let reopened = try LocalClassifierCoordinator(
            verifiedModelPackage: signed,
            stateFile: fixture.file,
            defaultPolicies: [StarterPolicies.clashRoyale]
        )
        let recovered = reopened.snapshot()
        XCTAssertEqual(recovered.cache.count, 1)
        XCTAssertEqual(recovered.ledger, persisted.ledger)
        let continuation = try XCTUnwrap(recovered.cacheBackfill)
        XCTAssertFalse(continuation.isStarted)
        XCTAssertEqual(continuation.releaseSequence, signed.manifest.releaseSequence)
        XCTAssertEqual(continuation.payloadSHA256, signed.manifest.payloadSHA256)

        let directRefresh = try reopened.backfillCachedEntries(.init(maximumEntries: 1))
        XCTAssertEqual(directRefresh.directRefreshedEntries, 1)
        XCTAssertEqual(directRefresh.causallyReplayedEntries, 0)
        XCTAssertFalse(directRefresh.isComplete)

        let causalReplay = try reopened.backfillCachedEntries(.init(maximumEntries: 1))
        XCTAssertEqual(causalReplay.directRefreshedEntries, 0)
        XCTAssertEqual(causalReplay.causallyReplayedEntries, 1)
        XCTAssertTrue(causalReplay.isComplete)
        XCTAssertEqual(reopened.snapshot().cache.first?.replayState, .causallyReplayed)
    }

    func testBootstrapRejectsPersistedPolicyThatDoesNotExistInCurrentTaxonomy() throws {
        let fixture = stateFile()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let invalid = NamedPolicy(
            id: "invalid.persisted.policy",
            name: "Invalid persisted policy",
            includeAnyTagIDs: ["content.entities.removed-tag"],
            feedAction: .dim,
            pageAction: .block
        )
        try fixture.file.save(.init(policies: [invalid]))
        XCTAssertThrowsError(try LocalClassifierCoordinator(verifiedPackage: seed(), stateFile: fixture.file)) { error in
            XCTAssertEqual(
                error as? PolicyValidationError,
                .unknownTag(policyID: invalid.id, tagID: "content.entities.removed-tag")
            )
        }
    }

    func testDirectActivationUsesHighWaterAndRollbackRequiresRecordedIdentity() throws {
        let fixture = stateFile()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let privateKey = Curve25519.Signing.PrivateKey()
        let first = try signedPackage(
            releaseSequence: 2,
            releaseVersion: try .init(major: 1, minor: 1, patch: 0),
            modelVersion: "identity-model-2",
            privateKey: privateKey
        )
        let second = try signedPackage(
            releaseSequence: 3,
            releaseVersion: try .init(major: 1, minor: 2, patch: 0),
            modelVersion: "identity-model-3",
            privateKey: privateKey
        )
        let neverActivated = try signedPackage(
            releaseSequence: 1,
            releaseVersion: try .init(major: 1, minor: 0, patch: 0),
            modelVersion: "identity-model-1",
            privateKey: privateKey
        )
        let coordinator = try LocalClassifierCoordinator(
            verifiedPackage: seed(),
            stateFile: fixture.file,
            defaultPolicies: [StarterPolicies.clashRoyale]
        )
        try coordinator.activateVerifiedModelPackage(first)
        try coordinator.activateVerifiedModelPackage(second)

        XCTAssertThrowsError(try coordinator.activateVerifiedModelPackage(first)) { error in
            guard case .nonMonotonicUpdate = error as? PackageManifestValidationError else {
                return XCTFail("Expected high-water rejection, got \(error)")
            }
        }
        XCTAssertThrowsError(try coordinator.activateRecordedRollbackModelPackage(neverActivated)) { error in
            guard case .nonMonotonicUpdate = error as? PackageManifestValidationError else {
                return XCTFail("Expected recorded-rollback rejection, got \(error)")
            }
        }

        try coordinator.activateRecordedRollbackModelPackage(first)
        let afterRollback = coordinator.snapshot()
        XCTAssertEqual(afterRollback.activeModelIdentity?.releaseSequence, 2)
        XCTAssertEqual(afterRollback.highestAcceptedSignedRelease?.releaseSequence, 3)
        XCTAssertThrowsError(try coordinator.activateVerifiedModelPackage(first))
    }

    func testBootstrapRejectsUnrecordedBelowHighWaterIdentityEvenWhenItWasPersistedActive() throws {
        let fixture = stateFile()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let privateKey = Curve25519.Signing.PrivateKey()
        let old = try signedPackage(
            releaseSequence: 2,
            releaseVersion: try .init(major: 1, minor: 1, patch: 0),
            modelVersion: "identity-old-model",
            privateKey: privateKey
        )
        let high = try signedPackage(
            releaseSequence: 3,
            releaseVersion: try .init(major: 1, minor: 2, patch: 0),
            modelVersion: "identity-high-model",
            privateKey: privateKey
        )
        try fixture.file.save(.init(
            policies: [StarterPolicies.clashRoyale],
            activeModelIdentity: .init(signed: old),
            highestAcceptedSignedRelease: .init(manifest: high.manifest),
            signedRollbackIdentities: []
        ))
        XCTAssertThrowsError(try LocalClassifierCoordinator(
            verifiedModelPackage: old,
            stateFile: fixture.file,
            defaultPolicies: [StarterPolicies.clashRoyale]
        )) { error in
            guard case .nonMonotonicUpdate = error as? PackageManifestValidationError else {
                return XCTFail("Expected recorded-rollback requirement, got \(error)")
            }
        }
    }
}
