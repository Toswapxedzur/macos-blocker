import CryptoKit
import Foundation

/// Durable state for the collection, per-video LLM, settings, and
/// package-lifecycle paths. Keys left behind by removed features (the deterministic
/// classifier, audit, content-block policy — now the extension's) are simply never
/// read, and so are never written back; see LegacyStateDecodeTests.
public struct LocalClassifierState: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var settings: ClassifierSettings
    public var workspaceCatalog: WorkspaceCatalog
    public var backupConfiguration: LocalBackupConfiguration?
    public var activeModelIdentity: ActiveModelIdentity?
    public var highestAcceptedSignedRelease: PackageReleaseStamp?
    public var signedRollbackIdentities: [ActiveModelIdentity]

    public init(
        schemaVersion: Int = 2,
        settings: ClassifierSettings = .init(),
        workspaceCatalog: WorkspaceCatalog = .starter(),
        backupConfiguration: LocalBackupConfiguration? = nil,
        activeModelIdentity: ActiveModelIdentity? = nil,
        highestAcceptedSignedRelease: PackageReleaseStamp? = nil,
        signedRollbackIdentities: [ActiveModelIdentity] = []
    ) {
        self.schemaVersion = schemaVersion
        self.settings = settings
        self.workspaceCatalog = workspaceCatalog
        self.backupConfiguration = backupConfiguration
        self.activeModelIdentity = activeModelIdentity
        self.highestAcceptedSignedRelease = highestAcceptedSignedRelease
        self.signedRollbackIdentities = Self.normalizedRollbackIdentities(signedRollbackIdentities)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, settings, workspaceCatalog, backupConfiguration
        case activeModelIdentity, highestAcceptedSignedRelease, signedRollbackIdentities
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = max(2, try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 2)
        settings = try container.decodeIfPresent(ClassifierSettings.self, forKey: .settings) ?? .init()
        workspaceCatalog = try container.decodeIfPresent(WorkspaceCatalog.self, forKey: .workspaceCatalog) ?? .starter()
        backupConfiguration = try container.decodeIfPresent(LocalBackupConfiguration.self, forKey: .backupConfiguration)
        activeModelIdentity = (try? container.decodeIfPresent(ActiveModelIdentity.self, forKey: .activeModelIdentity)) ?? nil
        if activeModelIdentity?.isStructurallyValid != true { activeModelIdentity = nil }
        highestAcceptedSignedRelease = (try? container.decodeIfPresent(PackageReleaseStamp.self, forKey: .highestAcceptedSignedRelease)) ?? nil
        signedRollbackIdentities = Self.normalizedRollbackIdentities(
            (try? container.decodeIfPresent([ActiveModelIdentity].self, forKey: .signedRollbackIdentities)) ?? []
        )
    }

    public mutating func rememberSignedIdentityForRollback(_ identity: ActiveModelIdentity, limit: Int = 3) {
        guard identity.kind == .signedPackage else { return }
        signedRollbackIdentities.removeAll { $0 == identity }
        signedRollbackIdentities.insert(identity, at: 0)
        signedRollbackIdentities = Self.normalizedRollbackIdentities(signedRollbackIdentities, limit: limit)
    }

    private static func normalizedRollbackIdentities(
        _ values: [ActiveModelIdentity],
        limit: Int = 3
    ) -> [ActiveModelIdentity] {
        var seen = Set<ActiveModelIdentity>()
        return values.filter {
            $0.kind == .signedPackage && $0.isStructurallyValid && seen.insert($0).inserted
        }.prefix(max(1, limit)).map { $0 }
    }
}

public final class LocalStateFile: @unchecked Sendable {
    public let url: URL

    private static let ioQueue = DispatchQueue(label: "com.adamancia.vault.classifier.state-io", qos: .utility)
    private static let lock = NSLock()
    private static var pending: [String: LocalClassifierState] = [:]
    private static var scheduled: Set<String> = []

    public init(url: URL) { self.url = url }

    public func load(or defaultState: LocalClassifierState = .init()) throws -> LocalClassifierState {
        Self.ioQueue.sync {}
        guard FileManager.default.fileExists(atPath: url.path) else { return defaultState }
        return try JSONDecoder().decode(LocalClassifierState.self, from: Data(contentsOf: url))
    }

    public func save(_ state: LocalClassifierState) throws {
        let key = url.path
        let fileURL = url
        Self.lock.lock()
        Self.pending[key] = state
        let shouldStart = Self.scheduled.insert(key).inserted
        Self.lock.unlock()
        guard shouldStart else { return }
        Self.ioQueue.async { Self.drainPendingWrites(key: key, url: fileURL) }
    }

    public func flushSynchronously() { Self.ioQueue.sync {} }
    public static func flushAllPendingWrites() { ioQueue.sync {} }

    private static func drainPendingWrites(key: String, url: URL) {
        while true {
            lock.lock()
            guard let state = pending[key] else {
                scheduled.remove(key)
                lock.unlock()
                return
            }
            pending[key] = nil
            lock.unlock()
            writeToDisk(state, url: url)
        }
    }

    private static func writeToDisk(_ state: LocalClassifierState, url: URL) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(state).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            // Best-effort background persistence; the session state remains authoritative.
        }
    }
}

public enum PlatformCollectionError: Error, Equatable, LocalizedError, Sendable {
    case disabled(String)
    case missingEntryIdentifier
    case missingCreatorIdentifier
    case missingTitle
    case advertisement

    public var errorDescription: String? {
        switch self {
        case .disabled: return "Collection is not enabled for this platform."
        case .missingEntryIdentifier: return "The platform did not provide a stable entry identifier."
        case .missingCreatorIdentifier: return "The platform did not provide a stable creator identifier."
        case .missingTitle: return "The platform entry does not contain a title."
        case .advertisement: return "Advertisements are not collected."
        }
    }
}

public enum CorrectionSubmissionError: Error, Equatable, LocalizedError, Sendable {
    case invalidClassifierType
    case missingCollectedEntry
    case invalidTagSelection

    public var errorDescription: String? {
        switch self {
        case .invalidClassifierType: return "The classifier type cannot correct this platform."
        case .missingCollectedEntry: return "The collected video is no longer available."
        case .invalidTagSelection: return "The correction contains a tag that is not eligible for this classifier type."
        }
    }
}

/// Coordinates collection, per-video on-device LLM classification, settings,
/// backups, and signed taxonomy-package lifecycle.
public final class LocalClassifierCoordinator: @unchecked Sendable {
    let stateFile: LocalStateFile
    let lock = NSLock()
    var activeVerifiedPackage: VerifiedSeedPackage
    var state: LocalClassifierState
    var onDeviceLLM: any OnDeviceLLM = StubOnDeviceLLM()
    var onDeviceLLMEngineResolver: (any OnDeviceLLMEngineResolving)?
    var classificationHouseRules: String?
    var groundedResearchQueue: GroundedResearchQueue?
    var onVideoReclassifiedCallback: (@Sendable (String, String, VideoTagsProjection) -> Void)?

    public convenience init(
        verifiedPackage: VerifiedSeedPackage,
        stateFile: LocalStateFile
    ) throws {
        try self.init(
            verifiedPackage: verifiedPackage,
            activeManifest: nil,
            stateFile: stateFile
        )
    }

    public convenience init(
        verifiedModelPackage: VerifiedModelPackage,
        stateFile: LocalStateFile
    ) throws {
        try self.init(
            verifiedPackage: verifiedModelPackage.seedPackage,
            activeManifest: verifiedModelPackage.manifest,
            stateFile: stateFile
        )
    }

    public convenience init(
        lifecycle: LocalPackageLifecycle,
        fallbackVerifiedSeedPackage: VerifiedSeedPackage,
        stateFile: LocalStateFile
    ) throws {
        if let active = try lifecycle.activePackage() {
            try self.init(verifiedModelPackage: active, stateFile: stateFile)
        } else {
            try self.init(verifiedPackage: fallbackVerifiedSeedPackage, stateFile: stateFile)
        }
    }

    private init(
        verifiedPackage: VerifiedSeedPackage,
        activeManifest: ModelPackageManifest?,
        stateFile: LocalStateFile
    ) throws {
        let identity = activeManifest.map {
            ActiveModelIdentity(
                kind: .signedPackage,
                packageID: $0.packageID,
                taxonomyVersion: $0.taxonomyVersion,
                modelVersion: $0.modelVersion,
                seedChecksum: nil,
                releaseSequence: $0.releaseSequence,
                payloadSHA256: $0.payloadSHA256
            )
        } ?? ActiveModelIdentity(seed: verifiedPackage)
        guard identity.isStructurallyValid else { throw PackageManifestValidationError.storedPackageMismatch }

        var loaded = try stateFile.load()
        let original = loaded
        loaded.workspaceCatalog.reconcileClassifierTypes()
        try loaded.workspaceCatalog.validate()
        loaded.activeModelIdentity = identity

        if let activeManifest {
            let stamp = PackageReleaseStamp(manifest: activeManifest)
            if let highWater = loaded.highestAcceptedSignedRelease,
               stamp != highWater,
               !stamp.isStrictlyNewer(than: highWater),
               !loaded.signedRollbackIdentities.contains(identity) {
                throw PackageManifestValidationError.nonMonotonicUpdate(current: highWater, candidate: stamp)
            }
            if loaded.highestAcceptedSignedRelease.map({ stamp.isStrictlyNewer(than: $0) }) ?? true {
                loaded.highestAcceptedSignedRelease = stamp
            }
            loaded.rememberSignedIdentityForRollback(identity)
        }

        if loaded != original { try stateFile.save(loaded) }
        self.stateFile = stateFile
        self.activeVerifiedPackage = verifiedPackage
        self.state = loaded
        let rules = loaded.settings.localLLM.houseRules.trimmingCharacters(in: .whitespacesAndNewlines)
        self.classificationHouseRules = rules.isEmpty ? nil : rules
    }

    public func setOnDeviceLLM(_ llm: any OnDeviceLLM) {
        lock.lock()
        defer { lock.unlock() }
        onDeviceLLM = llm
    }

    public func setOnDeviceLLMEngineResolver(
        _ resolver: (any OnDeviceLLMEngineResolving)?
    ) {
        lock.withLock { onDeviceLLMEngineResolver = resolver }
    }

    /// The global house rules (tag counts come from the Strict↔Broad dial).
    public func setClassificationOptions(houseRules: String?) {
        lock.lock()
        defer { lock.unlock() }
        let trimmed = houseRules?.trimmingCharacters(in: .whitespacesAndNewlines)
        classificationHouseRules = (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    public func setOnVideoReclassified(
        _ callback: (@Sendable (String, String, VideoTagsProjection) -> Void)?
    ) {
        lock.withLock { onVideoReclassifiedCallback = callback }
    }

    /// Every tag id defined across the user's classifier trees — the id space a
    /// content-block policy actually acts on (the classifier emits these), so
    /// policy validation must accept them alongside the seed taxonomy.

    enum SignedActivationDisposition { case forward, explicitRollback }

    public func snapshot() -> LocalClassifierState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }
}
