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
/// policy validation, backups, and signed taxonomy-package lifecycle.
public final class LocalClassifierCoordinator: @unchecked Sendable {
    private let stateFile: LocalStateFile
    private let lock = NSLock()
    private var activeVerifiedPackage: VerifiedSeedPackage
    private var state: LocalClassifierState
    private var onDeviceLLM: any OnDeviceLLM = StubOnDeviceLLM()
    private var onDeviceLLMEngineResolver: (any OnDeviceLLMEngineResolving)?
    private var classificationMaximumTags: Int
    private var classificationHouseRules: String?
    private var groundedResearchQueue: GroundedResearchQueue?
    private var onVideoReclassifiedCallback: (@Sendable (String, String, VideoTagsProjection) -> Void)?

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
        try PolicyCatalog(taxonomy: verifiedPackage.taxonomy, additionalValidTagIDs: Self.treeTagIDs(loaded.workspaceCatalog)).validate(loaded.policies)
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

    /// Removes one knowledge entry (term or creator) by id. Deleting a creator
    /// description lets it be re-researched; deleting a term forgets it.
    public func deleteKnowledgeEntry(id: String) throws {
        lock.lock()
        defer { lock.unlock() }
        state.workspaceCatalog.knowledgeEntries.removeAll { $0.id == id }
        state.workspaceCatalog.creatorKnowledge.removeAll { $0.id == id }
        try stateFile.save(state)
    }

    /// Edits the grounded description of an existing knowledge entry, keeping its
    /// kind, subject, id, and sources. A creator description edited here steers
    /// that creator's low-confidence classifications.
    @discardableResult
    public func updateKnowledgeEntryMeaning(id: String, meaning: String) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let trimmed = meaning.trimmingCharacters(in: .whitespacesAndNewlines)
        func apply(_ entries: inout [KnowledgeEntry]) -> Bool {
            guard let index = entries.firstIndex(where: { $0.id == id }) else { return false }
            let existing = entries[index]
            entries[index] = KnowledgeEntry(
                kind: existing.kind,
                subject: existing.subject,
                meaning: trimmed,
                contextTagHints: existing.contextTagHints,
                sourceURLs: existing.sourceURLs,
                createdAtMilliseconds: existing.createdAtMilliseconds,
                updatedAtMilliseconds: WorkspaceCatalog.now()
            )
            return true
        }
        let changed = apply(&state.workspaceCatalog.knowledgeEntries)
            || apply(&state.workspaceCatalog.creatorKnowledge)
        if changed { try stateFile.save(state) }
        return changed
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

    /// Collection-enabled platforms whose active classifier type(s) want
    /// thumbnail-OCR evidence (default ON per type). The extension OCRs
    /// thumbnails and sends their text only for these platforms.
    public func ocrEvidencePlatformIDs() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let catalog = state.workspaceCatalog
        let enabled = Set(catalog.bindings.filter(\.collectionEnabled).map(\.id))
        var platforms = Set<String>()
        for type in catalog.classifierTypes {
            guard let platformID = type.applicablePlatformID, enabled.contains(platformID) else { continue }
            if type.localModelOverrides?.effectiveThumbnailOcrEvidence ?? LocalModelOverrides.defaultThumbnailOcrEvidence {
                platforms.insert(platformID)
            }
        }
        return platforms.sorted()
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

    public func setClassificationOptions(maximumTags: Int, houseRules: String?) {
        lock.lock()
        defer { lock.unlock() }
        classificationMaximumTags = min(16, max(1, maximumTags))
        let trimmed = houseRules?.trimmingCharacters(in: .whitespacesAndNewlines)
        classificationHouseRules = (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    public func setGroundedResearchQueue(_ queue: GroundedResearchQueue?) {
        lock.withLock { groundedResearchQueue = queue }
    }

    public func setOnVideoReclassified(
        _ callback: (@Sendable (String, String, VideoTagsProjection) -> Void)?
    ) {
        lock.withLock { onVideoReclassifiedCallback = callback }
    }

    public func groundedResearchQueueSnapshot(for task: ResearchTask) -> GroundedResearchQueueSnapshot {
        lock.withLock {
            let settings = state.workspaceCatalog.classifierTypes.first(where: {
                $0.id == task.classifierTypeID
            }).map { $0.researchOverrides ?? state.settings.research } ?? state.settings.research
            // Dedup research against both maps: keyed creators (permanent) and
            // active term knowledge. A creator already keyed is never re-fetched.
            let knownKeys = (state.workspaceCatalog.knowledgeEntries
                + state.workspaceCatalog.creatorKnowledge)
                .filter { $0.isActive(ttlDays: settings.knowledgeTTLDays) }
                .map(\.id)
            return .init(
                existingKnowledgeKeys: Set(knownKeys),
                failedAttempts: state.workspaceCatalog.researchAttempts,
                tokenUsage: state.workspaceCatalog.tokenUsage
            )
        }
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

    /// Every tag id defined across the user's classifier trees — the id space a
    /// content-block policy actually acts on (the classifier emits these), so
    /// policy validation must accept them alongside the seed taxonomy.
    static func treeTagIDs(_ catalog: WorkspaceCatalog) -> Set<String> {
        Set(catalog.trees.flatMap { $0.nodes.map(\.id) })
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
            (
                state.workspaceCatalog,
                onDeviceLLM,
                onDeviceLLMEngineResolver,
                state.settings.localLLM,
                classificationMaximumTags,
                classificationHouseRules,
                state.settings.research,
                groundedResearchQueue
            )
        }
        let (
            catalog, defaultLLM, engineResolver, localLLMSettings,
            maximumTags, houseRules, globalResearchSettings, researchQueue
        ) = snapshot

        guard let binding = catalog.bindings.first(where: { $0.id == platformID }), binding.collectionEnabled else {
            throw PlatformCollectionError.disabled(platformID)
        }
        let types = Self.orderedTypes(for: platformID, in: catalog)
        guard !types.isEmpty else { return VideoTagsProjection(tags: [], predicted: false) }

        var classifications: [VideoClassification] = []
        var researchCandidates: [(
            ClassifierTypeAsset,
            VideoClassification,
            ResearchSettings,
            any OnDeviceLLM
        )] = []
        for type in types {
            guard let tree = catalog.trees.first(where: { $0.id == type.treeID }),
                  type.treeRevision == tree.revision else { continue }
            // A correction is authoritative for this taxonomy revision. Live
            // requests and research-triggered refreshes must not overwrite it
            // with a later model decision.
            if let corrected = catalog.videoClassification(
                classifierTypeID: type.id,
                platformID: platformID,
                entryID: entryID
            ), corrected.source == .humanCorrected,
               corrected.treeID == tree.id,
               corrected.treeRevision == tree.revision {
                classifications.append(corrected)
                continue
            }
            let overrides = type.localModelOverrides
            let knowledgeSettings = type.researchOverrides ?? globalResearchSettings
            let llm = await Self.resolvedLLM(
                for: type,
                defaultLLM: defaultLLM,
                resolver: engineResolver,
                configuration: localLLMSettings
            )
            let pipeline = VideoClassificationPipeline(llm: llm, maximumTags: maximumTags)
            // `text` carries the thumbnail-OCR evidence; honor the per-type opt-out.
            let typeText = (overrides?.effectiveThumbnailOcrEvidence ?? LocalModelOverrides.defaultThumbnailOcrEvidence) ? text : nil
            let classification = try await pipeline.classify(
                title: title,
                summary: summary,
                text: typeText,
                entryID: entryID,
                creatorID: creatorID,
                platformID: platformID,
                classifierType: type,
                tree: tree,
                catalog: catalog,
                houseRules: Self.effectiveHouseRules(
                    global: houseRules,
                    perType: overrides?.houseRules
                ),
                allowDecline: overrides?.allowDecline,
                confidenceThresholds: overrides?.confidenceThresholds,
                knowledgeTTLDays: knowledgeSettings.knowledgeTTLDays,
                maxKnowledgePerVideo: knowledgeSettings.maxKnowledgePerVideo,
                creatorGroundingConfidenceFloor: knowledgeSettings.confidenceTriggerLevel
            )
            classifications.append(classification)
            if let effectiveResearch = Self.effectiveResearchSettings(
                global: globalResearchSettings,
                for: type
            ) {
                researchCandidates.append((type, classification, effectiveResearch, llm))
            }
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
        if let researchQueue {
            for (type, classification, settings, llm) in researchCandidates
            where Self.shouldTriggerResearch(for: classification, settings: settings) {
                let hasWeakCreatorPrior = catalog.creatorHistogram(
                    classifierTypeID: type.id,
                    platformID: platformID,
                    creatorID: creatorID
                ) == nil
                Self.scheduleResearchSubjectExtraction(
                    llm: llm,
                    queue: researchQueue,
                    settings: settings,
                    classifierTypeID: type.id,
                    platformID: platformID,
                    entryID: entryID,
                    creatorID: creatorID,
                    title: title,
                    summary: summary,
                    includeCreator: hasWeakCreatorPrior
                )
            }
        }
        return projection
    }

    private static func resolvedLLM(
        for classifierType: ClassifierTypeAsset,
        defaultLLM: any OnDeviceLLM,
        resolver: (any OnDeviceLLMEngineResolving)?,
        configuration: LocalLLMSettings
    ) async -> any OnDeviceLLM {
        // The overwhelmingly common inherited-model route deliberately avoids
        // even an actor hop, preserving the pre-registry live pill path.
        guard let fileName = classifierType.modelFileName,
              let resolver else { return defaultLLM }
        do {
            return try await resolver.resolveEngine(
                forModel: fileName,
                configuration: configuration
            )
        } catch {
            VaultDevLog.shared.log("llm", "type-model-fallback", [
                "type": classifierType.id,
                "requested": fileName,
                "error": String(describing: error),
            ])
            return defaultLLM
        }
    }

    /// Resolves the type-level defaults without weakening the app-wide consent
    /// switch. A type may opt itself out, but it can never opt itself in while
    /// the global master gate is off.
    public static func effectiveResearchSettings(
        global: ResearchSettings,
        for classifierType: ClassifierTypeAsset
    ) -> ResearchSettings? {
        guard global.enabled else { return nil }
        let effective = classifierType.researchOverrides ?? global
        return effective.enabled ? effective : nil
    }

    private static func effectiveHouseRules(global: String?, perType: String?) -> String? {
        // A type's own house rules REPLACE the global rules (intentional override).
        // `perType` may still carry a legacy distilled "Learned preferences" block
        // from before corrections moved to per-video retrieval; keep only its
        // manual portion so stale distillations never leak back into the prompt.
        let manualPerType = CorrectionDistiller.manualRules(from: perType)
        if !manualPerType.isEmpty { return manualPerType }
        let trimmedGlobal = global?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmedGlobal?.isEmpty == false) ? trimmedGlobal : nil
    }

    public static func hasExplicitModelDecline(
        _ classifications: [VideoClassification]
    ) -> Bool {
        classifications.contains { $0.source == .model && $0.tags.isEmpty }
    }

    public static func shouldTriggerResearch(
        for classification: VideoClassification,
        settings: ResearchSettings
    ) -> Bool {
        guard classification.source == .model,
              settings.trigger.includesLiveClassification else { return false }
        if classification.tags.isEmpty { return true }
        guard settings.trigger.includesLowConfidence else { return false }
        return (classification.tags.map(\.confidence).max() ?? 0) <= settings.confidenceTriggerLevel
    }

    private static func scheduleResearchSubjectExtraction(
        llm: any OnDeviceLLM,
        resolver: (any OnDeviceLLMEngineResolving)? = nil,
        localLLMSettings: LocalLLMSettings = LocalLLMSettings(),
        classifierType: ClassifierTypeAsset? = nil,
        queue: GroundedResearchQueue,
        settings: ResearchSettings,
        classifierTypeID: String,
        platformID: String,
        entryID: String,
        creatorID: String,
        title: String,
        summary: String?,
        includeCreator: Bool
    ) {
        Task.detached(priority: .utility) {
            let extractionLLM: any OnDeviceLLM
            if let classifierType {
                extractionLLM = await Self.resolvedLLM(
                    for: classifierType,
                    defaultLLM: llm,
                    resolver: resolver,
                    configuration: localLLMSettings
                )
            } else {
                extractionLLM = llm
            }
            guard let extractor = extractionLLM as? any OnDeviceResearchSubjectExtracting else { return }
            var subjects: [ResearchSubject] = []
            if let subject = try? await extractor.extractResearchSubject(
                .init(title: title, summary: summary)
            ) {
                subjects.append(subject)
            }
            if includeCreator,
               subjects.count < settings.maxSubjectsPerVideo,
               let creator = ResearchSubject(kind: .creator, subject: creatorID) {
                subjects.append(creator)
            }
            guard !subjects.isEmpty else { return }
            _ = await queue.enqueue(.init(
                classifierTypeID: classifierTypeID,
                platformID: platformID,
                entryID: entryID,
                creatorID: creatorID,
                subjects: Array(subjects.prefix(settings.maxSubjectsPerVideo))
            ))
        }
    }

    /// Drops every persisted research cooldown so the next classification of
    /// each affected video may research again. Returns how many were cleared.
    @discardableResult
    public func clearResearchAttempts() -> Int {
        (try? lock.withLock { () -> Int in
            let count = state.workspaceCatalog.researchAttempts.count
            guard count > 0 else { return 0 }
            state.workspaceCatalog.researchAttempts.removeAll()
            try stateFile.save(state)
            return count
        }) ?? 0
    }

    public func recordResearchMutation(_ mutation: GroundedResearchQueueMutation) async {
        do {
            switch mutation {
            case .failed(_, let attempt):
                try lock.withLock {
                    state.workspaceCatalog.upsertResearchAttempt(attempt)
                    try stateFile.save(state)
                }
            case .retryRequested(let task, let subjectKey):
                try lock.withLock {
                    state.workspaceCatalog.removeResearchAttempt(
                        subjectKey: subjectKey,
                        classifierTypeID: task.classifierTypeID
                    )
                    try stateFile.save(state)
                }
            case .succeeded(let task, let result, let usage):
                try await recordResearchKnowledge(
                    result.knowledge,
                    usage: usage,
                    triggeringTask: task
                )
            }
        } catch {
            VaultDevLog.shared.log("research", "persist-failed", ["error": String(describing: error)])
        }
    }

    /// Persists under the coordinator lock, releases it, then performs every
    /// local reclassification. The non-reentrant NSLock is never held across an
    /// await.
    public func recordResearchKnowledge(
        _ entry: KnowledgeEntry,
        usage: TokenUsageRecord,
        triggeringTask: ResearchTask
    ) async throws {
        let affected: [CollectedPlatformEntry] = try lock.withLock {
            let storedEntry: KnowledgeEntry
            if entry.kind == .creator {
                storedEntry = KnowledgeEntry(
                    kind: .creator,
                    subject: triggeringTask.creatorID,
                    meaning: entry.meaning,
                    contextTagHints: [],
                    sourceURLs: entry.sourceURLs,
                    createdAtMilliseconds: entry.createdAtMilliseconds,
                    updatedAtMilliseconds: entry.updatedAtMilliseconds
                )
            } else {
                storedEntry = entry
            }
            state.workspaceCatalog.upsertKnowledgeEntry(storedEntry)
            state.workspaceCatalog.removeResearchAttempt(
                subjectKey: entry.id,
                classifierTypeID: triggeringTask.classifierTypeID
            )
            state.workspaceCatalog.tokenUsage.insert(usage, at: 0)
            Self.pruneTokenUsage(&state.workspaceCatalog.tokenUsage)
            let affected = Self.affectedEntries(
                for: storedEntry,
                triggeringTask: triggeringTask,
                catalog: state.workspaceCatalog,
                limit: 8
            )
            try stateFile.save(state)
            return affected
        }

        for collected in affected {
            let projection = try await Task.detached(priority: .utility) { [self] in
                try await classifyVideo(
                    platformID: collected.platformID,
                    entryID: collected.entryID,
                    creatorID: collected.creatorID,
                    title: collected.title,
                    summary: collected.summary,
                    text: collected.text
                )
            }.value
            let callback = lock.withLock { onVideoReclassifiedCallback }
            callback?(collected.platformID, collected.entryID, projection)
        }
    }

    public func startResearchBackfill(limit requestedLimit: Int = 16) {
        let snapshot = lock.withLock {
            (
                state.workspaceCatalog,
                state.settings.research,
                groundedResearchQueue,
                onDeviceLLM,
                onDeviceLLMEngineResolver,
                state.settings.localLLM
            )
        }
        let (catalog, globalSettings, queue, defaultLLM, resolver, localLLMSettings) = snapshot
        guard globalSettings.enabled, let queue else { return }
        let limit = min(32, max(1, requestedLimit))
        let eligible = catalog.videoClassifications
            .filter { $0.source == .model }
            .sorted { $0.updatedAtMilliseconds < $1.updatedAtMilliseconds }
        var seen = Set<String>()
        let candidates = eligible.compactMap { classification -> (
            entry: CollectedPlatformEntry,
            classifierType: ClassifierTypeAsset,
            settings: ResearchSettings
        )? in
            guard let classifierType = catalog.classifierTypes.first(where: {
                $0.id == classification.classifierTypeID
            }), let settings = Self.effectiveResearchSettings(
                global: globalSettings,
                for: classifierType
            ), Self.shouldTriggerResearch(for: classification, settings: settings) else { return nil }
            let key = "\(classification.classifierTypeID)\u{1F}\(classification.platformID)\u{1F}\(classification.entryID)"
            guard seen.insert(key).inserted else { return nil }
            guard let entry = Self.collectedEntry(
                platformID: classification.platformID,
                entryID: classification.entryID,
                catalog: catalog
            ) else { return nil }
            return (entry, classifierType, settings)
        }.prefix(limit)

        Task.detached(priority: .utility) {
            for candidate in candidates {
                let entry = candidate.entry
                let settings = candidate.settings
                let llm = await Self.resolvedLLM(
                    for: candidate.classifierType,
                    defaultLLM: defaultLLM,
                    resolver: resolver,
                    configuration: localLLMSettings
                )
                guard let extractor = llm as? any OnDeviceResearchSubjectExtracting else { continue }
                var subjects: [ResearchSubject] = []
                if let subject = try? await extractor.extractResearchSubject(
                    .init(title: entry.title, summary: entry.summary)
                ) {
                    subjects.append(subject)
                }
                if subjects.count < settings.maxSubjectsPerVideo,
                   let creator = ResearchSubject(kind: .creator, subject: entry.creatorID) {
                    subjects.append(creator)
                }
                guard !subjects.isEmpty else { continue }
                _ = await queue.enqueue(.init(
                    classifierTypeID: candidate.classifierType.id,
                    platformID: entry.platformID,
                    entryID: entry.entryID,
                    creatorID: entry.creatorID,
                    subjects: Array(subjects.prefix(settings.maxSubjectsPerVideo))
                ))
            }
        }
    }

    /// Stores an authoritative human correction, periodically refreshes the
    /// type's learned rule block, updates the cached projection, and—when the
    /// user has opted in and the type's trigger includes corrections—schedules
    /// the same sanitized second-decode research path used by model triggers.
    @discardableResult
    public func submitCorrection(
        classifierTypeID: String,
        platformID: String,
        entryID: String,
        correctTagIDs: [String],
        note: String? = nil
    ) throws -> VideoTagsProjection {
        let saved = try lock.withLock { () throws -> (
            projection: VideoTagsProjection,
            entry: CollectedPlatformEntry,
            llm: any OnDeviceLLM,
            resolver: (any OnDeviceLLMEngineResolving)?,
            localLLMSettings: LocalLLMSettings,
            queue: GroundedResearchQueue?,
            settings: ResearchSettings?,
            classifierType: ClassifierTypeAsset,
            callback: (@Sendable (String, String, VideoTagsProjection) -> Void)?
        ) in
            guard let typeIndex = state.workspaceCatalog.classifierTypes.firstIndex(where: {
                $0.id == classifierTypeID && $0.applicablePlatformID == platformID
            }) else { throw CorrectionSubmissionError.invalidClassifierType }
            let type = state.workspaceCatalog.classifierTypes[typeIndex]
            guard let tree = state.workspaceCatalog.trees.first(where: {
                $0.id == type.treeID && $0.revision == type.treeRevision
            }) else { throw CorrectionSubmissionError.invalidClassifierType }
            guard let entry = Self.collectedEntry(
                platformID: platformID,
                entryID: entryID,
                catalog: state.workspaceCatalog
            ) else { throw CorrectionSubmissionError.missingCollectedEntry }
            let taxonomy = try tree.inferenceTaxonomy()
            let uniqueTagIDs = Array(Set(correctTagIDs)).sorted()
            guard uniqueTagIDs.count <= CorrectionExample.maximumTagIDs,
                  uniqueTagIDs.allSatisfy({ taxonomy.nodes[$0]?.predictable == true }) else {
                throw CorrectionSubmissionError.invalidTagSelection
            }

            let example = CorrectionExample(
                classifierTypeID: classifierTypeID,
                platformID: platformID,
                entryID: entryID,
                creatorID: entry.creatorID,
                title: entry.title,
                correctTagIDs: uniqueTagIDs,
                note: note
            )
            state.workspaceCatalog.appendCorrectionExample(example)
            // The correction is now stored. It is NOT distilled into a static
            // per-type house-rules block anymore: corrections drive classification
            // through per-video retrieval (CorrectionRetriever) instead, so each
            // video sees the corrections most relevant to IT rather than a
            // recency-ordered block shared across every video. Manual house rules
            // (the user's typed preferences) remain untouched in localModelOverrides.

            let previous = state.workspaceCatalog.videoClassification(
                classifierTypeID: classifierTypeID,
                platformID: platformID,
                entryID: entryID
            )
            state.workspaceCatalog.upsertVideoClassification(.init(
                id: previous?.id ?? UUID().uuidString,
                classifierTypeID: classifierTypeID,
                platformID: platformID,
                entryID: entryID,
                creatorID: entry.creatorID,
                treeID: tree.id,
                treeRevision: tree.revision,
                tags: uniqueTagIDs.map { .init(tagID: $0, confidence: ScoredTag.maxConfidence) },
                unknownTerms: [],
                knowledgeRefs: previous?.knowledgeRefs ?? [],
                source: .humanCorrected,
                modelVersion: previous?.modelVersion ?? "human-correction-v1",
                createdAtMilliseconds: previous?.createdAtMilliseconds ?? WorkspaceCatalog.now()
            ))
            try stateFile.save(state)
            let types = Self.orderedTypes(for: platformID, in: state.workspaceCatalog)
            return (
                Self.videoTagsProjection(
                    entryID: entryID,
                    platformID: platformID,
                    types: types,
                    catalog: state.workspaceCatalog
                ),
                entry,
                onDeviceLLM,
                onDeviceLLMEngineResolver,
                state.settings.localLLM,
                groundedResearchQueue,
                Self.effectiveResearchSettings(global: state.settings.research, for: type),
                type,
                onVideoReclassifiedCallback
            )
        }

        saved.callback?(platformID, entryID, saved.projection)
        // Corrections are surfaced to the classifier by per-video retrieval
        // (CorrectionRetriever), not a static distilled block, and never by a
        // local-LLM free-text "re-summary" — a small model asked to generalize a
        // handful of corrections fabricates spurious rules ("tag Samsung as
        // Sports") that poison classification. Grounded exemplars beat invented
        // framing; see the creator prior for the same lesson.
        if let settings = saved.settings,
           settings.trigger.includesCorrections,
           let queue = saved.queue {
            Self.scheduleResearchSubjectExtraction(
                llm: saved.llm,
                resolver: saved.resolver,
                localLLMSettings: saved.localLLMSettings,
                classifierType: saved.classifierType,
                queue: queue,
                settings: settings,
                classifierTypeID: saved.classifierType.id,
                platformID: platformID,
                entryID: entryID,
                creatorID: saved.entry.creatorID,
                title: saved.entry.title,
                summary: saved.entry.summary,
                includeCreator: true
            )
        }
        return saved.projection
    }

    private static func collectedEntry(
        platformID: String,
        entryID: String,
        catalog: WorkspaceCatalog
    ) -> CollectedPlatformEntry? {
        catalog.datasets.lazy.flatMap(\.collectedEntries).first {
            $0.platformID == platformID && $0.entryID == entryID
        }
    }

    private static func affectedEntries(
        for knowledge: KnowledgeEntry,
        triggeringTask: ResearchTask,
        catalog: WorkspaceCatalog,
        limit: Int
    ) -> [CollectedPlatformEntry] {
        let allEntries = catalog.datasets.flatMap(\.collectedEntries)
        let creatorMembers: Set<String>
        if knowledge.kind == .creator {
            creatorMembers = CreatorIdentityIndex(entries: allEntries).members(of: triggeringTask.creatorID)
        } else {
            creatorMembers = []
        }
        let candidates = allEntries.filter { entry in
            guard entry.platformID == triggeringTask.platformID else { return false }
            if entry.entryID == triggeringTask.entryID { return true }
            switch knowledge.kind {
            case .term: return knowledge.matches(title: entry.title)
            case .creator: return creatorMembers.contains(entry.creatorID)
            }
        }.filter { entry in
            if entry.entryID == triggeringTask.entryID { return true }
            let rows = catalog.videoClassifications.filter {
                $0.platformID == entry.platformID && $0.entryID == entry.entryID
            }
            return rows.contains {
                $0.tags.isEmpty || ($0.tags.map(\.confidence).max() ?? 0) <= 2
            }
        }.sorted { lhs, rhs in
            if lhs.entryID == triggeringTask.entryID { return true }
            if rhs.entryID == triggeringTask.entryID { return false }
            return lhs.lastObservedAtMilliseconds > rhs.lastObservedAtMilliseconds
        }
        var seen = Set<String>()
        return Array(candidates.filter {
            seen.insert("\($0.platformID)\u{1F}\($0.entryID)").inserted
        }.prefix(max(1, limit)))
    }

    private static func pruneTokenUsage(_ records: inout [TokenUsageRecord]) {
        let todayStart = Int64(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 * 1_000)
        let required = Set(records.filter {
            $0.status == GroundedResearchQueue.researchUsageStatus &&
                $0.createdAtMilliseconds >= todayStart
        }.map(\.id))
        records = Array(records.enumerated().filter { offset, record in
            offset < 200 || required.contains(record.id)
        }.map(\.element).prefix(2_000))
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
        var confidenceByTagID: [String: Int] = [:]
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
                confidenceByTagID[node.id] = scored.confidence
            }
        }
        return VideoTagsProjection(tags: tags, predicted: false, confidenceByTagID: confidenceByTagID)
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
            if key == "thumbnailURL", !ThumbnailURLPolicy.isAccepted(platformID: platformID, value: rendered) {
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
        try PolicyCatalog(taxonomy: activeVerifiedPackage.taxonomy, additionalValidTagIDs: Self.treeTagIDs(state.workspaceCatalog)).validate(policies)
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
        try PolicyCatalog(taxonomy: verifiedPackage.seedPackage.taxonomy, additionalValidTagIDs: Self.treeTagIDs(state.workspaceCatalog)).validate(state.policies)
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
