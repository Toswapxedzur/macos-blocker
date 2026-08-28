import CryptoKit
import Foundation
import XCTest
@testable import VaultClassifierCore

final class PolicyManagementTests: XCTestCase {
    private func seed() throws -> VerifiedSeedPackage { try SeedPackageLoader.bundled() }

    private func verifiedCandidate(from package: SeedModelPackage) throws -> VerifiedModelPackage {
        let privateKey = Curve25519.Signing.PrivateKey()
        let payload = try JSONEncoder().encode(package)
        let manifest = ModelPackageManifest(
            packageID: package.packageID,
            releaseSequence: 1,
            releaseVersion: try .init(major: 1, minor: 0, patch: 0),
            taxonomyVersion: package.taxonomyVersion,
            modelVersion: package.modelVersion,
            payloadSHA256: PackageDigest.sha256Hex(payload),
            payloadByteCount: payload.count,
            publishedAtMilliseconds: 1_700_000_000_000,
            signingKeyID: "policy-test-key"
        )
        let signature = try privateKey.signature(for: PackageManifestCodec.canonicalData(for: manifest))
        let candidate = ModelPackageCandidate(
            signedManifest: .init(manifest: manifest, signature: signature),
            payload: payload
        )
        let keyring = try PackageSigningKeyring([
            .init(keyID: "policy-test-key", publicKey: privateKey.publicKey.rawRepresentation)
        ])
        return try PackageManifestValidator(keyring: keyring).verify(candidate)
    }

    func testPolicyCatalogAcceptsKnownAncestorCriteriaAndRejectsUnsafePolicies() throws {
        let taxonomy = try seed().taxonomy
        let catalog = PolicyCatalog(taxonomy: taxonomy)
        let valid = NamedPolicy(
            id: "gaming-focus",
            name: "Gaming focus",
            includeAnyTagIDs: ["content.topics.gaming"],
            excludeTagIDs: ["content.entities.clash-royale"]
        )
        XCTAssertNoThrow(try catalog.validate([valid]))

        XCTAssertThrowsError(try catalog.validate(.init(id: "", name: "Missing", includeAnyTagIDs: ["content"])))
        XCTAssertThrowsError(try catalog.validate(.init(id: "anything", name: "Anything", includeAnyTagIDs: [])))
        XCTAssertThrowsError(try catalog.validate(.init(id: "unknown", name: "Unknown", includeAnyTagIDs: ["content.not-real"])))
        XCTAssertThrowsError(try catalog.validate([valid, valid]))
    }

    func testPolicyCatalogRejectsIdentifiersWithSurroundingWhitespace() throws {
        let taxonomy = try seed().taxonomy
        let catalog = PolicyCatalog(taxonomy: taxonomy)
        let policy = NamedPolicy(
            id: "  gaming-focus\n",
            name: "Gaming focus",
            includeAnyTagIDs: ["content.topics.gaming"]
        )

        XCTAssertThrowsError(try catalog.validate(policy)) { error in
            XCTAssertEqual(error as? PolicyValidationError, .nonCanonicalID(policy.id))
        }
    }

    func testCoordinatorRejectsInvalidPolicyUpdateWithoutDiscardingSavedPolicies() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = StarterPolicies.clashRoyale
        let coordinator = try LocalClassifierCoordinator(
            verifiedPackage: seed(),
            stateFile: LocalStateFile(url: root.appendingPathComponent("state.json")),
            defaultPolicies: [original]
        )
        XCTAssertThrowsError(try coordinator.replacePolicies([
            .init(id: "bad", name: "Bad", includeAnyTagIDs: ["not-in-tree"])
        ]))
        XCTAssertEqual(coordinator.policies(), [original])
    }

    func testPackageSwapKeepsPoliciesSafe() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = StarterPolicies.clashRoyale
        let coordinator = try LocalClassifierCoordinator(
            verifiedPackage: seed(),
            stateFile: LocalStateFile(url: root.appendingPathComponent("state.json")),
            defaultPolicies: [original]
        )
        var incompatible = try seed().package
        incompatible.taxonomy.removeAll { $0.id == "content.entities.clash-royale" }
        let replacement = try verifiedCandidate(from: incompatible)
        XCTAssertThrowsError(try coordinator.activateVerifiedModelPackage(replacement))
        XCTAssertEqual(coordinator.policies(), [original])
    }

    // MARK: - Content-block verdict resolution (creator → content rewire)

    private func obs(_ id: String, _ c: Int) -> NamedPolicy.TagObservation {
        NamedPolicy.TagObservation(tagID: id, confidence: c)
    }

    func testExcludePolicyDisallowsMatchingTagAboveFloor() {
        let policy = NamedPolicy(id: "no-gaming", name: "No gaming", excludeTagIDs: ["gaming"],
                                 feedAction: .dim, pageAction: .block, confidenceFloor: 4)
        // Gaming at conf5 → disallowed → dim on feed, block on page.
        let hit = policy.resolveActions(for: [obs("gaming", 5)])
        XCTAssertEqual(hit.feed, .dim)
        XCTAssertEqual(hit.page, .block)
        // Same tag but below the floor → ignored → allowed.
        let weak = policy.resolveActions(for: [obs("gaming", 3)])
        XCTAssertEqual(weak.feed, .allow)
        XCTAssertEqual(weak.page, .allow)
    }

    func testIncludeOnlyPolicyDisallowsNonMatchingContent() {
        let policy = NamedPolicy(id: "only-cr", name: "Only Clash Royale",
                                 includeAnyTagIDs: ["clash-royale"], feedAction: .dim, pageAction: .block,
                                 confidenceFloor: 4)
        XCTAssertEqual(policy.resolveActions(for: [obs("clash-royale", 5)]).feed, .allow)   // wanted → shown
        XCTAssertEqual(policy.resolveActions(for: [obs("gaming", 5)]).feed, .dim)           // not wanted → dimmed
    }

    func testUntaggedFollowsUntaggedAction() {
        // Default: never hide what we couldn't confidently classify.
        let lenient = NamedPolicy(id: "p", name: "p", excludeTagIDs: ["gaming"], untaggedAction: .allow)
        XCTAssertEqual(lenient.resolveActions(for: []).feed, .allow)
        XCTAssertEqual(lenient.resolveActions(for: [obs("gaming", 2)]).feed, .allow)   // all below floor = untagged
        // Strict allow-only mode can opt into hiding the unclassifiable.
        let strict = NamedPolicy(id: "q", name: "q", includeAnyTagIDs: ["clash-royale"], untaggedAction: .dim)
        XCTAssertEqual(strict.resolveActions(for: []).feed, .dim)
    }

    func testPolicyDecodesWithoutNewFieldsUsingDefaults() throws {
        // A policy persisted before the rewire (no confidenceFloor / untaggedAction).
        let legacy = #"{"id":"p","name":"p","includeAnyTagIDs":["clash-royale"],"includeAllTagIDs":[],"excludeTagIDs":[],"feedAction":"dim","pageAction":"block"}"#
        let decoded = try JSONDecoder().decode(NamedPolicy.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.confidenceFloor, NamedPolicy.defaultConfidenceFloor)
        XCTAssertEqual(decoded.untaggedAction, .allow)
    }

    // MARK: - Per-type thumbnail-OCR evidence setting

    func testThumbnailOcrEvidenceDefaultsOnAndDecodesBackCompat() throws {
        // Unset → default ON.
        XCTAssertTrue(LocalModelOverrides().effectiveThumbnailOcrEvidence)
        XCTAssertTrue(LocalModelOverrides(thumbnailOcrEvidence: nil).effectiveThumbnailOcrEvidence)
        XCTAssertFalse(LocalModelOverrides(thumbnailOcrEvidence: false).effectiveThumbnailOcrEvidence)
        // An override that only sets OCR is not "empty" (must persist).
        XCTAssertFalse(LocalModelOverrides(thumbnailOcrEvidence: false).isEmpty)
        // A pre-existing override JSON without the field still defaults ON.
        let legacy = #"{"houseRules":"x","allowDecline":true}"#
        let decoded = try JSONDecoder().decode(LocalModelOverrides.self, from: Data(legacy.utf8))
        XCTAssertNil(decoded.thumbnailOcrEvidence)
        XCTAssertTrue(decoded.effectiveThumbnailOcrEvidence)
    }
}
