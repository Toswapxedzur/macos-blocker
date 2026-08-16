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
}
