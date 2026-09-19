import CryptoKit
import Darwin
import Foundation

/// Stable, numeric release metadata for a model package. This is deliberately
/// separate from a model's internal version string: the app uses it to reject a
/// signed but older distribution package after a rollback.
public struct PackageReleaseVersion: Codable, Equatable, Comparable, Hashable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) throws {
        guard major >= 0, minor >= 0, patch >= 0 else {
            throw PackageManifestValidationError.invalidMetadata("releaseVersion")
        }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            major: container.decode(Int.self, forKey: .major),
            minor: container.decode(Int.self, forKey: .minor),
            patch: container.decode(Int.self, forKey: .patch)
        )
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }

    public var displayString: String { "\(major).\(minor).\(patch)" }
}

/// The signed metadata for one immutable model payload. `payloadSHA256` is a
/// lowercase SHA-256 digest over the exact `SeedModelPackage` JSON bytes.
public struct ModelPackageManifest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var packageID: String
    public var releaseSequence: Int64
    public var releaseVersion: PackageReleaseVersion
    public var taxonomyVersion: String
    public var modelVersion: String
    public var payloadSHA256: String
    public var payloadByteCount: Int
    public var publishedAtMilliseconds: Int64
    public var signingKeyID: String

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        packageID: String,
        releaseSequence: Int64,
        releaseVersion: PackageReleaseVersion,
        taxonomyVersion: String,
        modelVersion: String,
        payloadSHA256: String,
        payloadByteCount: Int,
        publishedAtMilliseconds: Int64,
        signingKeyID: String
    ) {
        self.schemaVersion = schemaVersion
        self.packageID = packageID
        self.releaseSequence = releaseSequence
        self.releaseVersion = releaseVersion
        self.taxonomyVersion = taxonomyVersion
        self.modelVersion = modelVersion
        self.payloadSHA256 = payloadSHA256
        self.payloadByteCount = payloadByteCount
        self.publishedAtMilliseconds = publishedAtMilliseconds
        self.signingKeyID = signingKeyID
    }
}

public enum PackageSignatureAlgorithm: String, Codable, Equatable, Sendable {
    case ed25519
}

/// The signature covers the canonical encoding of `manifest`, never an
/// arbitrary re-serialization of the payload.
public struct SignedModelPackageManifest: Codable, Equatable, Sendable {
    public var manifest: ModelPackageManifest
    public var algorithm: PackageSignatureAlgorithm
    public var signature: Data

    public init(manifest: ModelPackageManifest, algorithm: PackageSignatureAlgorithm = .ed25519, signature: Data) {
        self.manifest = manifest
        self.algorithm = algorithm
        self.signature = signature
    }
}

/// A complete candidate is intentionally in-memory only. Network transport,
/// credentials, and server discovery are outside this local lifecycle layer.
public struct ModelPackageCandidate: Sendable {
    public var signedManifest: SignedModelPackageManifest
    public var payload: Data

    public init(signedManifest: SignedModelPackageManifest, payload: Data) {
        self.signedManifest = signedManifest
        self.payload = payload
    }
}

public struct VerifiedModelPackage: Sendable {
    public let manifest: ModelPackageManifest
    public let signedManifest: SignedModelPackageManifest
    public let seedPackage: VerifiedSeedPackage

    /// Deliberately internal: public callers can obtain this capability only
    /// from `PackageManifestValidator.verify(_:)` (or a lifecycle API that
    /// reuses that validator). A public initializer would let an arbitrary
    /// `VerifiedSeedPackage` bypass the signed-manifest boundary before it is
    /// activated by the coordinator.
    init(manifest: ModelPackageManifest, signedManifest: SignedModelPackageManifest, seedPackage: VerifiedSeedPackage) {
        self.manifest = manifest
        self.signedManifest = signedManifest
        self.seedPackage = seedPackage
    }
}

public struct PackageSigningKey: Equatable, Sendable {
    public var keyID: String
    public var publicKey: Data
    public var isRevoked: Bool

    public init(keyID: String, publicKey: Data, isRevoked: Bool = false) {
        self.keyID = keyID
        self.publicKey = publicKey
        self.isRevoked = isRevoked
    }
}

/// The keyring holds public verification material only. It deliberately has no
/// signer, private key, endpoint, token, or account state.
public struct PackageSigningKeyring: Sendable {
    private let keysByID: [String: PackageSigningKey]

    public init(_ keys: [PackageSigningKey]) throws {
        var mapping: [String: PackageSigningKey] = [:]
        for key in keys {
            guard PackageManifestValidator.isSafeIdentifier(key.keyID) else {
                throw PackageManifestValidationError.invalidMetadata("signingKeyID")
            }
            guard mapping[key.keyID] == nil else {
                throw PackageManifestValidationError.invalidMetadata("duplicate signingKeyID")
            }
            mapping[key.keyID] = key
        }
        self.keysByID = mapping
    }

    public func key(id: String) -> PackageSigningKey? { keysByID[id] }
}

public struct PackageReleaseStamp: Codable, Equatable, Comparable, Sendable {
    public var releaseSequence: Int64
    public var releaseVersion: PackageReleaseVersion

    public init(releaseSequence: Int64, releaseVersion: PackageReleaseVersion) {
        self.releaseSequence = releaseSequence
        self.releaseVersion = releaseVersion
    }

    public init(manifest: ModelPackageManifest) {
        self.init(releaseSequence: manifest.releaseSequence, releaseVersion: manifest.releaseVersion)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.releaseSequence != rhs.releaseSequence { return lhs.releaseSequence < rhs.releaseSequence }
        return lhs.releaseVersion < rhs.releaseVersion
    }

    /// A package must advance both independent release controls. This prevents
    /// a higher sequence from relabeling an old semantic release, or a higher
    /// semantic version from bypassing the durable sequence high-water mark.
    public func isStrictlyNewer(than previous: Self) -> Bool {
        releaseSequence > previous.releaseSequence && releaseVersion > previous.releaseVersion
    }
}

public enum PackageManifestValidationError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedSchema(Int)
    case invalidMetadata(String)
    case invalidChecksumFormat
    case payloadSizeMismatch(expected: Int, actual: Int)
    case checksumMismatch(expected: String, actual: String)
    case unknownSigningKey(String)
    case revokedSigningKey(String)
    case invalidSignature
    case invalidPayload
    case payloadMetadataMismatch(String)
    case nonMonotonicUpdate(current: PackageReleaseStamp, candidate: PackageReleaseStamp)
    case stagedUpdatePending
    case noStagedPackage
    case noRollbackPackage
    case missingStoredPackage
    case storedPackageMismatch

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema: return "This package manifest uses an unsupported schema."
        case .invalidMetadata(let field): return "The package manifest has invalid \(field) metadata."
        case .invalidChecksumFormat: return "The package manifest checksum is malformed."
        case .payloadSizeMismatch: return "The package payload size does not match its signed manifest."
        case .checksumMismatch: return "The package payload did not pass its SHA-256 integrity check."
        case .unknownSigningKey: return "The package was signed by an unknown key."
        case .revokedSigningKey: return "The package was signed by a revoked key."
        case .invalidSignature: return "The package manifest signature is invalid."
        case .invalidPayload: return "The package payload cannot be validated."
        case .payloadMetadataMismatch: return "The package payload does not match its signed metadata."
        case .nonMonotonicUpdate: return "The package does not advance the accepted release metadata."
        case .stagedUpdatePending: return "A verified package is already waiting for activation."
        case .noStagedPackage: return "There is no verified package waiting for activation."
        case .noRollbackPackage: return "There is no verified package available for rollback."
        case .missingStoredPackage: return "A locally recorded package is unavailable."
        case .storedPackageMismatch: return "A locally recorded package does not match its lifecycle metadata."
        }
    }
}

public enum PackageDigest {
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public enum PackageManifestCodec {
    public static func canonicalData(for manifest: ModelPackageManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(manifest)
    }

    static func storageData<T: Encodable>(for value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(value)
    }

    static func storageDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}

public struct PackageManifestValidator: Sendable {
    public static let maximumPayloadByteCount = 128 * 1024 * 1024
    public let keyring: PackageSigningKeyring

    public init(keyring: PackageSigningKeyring) {
        self.keyring = keyring
    }

    /// Validates the signed metadata before a client derives a payload path or
    /// downloads a potentially large body. This is deliberately separate from
    /// `verify(_:)`: it proves the manifest's signer and canonical contents,
    /// while full package verification additionally binds the exact payload.
    @discardableResult
    public func verifyManifest(_ signedManifest: SignedModelPackageManifest) throws -> ModelPackageManifest {
        let manifest = signedManifest.manifest
        try validateMetadata(manifest)
        guard signedManifest.algorithm == .ed25519, signedManifest.signature.count == 64 else {
            throw PackageManifestValidationError.invalidSignature
        }
        guard let signingKey = keyring.key(id: manifest.signingKeyID) else {
            throw PackageManifestValidationError.unknownSigningKey(manifest.signingKeyID)
        }
        guard !signingKey.isRevoked else {
            throw PackageManifestValidationError.revokedSigningKey(signingKey.keyID)
        }
        let canonicalManifest = try PackageManifestCodec.canonicalData(for: manifest)
        let envelope = SignedPackageEnvelope(payload: canonicalManifest, signature: signedManifest.signature)
        guard Ed25519SignatureVerifier(publicKey: signingKey.publicKey).verify(envelope) else {
            throw PackageManifestValidationError.invalidSignature
        }
        return manifest
    }

    public func verify(_ candidate: ModelPackageCandidate) throws -> VerifiedModelPackage {
        let signedManifest = candidate.signedManifest
        let manifest = try verifyManifest(signedManifest)
        guard candidate.payload.count == manifest.payloadByteCount else {
            throw PackageManifestValidationError.payloadSizeMismatch(expected: manifest.payloadByteCount, actual: candidate.payload.count)
        }
        let actualChecksum = PackageDigest.sha256Hex(candidate.payload)
        guard actualChecksum == manifest.payloadSHA256 else {
            throw PackageManifestValidationError.checksumMismatch(expected: manifest.payloadSHA256, actual: actualChecksum)
        }
        let seedPackage: VerifiedSeedPackage
        do {
            seedPackage = try SeedPackageLoader.verify(data: candidate.payload, expectedChecksum: manifest.payloadSHA256)
        } catch {
            throw PackageManifestValidationError.invalidPayload
        }
        guard seedPackage.package.packageID == manifest.packageID else {
            throw PackageManifestValidationError.payloadMetadataMismatch("packageID")
        }
        guard seedPackage.package.taxonomyVersion == manifest.taxonomyVersion else {
            throw PackageManifestValidationError.payloadMetadataMismatch("taxonomyVersion")
        }
        guard seedPackage.package.modelVersion == manifest.modelVersion else {
            throw PackageManifestValidationError.payloadMetadataMismatch("modelVersion")
        }
        return .init(manifest: manifest, signedManifest: signedManifest, seedPackage: seedPackage)
    }

    /// Checks the structural metadata that is safe to inspect before a payload
    /// download. It intentionally does not treat unverified metadata as a
    /// package; callers must still call `verifyManifest(_:)` or `verify(_:)`.
    public func validateMetadata(_ manifest: ModelPackageManifest) throws {
        guard manifest.schemaVersion == ModelPackageManifest.currentSchemaVersion else {
            throw PackageManifestValidationError.unsupportedSchema(manifest.schemaVersion)
        }
        guard Self.isSafeIdentifier(manifest.packageID),
              Self.isSafeIdentifier(manifest.taxonomyVersion),
              Self.isSafeIdentifier(manifest.modelVersion),
              Self.isSafeIdentifier(manifest.signingKeyID) else {
            throw PackageManifestValidationError.invalidMetadata("identifier")
        }
        guard manifest.releaseSequence > 0, manifest.publishedAtMilliseconds >= 0 else {
            throw PackageManifestValidationError.invalidMetadata("release")
        }
        guard manifest.payloadByteCount > 0, manifest.payloadByteCount <= Self.maximumPayloadByteCount else {
            throw PackageManifestValidationError.invalidMetadata("payloadByteCount")
        }
        guard manifest.payloadSHA256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw PackageManifestValidationError.invalidChecksumFormat
        }
    }

    fileprivate static func isSafeIdentifier(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$", options: .regularExpression) != nil
    }
}

/// A reference to a locally staged, active, or rollback package. The directory
/// name is derived rather than persisted, so lifecycle JSON cannot redirect
/// loading outside the package store.
public struct LocalPackageReference: Codable, Equatable, Sendable, Identifiable {
    public var manifest: ModelPackageManifest
    public var stagedAt: Date

    public init(manifest: ModelPackageManifest, stagedAt: Date = .now) {
        self.manifest = manifest
        self.stagedAt = stagedAt
    }

    public var id: String { "\(manifest.releaseSequence):\(manifest.payloadSHA256)" }
    public var releaseStamp: PackageReleaseStamp { .init(manifest: manifest) }
    /// The lifecycle file is local persistent input. Derive a storage name only
    /// from the two fields whose syntax makes it a single safe path component.
    /// A malformed state record can then neither escape the package directory
    /// nor cause cleanup to protect an arbitrary path.
    fileprivate var storageName: String? {
        guard manifest.releaseSequence > 0,
              manifest.payloadSHA256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            return nil
        }
        return "release-\(manifest.releaseSequence)-\(manifest.payloadSHA256)"
    }
}

public struct LocalPackageLifecycleState: Codable, Equatable, Sendable {
    public var active: LocalPackageReference?
    public var staged: LocalPackageReference?
    public var rollbackPackages: [LocalPackageReference]
    public var highestAcceptedRelease: PackageReleaseStamp?
    public var lastManifestCheckAt: Date?
    public var lastSuccessfulSyncAt: Date?

    public init(
        active: LocalPackageReference? = nil,
        staged: LocalPackageReference? = nil,
        rollbackPackages: [LocalPackageReference] = [],
        highestAcceptedRelease: PackageReleaseStamp? = nil,
        lastManifestCheckAt: Date? = nil,
        lastSuccessfulSyncAt: Date? = nil
    ) {
        self.active = active
        self.staged = staged
        self.rollbackPackages = rollbackPackages
        self.highestAcceptedRelease = highestAcceptedRelease
        self.lastManifestCheckAt = lastManifestCheckAt
        self.lastSuccessfulSyncAt = lastSuccessfulSyncAt
    }
}

public enum PackageUpdateMode: String, Codable, Equatable, Sendable, CaseIterable {
    case automatic
    case downloadThenAsk
    case manual
}

public enum PackageDownloadDisposition: String, Codable, Equatable, Sendable {
    case automatic
    case askBeforeDownload
}

public enum DailyPackageSyncDecision: Equatable, Sendable {
    case checkManifest(downloadDisposition: PackageDownloadDisposition)
    case waitUntil(Date)
    case backgroundSyncDisabled
    case manualOnly
}

/// Pure scheduling logic. It never opens a connection; a caller may use a
/// `checkManifest` decision to perform a separately implemented transport.
public struct DailyPackageSyncPlanner: Sendable {
    public static let interval: TimeInterval = 24 * 60 * 60

    public init() {}

    public func decision(
        now: Date = .now,
        state: LocalPackageLifecycleState,
        updateMode: PackageUpdateMode = .automatic,
        backgroundSyncEnabled: Bool
    ) -> DailyPackageSyncDecision {
        guard backgroundSyncEnabled else { return .backgroundSyncDisabled }
        guard updateMode != .manual else { return .manualOnly }
        let disposition: PackageDownloadDisposition = updateMode == .automatic ? .automatic : .askBeforeDownload
        guard let lastCheck = state.lastManifestCheckAt else {
            return .checkManifest(downloadDisposition: disposition)
        }
        let nextCheck = lastCheck.addingTimeInterval(Self.interval)
        return now >= nextCheck ? .checkManifest(downloadDisposition: disposition) : .waitUntil(nextCheck)
    }
}

/// Local, crash-safe package staging and activation. Package files are written
/// into a same-volume staging directory and renamed before the lifecycle state
/// is atomically replaced. A failure therefore leaves the previously active
/// package usable offline.
public final class LocalPackageLifecycle {
    private let rootDirectory: URL
    private let rollbackLimit: Int
    private let validator: PackageManifestValidator
    private let fileManager: FileManager
    private let lock = NSLock()

    public init(
        rootDirectory: URL,
        keyring: PackageSigningKeyring,
        rollbackLimit: Int = 3,
        fileManager: FileManager = .default
    ) {
        self.rootDirectory = rootDirectory
        self.rollbackLimit = max(1, rollbackLimit)
        self.validator = PackageManifestValidator(keyring: keyring)
        self.fileManager = fileManager
    }

    public func snapshot() throws -> LocalPackageLifecycleState {
        lock.lock()
        defer { lock.unlock() }
        return try loadState()
    }

    /// Verifies a candidate before it can become visible to ordinary offline
    /// classification. Staging does not change the active package.
    @discardableResult
    public func stage(_ candidate: ModelPackageCandidate, at date: Date = .now) throws -> LocalPackageReference {
        lock.lock()
        defer { lock.unlock() }

        let verified = try validator.verify(candidate)
        var state = try loadState()
        if let staged = state.staged {
            if staged.manifest == verified.manifest {
                _ = try loadVerifiedPackage(staged)
                return staged
            }
            throw PackageManifestValidationError.stagedUpdatePending
        }
        let candidateStamp = PackageReleaseStamp(manifest: verified.manifest)
        let acceptedStamp = state.highestAcceptedRelease ?? state.active?.releaseStamp
        if let acceptedStamp, !candidateStamp.isStrictlyNewer(than: acceptedStamp) {
            throw PackageManifestValidationError.nonMonotonicUpdate(current: acceptedStamp, candidate: candidateStamp)
        }

        try createLayout()
        let reference = LocalPackageReference(manifest: verified.manifest, stagedAt: date)
        let destination = try packageURL(for: reference)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try loadVerifiedPackage(reference)
        } else {
            let staging = stagingDirectoryURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
            do {
                try createPrivateDirectory(at: staging)
                try writePrivate(candidate.payload, to: staging.appendingPathComponent("seed-package.json"))
                let signedManifestData = try PackageManifestCodec.storageData(for: candidate.signedManifest)
                try writePrivate(signedManifestData, to: staging.appendingPathComponent("signed-manifest.json"))
                try fileManager.moveItem(at: staging, to: destination)
            } catch {
                try? fileManager.removeItem(at: staging)
                if fileManager.fileExists(atPath: destination.path) {
                    _ = try loadVerifiedPackage(reference)
                } else {
                    throw error
                }
            }
        }
        state.staged = reference
        try saveState(state)
        return reference
    }

    /// Makes the verified staged package active in one atomic metadata update.
    /// The previous active reference remains a verified rollback candidate.
    @discardableResult
    public func activateStaged(at date: Date = .now) throws -> LocalPackageReference {
        lock.lock()
        defer { lock.unlock() }

        var state = try loadState()
        guard let staged = state.staged else { throw PackageManifestValidationError.noStagedPackage }
        _ = try loadVerifiedPackage(staged)
        var rollbacks = state.rollbackPackages.filter { $0.id != staged.id && $0.id != state.active?.id }
        if let active = state.active { rollbacks.insert(active, at: 0) }
        state.active = staged
        state.staged = nil
        state.rollbackPackages = Array(rollbacks.prefix(rollbackLimit))
        if let accepted = state.highestAcceptedRelease, accepted != staged.releaseStamp {
            guard staged.releaseStamp.isStrictlyNewer(than: accepted) else {
                throw PackageManifestValidationError.nonMonotonicUpdate(current: accepted, candidate: staged.releaseStamp)
            }
            state.highestAcceptedRelease = staged.releaseStamp
        } else if state.highestAcceptedRelease == nil {
            state.highestAcceptedRelease = staged.releaseStamp
        }
        state.lastSuccessfulSyncAt = date
        try saveState(state)
        pruneUnreferencedPackageDirectories(keeping: state)
        return staged
    }

    /// Intentionally re-activates an already verified rollback reference. It
    /// never lowers `highestAcceptedRelease`, so a later download cannot replay
    /// the older package as a new update.
    @discardableResult
    public func rollback(to referenceID: String? = nil) throws -> LocalPackageReference {
        lock.lock()
        defer { lock.unlock() }

        var state = try loadState()
        guard state.staged == nil else { throw PackageManifestValidationError.stagedUpdatePending }
        guard let active = state.active else { throw PackageManifestValidationError.noRollbackPackage }
        let target: LocalPackageReference
        if let referenceID {
            guard let found = state.rollbackPackages.first(where: { $0.id == referenceID }) else {
                throw PackageManifestValidationError.noRollbackPackage
            }
            target = found
        } else if let first = state.rollbackPackages.first {
            target = first
        } else {
            throw PackageManifestValidationError.noRollbackPackage
        }
        _ = try loadVerifiedPackage(target)
        var rollbacks = state.rollbackPackages.filter { $0.id != target.id && $0.id != active.id }
        rollbacks.insert(active, at: 0)
        state.active = target
        state.rollbackPackages = Array(rollbacks.prefix(rollbackLimit))
        try saveState(state)
        pruneUnreferencedPackageDirectories(keeping: state)
        return target
    }

    /// Clears the activation intent, then reclaims that now-unreferenced staged
    /// directory only when it has the exact private package-store shape.
    public func discardStaged() throws {
        lock.lock()
        defer { lock.unlock() }
        var state = try loadState()
        state.staged = nil
        try saveState(state)
        pruneUnreferencedPackageDirectories(keeping: state)
    }

    /// Records a completed manifest check monotonically for the pure daily
    /// scheduler. Calling it does not download or activate anything.
    public func recordManifestCheck(at date: Date = .now) throws {
        lock.lock()
        defer { lock.unlock() }
        var state = try loadState()
        if state.lastManifestCheckAt.map({ date > $0 }) ?? true {
            state.lastManifestCheckAt = date
            try saveState(state)
        }
    }

    /// Loads the locally active, independently re-verified payload. This is
    /// the offline classification path; no network fallback exists here.
    public func activePackage() throws -> VerifiedModelPackage? {
        lock.lock()
        defer { lock.unlock() }
        guard let active = try loadState().active else { return nil }
        return try loadVerifiedPackage(active)
    }

    private var packagesDirectoryURL: URL { rootDirectory.appendingPathComponent("packages", isDirectory: true) }
    private var stagingDirectoryURL: URL { rootDirectory.appendingPathComponent("staging", isDirectory: true) }
    private var stateURL: URL { rootDirectory.appendingPathComponent("lifecycle.json") }

    private func packageURL(for reference: LocalPackageReference) throws -> URL {
        try validator.validateMetadata(reference.manifest)
        guard let storageName = reference.storageName else {
            throw PackageManifestValidationError.storedPackageMismatch
        }
        let root = packagesDirectoryURL.standardizedFileURL
        let destination = root.appendingPathComponent(storageName, isDirectory: true).standardizedFileURL
        guard destination.deletingLastPathComponent() == root else {
            throw PackageManifestValidationError.storedPackageMismatch
        }
        return destination
    }

    private func createLayout() throws {
        try createPrivateDirectory(at: rootDirectory)
        try createPrivateDirectory(at: packagesDirectoryURL)
        try createPrivateDirectory(at: stagingDirectoryURL)
    }

    private func createPrivateDirectory(at url: URL) throws {
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func writePrivate(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func loadState() throws -> LocalPackageLifecycleState {
        guard fileManager.fileExists(atPath: stateURL.path) else { return .init() }
        let data = try Data(contentsOf: stateURL)
        return try PackageManifestCodec.storageDecoder().decode(LocalPackageLifecycleState.self, from: data)
    }

    private func saveState(_ state: LocalPackageLifecycleState) throws {
        try createLayout()
        let data = try PackageManifestCodec.storageData(for: state)
        try writePrivate(data, to: stateURL)
    }

    private func loadVerifiedPackage(_ reference: LocalPackageReference) throws -> VerifiedModelPackage {
        try validator.validateMetadata(reference.manifest)
        let directory = try packageURL(for: reference)
        guard fileManager.fileExists(atPath: directory.path) else {
            throw PackageManifestValidationError.missingStoredPackage
        }
        let payloadURL = directory.appendingPathComponent("seed-package.json")
        let manifestURL = directory.appendingPathComponent("signed-manifest.json")
        guard fileManager.fileExists(atPath: payloadURL.path), fileManager.fileExists(atPath: manifestURL.path) else {
            throw PackageManifestValidationError.missingStoredPackage
        }
        let payload = try Data(contentsOf: payloadURL)
        let signedManifest = try PackageManifestCodec.storageDecoder().decode(SignedModelPackageManifest.self, from: Data(contentsOf: manifestURL))
        guard signedManifest.manifest == reference.manifest else {
            throw PackageManifestValidationError.storedPackageMismatch
        }
        return try validator.verify(.init(signedManifest: signedManifest, payload: payload))
    }

    /// Reclaims only complete, app-owned package directories. Cleanup is
    /// deliberately fail-closed: it operates on directory descriptors, never
    /// follows a symlink, never recurses, and leaves anything unexpected for a
    /// future manual repair rather than risking a path outside this store.
    private func pruneUnreferencedPackageDirectories(keeping state: LocalPackageLifecycleState) {
        let retained = Set(
            ([state.active, state.staged].compactMap { $0 } + state.rollbackPackages)
                .compactMap(\.storageName)
        )
        let packagesDescriptor = packagesDirectoryURL.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        }
        guard packagesDescriptor >= 0 else { return }
        defer { close(packagesDescriptor) }

        guard let names = directoryEntryNames(from: packagesDescriptor) else { return }
        for name in names where isPackageStorageName(name) && !retained.contains(name) {
            removePackageDirectoryIfSafe(named: name, from: packagesDescriptor)
        }
    }

    private func removePackageDirectoryIfSafe(named name: String, from parentDescriptor: Int32) {
        guard let expectedDirectory = fileStatus(named: name, relativeTo: parentDescriptor),
              isDirectory(expectedDirectory) else {
            return
        }
        let directoryDescriptor = name.withCString {
            openat(parentDescriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        }
        guard directoryDescriptor >= 0 else { return }
        defer { close(directoryDescriptor) }

        var openedDirectory = stat()
        guard fstat(directoryDescriptor, &openedDirectory) == 0,
              sameFile(expectedDirectory, openedDirectory),
              let childNames = directoryEntryNames(from: directoryDescriptor),
              Set(childNames) == Self.storedPackageFileNames,
              childNames.count == Self.storedPackageFileNames.count else {
            return
        }
        for childName in Self.storedPackageFileNames {
            guard let child = fileStatus(named: childName, relativeTo: directoryDescriptor),
                  isRegularFile(child),
                  unlinkat(directoryDescriptor, childName, 0) == 0 else {
                return
            }
        }
        // The parent entry must still name the directory we opened. If a
        // replacement appeared while cleaning, leave it untouched.
        guard let currentDirectory = fileStatus(named: name, relativeTo: parentDescriptor),
              sameFile(openedDirectory, currentDirectory) else {
            return
        }
        _ = unlinkat(parentDescriptor, name, AT_REMOVEDIR)
    }

    private static let storedPackageFileNames: Set<String> = ["seed-package.json", "signed-manifest.json"]

    private func isPackageStorageName(_ name: String) -> Bool {
        name.range(of: "^release-[1-9][0-9]*-[0-9a-f]{64}$", options: .regularExpression) != nil
    }

    private func directoryEntryNames(from descriptor: Int32) -> [String]? {
        let duplicated = dup(descriptor)
        guard duplicated >= 0, let directory = fdopendir(duplicated) else {
            if duplicated >= 0 { close(duplicated) }
            return nil
        }
        defer { closedir(directory) }

        var names: [String] = []
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN)) {
                    String(cString: $0)
                }
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }

    private func fileStatus(named name: String, relativeTo descriptor: Int32) -> stat? {
        var metadata = stat()
        let result = name.withCString {
            fstatat(descriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW)
        }
        return result == 0 ? metadata : nil
    }

    private func isDirectory(_ metadata: stat) -> Bool {
        (metadata.st_mode & S_IFMT) == S_IFDIR
    }

    private func isRegularFile(_ metadata: stat) -> Bool {
        (metadata.st_mode & S_IFMT) == S_IFREG
    }

    private func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
    }
}
