import CryptoKit
import Foundation

public struct SeedModelPackage: Codable, Equatable, Sendable {
    public var packageID: String
    public var taxonomyVersion: String
    public var modelVersion: String
    public var taxonomy: [TagNode]

    public init(packageID: String, taxonomyVersion: String, modelVersion: String, taxonomy: [TagNode]) {
        self.packageID = packageID
        self.taxonomyVersion = taxonomyVersion
        self.modelVersion = modelVersion
        self.taxonomy = taxonomy
    }

    private enum CodingKeys: String, CodingKey {
        case packageID, taxonomyVersion, modelVersion, taxonomy
    }

    private enum RetiredCodingKeys: String, CodingKey {
        case model, pageThreshold, feedThresholdOffset, sourcePrior
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        _ = try decoder.container(keyedBy: RetiredCodingKeys.self)
        packageID = try container.decode(String.self, forKey: .packageID)
        taxonomyVersion = try container.decode(String.self, forKey: .taxonomyVersion)
        modelVersion = try container.decode(String.self, forKey: .modelVersion)
        taxonomy = try container.decode([TagNode].self, forKey: .taxonomy)
    }
}

public struct VerifiedSeedPackage: Sendable {
    public let package: SeedModelPackage
    public let rawData: Data
    public let checksum: String

    public init(package: SeedModelPackage, rawData: Data, checksum: String) {
        self.package = package
        self.rawData = rawData
        self.checksum = checksum
    }

    public var taxonomy: Taxonomy { get throws { try Taxonomy(nodes: package.taxonomy) } }
}

public enum SeedPackageError: Error, LocalizedError, Sendable {
    case missingResource(String)
    case invalidChecksum
    case checksumMismatch(expected: String, actual: String)
    case invalidTaxonomy(TaxonomyError)

    public var errorDescription: String? {
        switch self {
        case .missingResource(let name): return "Missing bundled resource \(name)."
        case .invalidChecksum: return "The bundled package checksum is malformed."
        case .checksumMismatch: return "The bundled seed package did not pass its integrity check."
        case .invalidTaxonomy(let error): return error.localizedDescription
        }
    }
}

public enum SeedPackageLoader {
    public static func bundled() throws -> VerifiedSeedPackage {
        guard let packageURL = Bundle.module.url(forResource: "seed-package", withExtension: "json", subdirectory: "Resources"),
              let checksumURL = Bundle.module.url(forResource: "seed-package", withExtension: "sha256", subdirectory: "Resources") else {
            throw SeedPackageError.missingResource("seed-package")
        }
        let data = try Data(contentsOf: packageURL)
        let expected = try String(contentsOf: checksumURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard expected.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { throw SeedPackageError.invalidChecksum }
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == expected else { throw SeedPackageError.checksumMismatch(expected: expected, actual: actual) }
        let package = try JSONDecoder().decode(SeedModelPackage.self, from: data)
        do { _ = try Taxonomy(nodes: package.taxonomy) }
        catch let error as TaxonomyError { throw SeedPackageError.invalidTaxonomy(error) }
        return .init(package: package, rawData: data, checksum: actual)
    }

    public static func verify(data: Data, expectedChecksum: String) throws -> VerifiedSeedPackage {
        let expected = expectedChecksum.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == expected else { throw SeedPackageError.checksumMismatch(expected: expected, actual: actual) }
        let package = try JSONDecoder().decode(SeedModelPackage.self, from: data)
        do { _ = try Taxonomy(nodes: package.taxonomy) }
        catch let error as TaxonomyError { throw SeedPackageError.invalidTaxonomy(error) }
        return .init(package: package, rawData: data, checksum: actual)
    }
}

public struct SignedPackageEnvelope: Codable, Equatable, Sendable {
    public var payload: Data
    public var signature: Data

    public init(payload: Data, signature: Data) { self.payload = payload; self.signature = signature }
}

/// The verifier is ready for a release signer but this repository deliberately holds no private key.
public struct Ed25519SignatureVerifier: Sendable {
    public let publicKey: Data

    public init(publicKey: Data) { self.publicKey = publicKey }

    public func verify(_ envelope: SignedPackageEnvelope) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else { return false }
        return key.isValidSignature(envelope.signature, for: envelope.payload)
    }
}
