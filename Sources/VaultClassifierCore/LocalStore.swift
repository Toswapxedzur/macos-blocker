import CryptoKit
import Foundation

/// Durable state for the collection, per-video LLM, policy, settings, and
/// package-lifecycle paths. Retired deterministic-classifier fields are
/// deliberately recognized while decoding and are never written back.
public struct LocalClassifierState: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var settings: ClassifierSettings
    public var policies: [NamedPolicy]
    public var workspaceCatalog: WorkspaceCatalog
    public var backupConfiguration: LocalBackupConfiguration?
    public var activeModelIdentity: ActiveModelIdentity?
    public var highestAcceptedSignedRelease: PackageReleaseStamp?
    public var signedRollbackIdentities: [ActiveModelIdentity]

    public init(
        schemaVersion: Int = 2,
        settings: ClassifierSettings = .init(),
        policies: [NamedPolicy] = [],
        workspaceCatalog: WorkspaceCatalog = .starter(),
        backupConfiguration: LocalBackupConfiguration? = nil,
        activeModelIdentity: ActiveModelIdentity? = nil,
        highestAcceptedSignedRelease: PackageReleaseStamp? = nil,
        signedRollbackIdentities: [ActiveModelIdentity] = []
    ) {
        self.schemaVersion = schemaVersion
        self.settings = settings
        self.policies = policies
        self.workspaceCatalog = workspaceCatalog
        self.backupConfiguration = backupConfiguration
        self.activeModelIdentity = activeModelIdentity
        self.highestAcceptedSignedRelease = highestAcceptedSignedRelease
        self.signedRollbackIdentities = Self.normalizedRollbackIdentities(signedRollbackIdentities)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, settings, policies, workspaceCatalog, backupConfiguration
        case activeModelIdentity, highestAcceptedSignedRelease, signedRollbackIdentities
    }

    private enum RetiredCodingKeys: String, CodingKey {
        case sequence, sourceProfiles, sourcePrior, personalModel, trainingCorpus
        case creatorClassifications, cacheBackfill, cache, ledger, auditState
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Opening this container makes the migration intent explicit. Values
        // are not decoded because the retired subsystem must never be revived.
        _ = try decoder.container(keyedBy: RetiredCodingKeys.self)
        schemaVersion = max(2, try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 2)
        settings = try container.decodeIfPresent(ClassifierSettings.self, forKey: .settings) ?? .init()
        policies = try container.decodeIfPresent([NamedPolicy].self, forKey: .policies) ?? []
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

/// Coordinates collection, per-video on-device LLM classification, settings,
/// policy validation, backups, and signed taxonomy-package lifecycle.
public final class LocalClassifierCoordinator {
    private let stateFile: LocalStateFile
    private let lock = NSLock()
    private var activeVerifiedPackage: VerifiedSeedPackage
    private var state: LocalClassifierState
    private var onDeviceLLM: any OnDeviceLLM = StubOnDeviceLLM()
    private var classificationMaximumTags: Int
    private var classificationHouseRules: String?

    public convenience init(
        verifiedPackage: VerifiedSeedPackage,
        stateFile: LocalStateFile,
        defaultPolicies: [NamedPolicy] = []
    ) throws {
        try self.init(
            verifiedPackage: verifiedPackage,
            activeManifest: nil,
            stateFile: stateFile,
            defaultPolicies: defaultPolicies
        )
    }

    public convenience init(
        verifiedModelPackage: VerifiedModelPackage,
        stateFile: LocalStateFile,
        defaultPolicies: [NamedPolicy] = []
    ) throws {
        try self.init(
            verifiedPackage: verifiedModelPackage.seedPackage,
            activeManifest: verifiedModelPackage.manifest,
            stateFile: stateFile,
            defaultPolicies: defaultPolicies
        )
    }

    public convenience init(
        lifecycle: LocalPackageLifecycle,
        fallbackVerifiedSeedPackage: VerifiedSeedPackage,
        stateFile: LocalStateFile,
        defaultPolicies: [NamedPolicy] = []
    ) throws {
        if let active = try lifecycle.activePackage() {
            try self.init(verifiedModelPackage: active, stateFile: stateFile, defaultPolicies: defaultPolicies)
        } else {
            try self.init(verifiedPackage: fallbackVerifiedSeedPackage, stateFile: stateFile, defaultPolicies: defaultPolicies)
        }
    }

    private init(
        verifiedPackage: VerifiedSeedPackage,
        activeManifest: ModelPackageManifest?,
        stateFile: LocalStateFile,
        defaultPolicies: [NamedPolicy]
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
        if loaded.policies.isEmpty { loaded.policies = defaultPolicies }
        loaded.workspaceCatalog.reconcileClassifierTypes()
        try loaded.workspaceCatalog.validate()
        try PolicyCatalog(taxonomy: verifiedPackage.taxonomy).validate(loaded.policies)
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
        self.classificationMaximumTags = loaded.settings.localLLM.maximumTags
        let rules = loaded.settings.localLLM.houseRules.trimmingCharacters(in: .whitespacesAndNewlines)
        self.classificationHouseRules = rules.isEmpty ? nil : rules
    }

    public func updateSettings(_ settings: ClassifierSettings) throws {
        lock.lock()
        defer { lock.unlock() }
        state.settings = settings
        classificationMaximumTags = settings.localLLM.maximumTags
        let rules = settings.localLLM.houseRules.trimmingCharacters(in: .whitespacesAndNewlines)
        classificationHouseRules = rules.isEmpty ? nil : rules
        try stateFile.save(state)
    }

    public func updateLocalBackupConfiguration(_ configuration: LocalBackupConfiguration?) throws {
        lock.lock()
        defer { lock.unlock() }
        if let configuration, configuration.isEnabled { _ = try configuration.directoryURL() }
        state.backupConfiguration = configuration
        try stateFile.save(state)
    }

    public func updateWorkspaceCatalog(_ catalog: WorkspaceCatalog) throws {
        lock.lock()
        defer { lock.unlock() }
        var reconciled = catalog
        reconciled.reconcileClassifierTypes()
        try reconciled.validate()
        state.workspaceCatalog = reconciled
        try stateFile.save(state)
    }

    public func enabledCollectionPlatformIDs() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return state.workspaceCatalog.bindings.filter(\.collectionEnabled).map(\.id).sorted()
    }

    public func hasClassifierTypes(platformID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return state.workspaceCatalog.classifierTypes.contains { $0.applicablePlatformID == platformID }
    }

    public func setOnDeviceLLM(_ llm: any OnDeviceLLM) {
        lock.lock()
        defer { lock.unlock() }
        onDeviceLLM = llm
    }

    public func setClassificationOptions(maximumTags: Int, houseRules: String?) {
        lock.lock()
        defer { lock.unlock() }
        classificationMaximumTags = min(16, max(1, maximumTags))
        let trimmed = houseRules?.trimmingCharacters(in: .whitespacesAndNewlines)
        classificationHouseRules = (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    public func cachedVideoTags(platformID: String, entryID: String) -> VideoTagsProjection? {
        lock.lock()
        defer { lock.unlock() }
        let catalog = state.workspaceCatalog
        let types = Self.orderedTypes(for: platformID, in: catalog)
        guard !types.isEmpty else { return nil }
        guard types.contains(where: {
            catalog.videoClassification(classifierTypeID: $0.id, platformID: platformID, entryID: entryID) != nil
        }) else { return nil }
        return Self.videoTagsProjection(entryID: entryID, platformID: platformID, types: types, catalog: catalog)
    }

    public func classifyVideo(
        platformID: String,
        entryID: String,
        creatorID: String,
        title: String,
        summary: String? = nil,
        text: String? = nil
    ) async throws -> VideoTagsProjection {
        let snapshot = lock.withLock {
            (state.workspaceCatalog, onDeviceLLM, classificationMaximumTags, classificationHouseRules)
        }
        let (catalog, llm, maximumTags, houseRules) = snapshot

        guard let binding = catalog.bindings.first(where: { $0.id == platformID }), binding.collectionEnabled else {
            throw PlatformCollectionError.disabled(platformID)
        }
        let types = Self.orderedTypes(for: platformID, in: catalog)
        guard !types.isEmpty else { return VideoTagsProjection(tags: [], predicted: false) }

        let pipeline = VideoClassificationPipeline(llm: llm, maximumTags: maximumTags)
        var classifications: [VideoClassification] = []
        for type in types {
            guard let tree = catalog.trees.first(where: { $0.id == type.treeID }),
                  type.treeRevision == tree.revision else { continue }
            classifications.append(try await pipeline.classify(
                title: title,
                summary: summary,
                text: text,
                entryID: entryID,
                creatorID: creatorID,
                platformID: platformID,
                classifierType: type,
                tree: tree,
                catalog: catalog,
                houseRules: houseRules
            ))
        }

        let saved = try lock.withLock {
            for classification in classifications { state.workspaceCatalog.upsertVideoClassification(classification) }
            try stateFile.save(state)
            return state.workspaceCatalog
        }

        let projection = Self.videoTagsProjection(entryID: entryID, platformID: platformID, types: types, catalog: saved)
        VaultDevLog.shared.log("classify", "video", [
            "platform": platformID,
            "entry": entryID,
            "creator": creatorID,
            "types": "\(types.count)",
            "classified": "\(classifications.count)",
            "tags": "\(projection.tags.count)"
        ])
        return projection
    }

    private static func orderedTypes(for platformID: String, in catalog: WorkspaceCatalog) -> [ClassifierTypeAsset] {
        catalog.classifierTypes
            .filter { $0.applicablePlatformID == platformID }
            .sorted { ($0.order, $0.id) < ($1.order, $1.id) }
    }

    private static func videoTagsProjection(
        entryID: String,
        platformID: String,
        types: [ClassifierTypeAsset],
        catalog: WorkspaceCatalog
    ) -> VideoTagsProjection {
        var tags: [TagNode] = []
        var seen = Set<String>()
        for type in types {
            guard let classification = catalog.videoClassification(
                classifierTypeID: type.id,
                platformID: platformID,
                entryID: entryID
            ), let tree = catalog.trees.first(where: { $0.id == type.treeID }),
               let taxonomy = try? tree.inferenceTaxonomy() else { continue }
            for scored in classification.tags {
                guard let node = taxonomy.nodes[scored.tagID], seen.insert(node.id).inserted else { continue }
                tags.append(node)
            }
        }
        return VideoTagsProjection(tags: tags, predicted: false)
    }

    @discardableResult
    public func collectPlatformEntry(
        _ entry: EntryEvidence,
        firstObservedAtMilliseconds requestedFirstObservedAtMilliseconds: Int64? = nil,
        lastObservedAtMilliseconds requestedLastObservedAtMilliseconds: Int64? = nil,
        observationCount requestedObservationCount: Int? = nil,
        at milliseconds: Int64 = WorkspaceCatalog.now()
    ) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }

        try EntryEvidenceValidator().validate(entry)
        guard let binding = state.workspaceCatalog.bindings.first(where: { $0.id == entry.platform }),
              binding.collectionEnabled else { throw PlatformCollectionError.disabled(entry.platform) }
        guard let entryID = entry.entryID?.trimmingCharacters(in: .whitespacesAndNewlines), !entryID.isEmpty else {
            throw PlatformCollectionError.missingEntryIdentifier
        }
        guard let creatorID = entry.sourceID?.trimmingCharacters(in: .whitespacesAndNewlines), !creatorID.isEmpty else {
            throw PlatformCollectionError.missingCreatorIdentifier
        }
        guard let title = entry.evidence.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            throw PlatformCollectionError.missingTitle
        }

        let metadata = collectionMetadata(from: entry.evidence.metadata, platformID: entry.platform)
        guard metadata["isAdvertisement"] != "true" else { throw PlatformCollectionError.advertisement }
        let entryType = metadata["entryType"]?.lowercased() ?? "content"
        guard entryType != "advertisement", entryType != "ad" else { throw PlatformCollectionError.advertisement }
        let creatorName = metadata["sourceName"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let canonicalURL = metadata["canonicalURL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceIconURL = metadata["sourceIconURL"].flatMap {
            SourceIconURLPolicy.isAccepted(platformID: entry.platform, value: $0) ? $0 : nil
        }
        let maximumFutureTimestamp = milliseconds + (5 * 60 * 1_000)
        let firstObservedAtMilliseconds = requestedFirstObservedAtMilliseconds.flatMap {
            $0 > 0 && $0 <= maximumFutureTimestamp ? $0 : nil
        } ?? milliseconds
        let lastObservedAtMilliseconds = max(
            firstObservedAtMilliseconds,
            requestedLastObservedAtMilliseconds.flatMap {
                $0 > 0 && $0 <= maximumFutureTimestamp ? $0 : nil
            } ?? firstObservedAtMilliseconds
        )
        let observationCount = min(512, max(1, requestedObservationCount ?? 1))
        let stableMaterial = "\(entry.platform)\u{1F}\(entryID)"
        let stableID = SHA256.hash(data: Data(stableMaterial.utf8)).map { String(format: "%02x", $0) }.joined()
        let collected = CollectedPlatformEntry(
            id: "collected-\(stableID)",
            platformID: entry.platform,
            entryID: entryID,
            creatorID: creatorID,
            sourceAliases: entry.sourceAliases,
            creatorName: creatorName?.isEmpty == false ? creatorName! : creatorID,
            entryType: entryType,
            title: title,
            surface: entry.surface,
            text: entry.evidence.text,
            summary: entry.evidence.summary,
            suppliedTags: entry.evidence.suppliedTags,
            canonicalURL: canonicalURL?.isEmpty == false ? canonicalURL : nil,
            sourceIconURL: sourceIconURL,
            attributes: metadata.filter {
                key, _ in
                key != "sourceName" && key != "canonicalURL" && key != "entryType" &&
                    key != "isAdvertisement" && key != "sourceIconURL"
            },
            firstObservedAtMilliseconds: firstObservedAtMilliseconds,
            lastObservedAtMilliseconds: lastObservedAtMilliseconds,
            observationCount: observationCount
        )
        guard let datasetIndex = state.workspaceCatalog.datasets.firstIndex(where: { $0.id == binding.datasetID }) else {
            throw WorkspaceCatalogError.missingDataset(binding.datasetID)
        }
        let inserted = state.workspaceCatalog.datasets[datasetIndex].upsertCollectedEntry(collected)
        try state.workspaceCatalog.validate()
        try stateFile.save(state)
        return inserted
    }

    private func collectionMetadata(from metadata: [String: JSONValue], platformID: String) -> [String: String] {
        var output: [String: String] = [:]
        for key in metadata.keys.sorted() {
            guard key != "creatorAvatarURL", key != "creatorURL" else { continue }
            guard output.count < CollectedPlatformEntry.maximumAttributes + 4,
                  key.count <= CollectedPlatformEntry.maximumAttributeKeyLength,
                  let value = metadata[key] else { continue }
            let rendered: String
            switch value {
            case .string(let text): rendered = text
            case .number(let number): rendered = number.formatted(.number.grouping(.never))
            case .bool(let bool): rendered = bool ? "true" : "false"
            }
            guard !rendered.isEmpty, rendered.count <= CollectedPlatformEntry.maximumAttributeValueLength else { continue }
            if key == "sourceIconURL", !SourceIconURLPolicy.isAccepted(platformID: platformID, value: rendered) {
                continue
            }
            output[key] = rendered
        }
        return output
    }

    @discardableResult
    public func backupLocalModelNow(at date: Date = .now) throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        guard let configuration = state.backupConfiguration, configuration.isEnabled else {
            throw LocalBackupError.backupDisabled
        }
        return try LocalModelBackup().backup(
            state: state,
            package: activeVerifiedPackage,
            in: configuration.directoryURL(),
            at: date
        )
    }

    public func replacePolicies(_ policies: [NamedPolicy]) throws {
        lock.lock()
        defer { lock.unlock() }
        try PolicyCatalog(taxonomy: activeVerifiedPackage.taxonomy).validate(policies)
        state.policies = policies
        try stateFile.save(state)
    }

    public func activateVerifiedModelPackage(_ verifiedPackage: VerifiedModelPackage) throws {
        try replacePackage(verifiedPackage, disposition: .forward)
    }

    public func activateRecordedRollbackModelPackage(_ verifiedPackage: VerifiedModelPackage) throws {
        try replacePackage(verifiedPackage, disposition: .explicitRollback)
    }

    private enum SignedActivationDisposition { case forward, explicitRollback }

    private func replacePackage(
        _ verifiedPackage: VerifiedModelPackage,
        disposition: SignedActivationDisposition
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        try PolicyCatalog(taxonomy: verifiedPackage.seedPackage.taxonomy).validate(state.policies)
        let manifest = verifiedPackage.manifest
        let identity = ActiveModelIdentity(
            kind: .signedPackage,
            packageID: manifest.packageID,
            taxonomyVersion: manifest.taxonomyVersion,
            modelVersion: manifest.modelVersion,
            seedChecksum: nil,
            releaseSequence: manifest.releaseSequence,
            payloadSHA256: manifest.payloadSHA256
        )
        guard identity.isStructurallyValid else { throw PackageManifestValidationError.storedPackageMismatch }
        let stamp = PackageReleaseStamp(manifest: manifest)
        switch disposition {
        case .forward:
            if let highWater = state.highestAcceptedSignedRelease, !stamp.isStrictlyNewer(than: highWater) {
                throw PackageManifestValidationError.nonMonotonicUpdate(current: highWater, candidate: stamp)
            }
        case .explicitRollback:
            guard state.signedRollbackIdentities.contains(identity) else {
                throw PackageManifestValidationError.nonMonotonicUpdate(
                    current: state.highestAcceptedSignedRelease ?? stamp,
                    candidate: stamp
                )
            }
        }
        if let current = state.activeModelIdentity, current.kind == .signedPackage {
            state.rememberSignedIdentityForRollback(current)
        }
        state.activeModelIdentity = identity
        if disposition == .forward { state.highestAcceptedSignedRelease = stamp }
        state.rememberSignedIdentityForRollback(identity)
        try stateFile.save(state)
        activeVerifiedPackage = verifiedPackage.seedPackage
    }

    public func policies() -> [NamedPolicy] {
        lock.lock()
        defer { lock.unlock() }
        return state.policies
    }

    public func snapshot() -> LocalClassifierState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }
}
