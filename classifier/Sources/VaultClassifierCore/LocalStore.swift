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
    /// Per state file: each collected-entries day file last written → its
    /// signature, so a save rewrites only the days that changed.
    private static var writtenDays: [String: [String: CollectedDaySignature]] = [:]

    public init(url: URL) { self.url = url }

    /// Collected entries live beside the state (owner 2026-09-30: kept for
    /// months, they would make one file rewritten on every save huge):
    /// `collected/<dataset>/<platform>/<yyyy-MM-dd>.json`, by the day an entry
    /// was first seen.
    var collectedDirectory: URL { Self.collectedDirectory(for: url) }

    static func collectedDirectory(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent("collected", isDirectory: true)
    }

    public func load(or defaultState: LocalClassifierState = .init()) throws -> LocalClassifierState {
        Self.ioQueue.sync {}
        guard FileManager.default.fileExists(atPath: url.path) else { return defaultState }
        var state = try JSONDecoder().decode(LocalClassifierState.self, from: Data(contentsOf: url))
        let directory = collectedDirectory
        let manager = FileManager.default
        // Entries inside the state file (saved before the split) are not in any
        // day file yet: the first save then writes every day.
        let savedInside = state.workspaceCatalog.datasets.contains { !$0.collectedEntries.isEmpty }
        for index in state.workspaceCatalog.datasets.indices {
            let datasetDirectory = directory.appendingPathComponent(Self.pathComponent(state.workspaceCatalog.datasets[index].id), isDirectory: true)
            // Entries still inside the state (saved before the split) stay; the
            // next save moves them out.
            var known = Set(state.workspaceCatalog.datasets[index].collectedEntries.map(\.id))
            for platform in (try? manager.contentsOfDirectory(at: datasetDirectory, includingPropertiesForKeys: nil)) ?? [] {
                for day in (try? manager.contentsOfDirectory(at: platform, includingPropertiesForKeys: nil)) ?? [] where day.pathExtension == "json" {
                    guard let data = try? Data(contentsOf: day),
                          let entries = try? JSONDecoder().decode([CollectedPlatformEntry].self, from: data) else { continue }
                    for entry in entries where known.insert(entry.id).inserted {
                        state.workspaceCatalog.datasets[index].collectedEntries.append(entry)
                    }
                }
            }
        }
        let signatures = savedInside ? [:] : Self.collectedDays(of: state).mapValues(Self.signature)
        Self.lock.lock()
        Self.writtenDays[url.path] = signatures
        Self.lock.unlock()
        return state
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
            let manager = FileManager.default
            try manager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            // The collected entries go to their day files; the state file holds the rest.
            let days = collectedDays(of: state)
            var slim = state
            for index in slim.workspaceCatalog.datasets.indices { slim.workspaceCatalog.datasets[index].collectedEntries = [] }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let directory = collectedDirectory(for: url)
            lock.lock()
            let previous = writtenDays[url.path] ?? [:]
            lock.unlock()
            var written: [String: CollectedDaySignature] = [:]
            let compact = JSONEncoder()
            for (relative, entries) in days {
                let signature = signature(entries)
                written[relative] = signature
                guard previous[relative] != signature else { continue }
                let file = directory.appendingPathComponent(relative)
                try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try compact.encode(entries).write(to: file, options: .atomic)
                try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            }
            for relative in previous.keys where written[relative] == nil {
                try? manager.removeItem(at: directory.appendingPathComponent(relative))
            }
            lock.lock()
            writtenDays[url.path] = written
            lock.unlock()
            try encoder.encode(slim).write(to: url, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            // Best-effort background persistence; the session state remains authoritative.
        }
    }

    /// Collected entries grouped by their day file ("<dataset>/<platform>/<day>.json").
    static func collectedDays(of state: LocalClassifierState) -> [String: [CollectedPlatformEntry]] {
        var days: [String: [CollectedPlatformEntry]] = [:]
        var dayNames: [Int64: String] = [:]
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        for dataset in state.workspaceCatalog.datasets {
            let datasetPart = pathComponent(dataset.id)
            for entry in dataset.collectedEntries {
                let dayNumber = entry.firstObservedAtMilliseconds / 86_400_000
                let dayName = dayNames[dayNumber] ?? {
                    let name = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(dayNumber) * 86_400))
                    dayNames[dayNumber] = name
                    return name
                }()
                days["\(datasetPart)/\(pathComponent(entry.platformID))/\(dayName).json", default: []].append(entry)
            }
        }
        return days
    }

    /// Cheap change detector for one day file: an update to an entry moves its
    /// last-seen time or observation count.
    static func signature(_ entries: [CollectedPlatformEntry]) -> CollectedDaySignature {
        var signature = CollectedDaySignature()
        for entry in entries {
            signature.count += 1
            signature.lastSeen &+= entry.lastObservedAtMilliseconds
            signature.observations &+= entry.observationCount
            signature.textBytes &+= (entry.text?.utf8.count ?? 0) + entry.title.utf8.count + entry.creatorName.utf8.count
        }
        return signature
    }

    static func pathComponent(_ value: String) -> String {
        String(value.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." ? $0 : "_" })
    }
}

struct CollectedDaySignature: Equatable, Sendable {
    var count = 0
    var lastSeen: Int64 = 0
    var observations = 0
    var textBytes = 0
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
    /// When the collection Keep was last applied (see `collect`).
    var lastCollectionPrune: Int64 = 0
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
        loaded.workspaceCatalog.pruneCollectedEntries()
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
