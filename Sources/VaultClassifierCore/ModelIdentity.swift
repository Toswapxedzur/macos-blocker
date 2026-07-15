import Foundation

/// The exact local model that produced a cache row or personal-audit record.
///
/// A bundled seed is identified by the checksum verified beside that resource.
/// A distributed package is identified by both its monotonic signed release
/// sequence and the signed payload digest. Package/model display names alone
/// are deliberately insufficient because they can be reused across releases.
public struct ActiveModelIdentity: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, Equatable, Hashable, Sendable {
        case seed
        case signedPackage
    }

    public var kind: Kind
    public var packageID: String
    public var taxonomyVersion: String
    public var modelVersion: String
    /// Present only for a bundled/seed-only package.
    public var seedChecksum: String?
    /// Present only for a signed distribution package.
    public var releaseSequence: Int64?
    /// Present only for a signed distribution package.
    public var payloadSHA256: String?

    init(
        kind: Kind,
        packageID: String,
        taxonomyVersion: String,
        modelVersion: String,
        seedChecksum: String?,
        releaseSequence: Int64?,
        payloadSHA256: String?
    ) {
        self.kind = kind
        self.packageID = packageID
        self.taxonomyVersion = taxonomyVersion
        self.modelVersion = modelVersion
        self.seedChecksum = seedChecksum
        self.releaseSequence = releaseSequence
        self.payloadSHA256 = payloadSHA256
    }

    public init(seed verifiedPackage: VerifiedSeedPackage) {
        kind = .seed
        packageID = verifiedPackage.package.packageID
        taxonomyVersion = verifiedPackage.package.taxonomyVersion
        modelVersion = verifiedPackage.package.modelVersion
        seedChecksum = verifiedPackage.checksum.lowercased()
        releaseSequence = nil
        payloadSHA256 = nil
    }

    public init(signed verifiedPackage: VerifiedModelPackage) {
        kind = .signedPackage
        packageID = verifiedPackage.manifest.packageID
        taxonomyVersion = verifiedPackage.manifest.taxonomyVersion
        modelVersion = verifiedPackage.manifest.modelVersion
        seedChecksum = nil
        releaseSequence = verifiedPackage.manifest.releaseSequence
        payloadSHA256 = verifiedPackage.manifest.payloadSHA256.lowercased()
    }

    public var isStructurallyValid: Bool {
        guard !packageID.isEmpty,
              !taxonomyVersion.isEmpty,
              !modelVersion.isEmpty else {
            return false
        }
        switch kind {
        case .seed:
            return releaseSequence == nil
                && payloadSHA256 == nil
                && Self.isSHA256(seedChecksum)
        case .signedPackage:
            return seedChecksum == nil
                && (releaseSequence ?? 0) > 0
                && Self.isSHA256(payloadSHA256)
        }
    }

    public func matches(_ result: ClassificationResult) -> Bool {
        packageID == result.packageID && modelVersion == result.modelVersion
    }

    private static func isSHA256(_ value: String?) -> Bool {
        guard let value else { return false }
        return value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
    }
}
