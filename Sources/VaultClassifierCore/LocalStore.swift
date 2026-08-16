import CryptoKit
import Foundation

public enum UserCorrection: String, Codable, Sendable, CaseIterable {
    case falseAllow
    case falseDim
    case falseBlock
}

/// Cached direct-only refreshes must never be mistaken for a final decision.
/// The causal FIFO pass is the sole path that sets `.causallyReplayed` after a
/// package/settings/model backfill begins.
public enum CachedEntryReplayState: String, Codable, Equatable, Sendable {
    case awaitingCausalReplay
    case causallyReplayed
}

public struct CachedEntry: Codable, Equatable, Sendable, Identifiable {
    public var key: String
    public var savedAt: Date
    public var evidence: EntryEvidence
    public var result: ClassificationResult
    /// The exact local model that produced `result`. Legacy rows decode with a
    /// nil identity and remain retained for local history/backfill, but cannot
    /// be treated as a current model result.
    public var modelIdentity: ActiveModelIdentity?
    /// Direct-only refreshes are intentionally provisional. This state is
    /// persisted per row because a backfill can span relaunches and batches.
    public var replayState: CachedEntryReplayState

    public var id: String { key }

    public init(
        key: String,
        savedAt: Date,
        evidence: EntryEvidence,
        result: ClassificationResult,
        modelIdentity: ActiveModelIdentity? = nil,
        replayState: CachedEntryReplayState = .causallyReplayed
    ) {
        self.key = key
        self.savedAt = savedAt
        self.evidence = evidence
        self.result = result
        self.modelIdentity = modelIdentity
        self.replayState = replayState
    }

    private enum CodingKeys: String, CodingKey {
        case key, savedAt, evidence, result, modelIdentity, replayState
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        savedAt = try container.decode(Date.self, forKey: .savedAt)
        evidence = try container.decode(EntryEvidence.self, forKey: .evidence)
        result = try container.decode(ClassificationResult.self, forKey: .result)
        modelIdentity = try container.decodeIfPresent(ActiveModelIdentity.self, forKey: .modelIdentity)
        // A persisted row from before the two-stage contract was produced by
        // the normal causal runtime. Identity checks still keep incompatible
        // legacy results out of current-model paths.
        replayState = try container.decodeIfPresent(CachedEntryReplayState.self, forKey: .replayState) ?? .causallyReplayed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encode(savedAt, forKey: .savedAt)
        try container.encode(evidence, forKey: .evidence)
        try container.encode(result, forKey: .result)
        try container.encodeIfPresent(modelIdentity, forKey: .modelIdentity)
        try container.encode(replayState, forKey: .replayState)
    }
}

public struct DecisionLedgerEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var cacheKey: String
    public var recordedAt: Date
    public var packageID: String
    public var modelVersion: String
    public var evidenceState: ClassificationEvidenceState
    public var directScores: [String: Double]
    public var sourceScores: [String: Double]
    public var finalScores: [String: Double]
    public var actions: [String: PresentationAction]
    public var correction: UserCorrection?

    public init(cacheKey: String, result: ClassificationResult, recordedAt: Date = .now) {
        self.id = UUID()
        self.cacheKey = cacheKey
        self.recordedAt = recordedAt
        self.packageID = result.packageID
        self.modelVersion = result.modelVersion
        self.evidenceState = result.evidenceState
        self.directScores = Dictionary(uniqueKeysWithValues: result.scores.map { ($0.tagID, $0.directScore) })
        self.sourceScores = Dictionary(uniqueKeysWithValues: result.scores.compactMap { score in score.sourceScore.map { (score.tagID, $0) } })
        self.finalScores = Dictionary(uniqueKeysWithValues: result.scores.map { ($0.tagID, $0.finalScore) })
        self.actions = Dictionary(uniqueKeysWithValues: result.decisions.map { ($0.policyID, $0.action) })
        self.correction = nil
    }

}

public struct LocalClassifierState: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var sequence: Int64
    public var settings: ClassifierSettings
    public var policies: [NamedPolicy]
    public var sourceProfiles: [String: SourceProfile]
    public var personalModel: PersonalFTRLModel
    /// Explicit, local-only labels used to reproducibly rebuild
    /// `personalModel`. This is separate from cache and ledger history so
    /// browsing or correction events cannot become labels by accident.
    public var trainingCorpus: LocalTrainingCorpus
    /// Shared user-owned tree, model, dataset, bridge, and token-ledger assets.
    public var workspaceCatalog: WorkspaceCatalog
    /// Optional private, user-owned local snapshot destination. The owner-code
    /// verifier lives in Keychain, never in this state file.
    public var backupConfiguration: LocalBackupConfiguration?
    public var cacheBackfill: CacheBackfillProgress?
    /// Persisted exact package identity. Missing/invalid legacy state is never
    /// treated as equivalent to a current model.
    public var activeModelIdentity: ActiveModelIdentity?
    /// Monotonic high-water mark for direct signed-package activation. It is
    /// intentionally retained across a temporary seed fallback.
    public var highestAcceptedSignedRelease: PackageReleaseStamp?
    /// Exact signed packages that were previously made active locally and may
    /// therefore be selected only through the explicit rollback path.
    public var signedRollbackIdentities: [ActiveModelIdentity]
    public var cache: [CachedEntry]
    public var ledger: [DecisionLedgerEntry]

    public init(schemaVersion: Int = 1, sequence: Int64 = 0, settings: ClassifierSettings = .init(), policies: [NamedPolicy] = [], sourceProfiles: [String: SourceProfile] = [:], personalModel: PersonalFTRLModel = .init(), trainingCorpus: LocalTrainingCorpus = .init(), workspaceCatalog: WorkspaceCatalog = .starter(), backupConfiguration: LocalBackupConfiguration? = nil, cacheBackfill: CacheBackfillProgress? = nil, activeModelIdentity: ActiveModelIdentity? = nil, highestAcceptedSignedRelease: PackageReleaseStamp? = nil, signedRollbackIdentities: [ActiveModelIdentity] = [], cache: [CachedEntry] = [], ledger: [DecisionLedgerEntry] = []) {
        self.schemaVersion = schemaVersion
        self.sequence = sequence
        self.settings = settings
        self.policies = policies
        self.sourceProfiles = sourceProfiles
        self.personalModel = personalModel
        self.trainingCorpus = trainingCorpus
        self.workspaceCatalog = workspaceCatalog
        self.backupConfiguration = backupConfiguration
        self.cacheBackfill = cacheBackfill
        self.activeModelIdentity = activeModelIdentity
        self.highestAcceptedSignedRelease = highestAcceptedSignedRelease
        self.signedRollbackIdentities = Self.normalizedRollbackIdentities(signedRollbackIdentities)
        self.cache = cache
        self.ledger = ledger
    }

    public mutating func record(
        entry: EntryEvidence,
        result: ClassificationResult,
        modelIdentity: ActiveModelIdentity? = nil,
        replayState: CachedEntryReplayState = .causallyReplayed,
        at date: Date = .now
    ) {
        let key = Self.cacheKey(for: entry)
        cache.removeAll { $0.key == key }
        cache.append(.init(
            key: key,
            savedAt: date,
            evidence: entry,
            result: result,
            modelIdentity: modelIdentity,
            replayState: replayState
        ))
        let ledgerEntry = DecisionLedgerEntry(cacheKey: key, result: result, recordedAt: date)
        ledger.append(ledgerEntry)
        let cacheLimit = max(1, settings.cacheCapacity)
        if cache.count > cacheLimit { cache.removeFirst(cache.count - cacheLimit) }
        let ledgerLimit = max(cacheLimit, 1_000)
        if ledger.count > ledgerLimit { ledger.removeFirst(ledger.count - ledgerLimit) }
    }

    public mutating func setCorrection(ledgerID: UUID, correction: UserCorrection?) {
        guard let index = ledger.firstIndex(where: { $0.id == ledgerID }) else { return }
        ledger[index].correction = correction
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, sequence, settings, policies, sourceProfiles, personalModel, trainingCorpus, workspaceCatalog, backupConfiguration, cacheBackfill, activeModelIdentity, highestAcceptedSignedRelease, signedRollbackIdentities, cache, ledger
    }

    private enum RetiredCodingKeys: String, CodingKey {
        case auditState
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let retired = try decoder.container(keyedBy: RetiredCodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        sequence = try container.decodeIfPresent(Int64.self, forKey: .sequence) ?? 0
        settings = try container.decodeIfPresent(ClassifierSettings.self, forKey: .settings) ?? .init()
        policies = try container.decodeIfPresent([NamedPolicy].self, forKey: .policies) ?? []
        sourceProfiles = try container.decodeIfPresent([String: SourceProfile].self, forKey: .sourceProfiles) ?? [:]
        personalModel = try container.decodeIfPresent(PersonalFTRLModel.self, forKey: .personalModel) ?? .init()
        trainingCorpus = try container.decodeIfPresent(LocalTrainingCorpus.self, forKey: .trainingCorpus) ?? .init()
        workspaceCatalog = try container.decodeIfPresent(WorkspaceCatalog.self, forKey: .workspaceCatalog) ?? .starter()
        backupConfiguration = try container.decodeIfPresent(LocalBackupConfiguration.self, forKey: .backupConfiguration)
        cacheBackfill = try container.decodeIfPresent(CacheBackfillProgress.self, forKey: .cacheBackfill)
        // Identity fields are defensive migration input. A malformed legacy
        // value must not make the whole local classifier state unreadable; it
        // instead becomes an incompatible identity at coordinator bootstrap.
        activeModelIdentity = (try? container.decodeIfPresent(ActiveModelIdentity.self, forKey: .activeModelIdentity)) ?? nil
        if activeModelIdentity?.isStructurallyValid != true { activeModelIdentity = nil }
        highestAcceptedSignedRelease = (try? container.decodeIfPresent(PackageReleaseStamp.self, forKey: .highestAcceptedSignedRelease)) ?? nil
        signedRollbackIdentities = Self.normalizedRollbackIdentities(
            (try? container.decodeIfPresent([ActiveModelIdentity].self, forKey: .signedRollbackIdentities)) ?? []
        )
        cache = try container.decodeIfPresent([CachedEntry].self, forKey: .cache) ?? []
        ledger = try container.decodeIfPresent([DecisionLedgerEntry].self, forKey: .ledger) ?? []
        if retired.contains(.auditState) || trainingCorpus.removedRetiredAuditLabels {
            // Personal Audit was intentionally retired. Its queued records and
            // any model trained from its labels must not remain active.
            personalModel = .init()
            trainingCorpus.lastRun = nil
        }
        trainingCorpus.acknowledgeRetiredAuditLabelRemoval()
    }

    public static func cacheKey(for entry: EntryEvidence) -> String {
        if let entryID = entry.entryID, !entryID.isEmpty { return "\(entry.platform):\(entryID)" }
        let encoded = (try? JSONEncoder().encode(entry)) ?? Data(entry.requestID.utf8)
        let digest = SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
        return "\(entry.platform):\(digest)"
    }

    /// Applies a model-bound invalidation while retaining raw cache evidence,
    /// decision history and user corrections.
    /// Cached rows are deliberately not rewritten: their old identity keeps
    /// them visibly stale until an explicit backfill replaces their result.
    public mutating func resetDerivedModelState(for identity: ActiveModelIdentity) {
        activeModelIdentity = identity
        sourceProfiles = [:]
        cacheBackfill = nil
        for index in cache.indices {
            cache[index].replayState = .awaitingCausalReplay
        }
    }

    public func hasOnlyCurrentCacheRows(for identity: ActiveModelIdentity) -> Bool {
        cache.allSatisfy { $0.modelIdentity == identity && identity.matches($0.result) }
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

    // One process-wide serial queue owns every state write. Because it is
    // shared, `load()` can flush a write that a *different* instance enqueued
    // for the same file, so save→reload stays deterministic while callers never
    // block on the encode/write themselves.
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

    /// Persists without blocking the caller. The encode and atomic write run on
    /// a serial background queue, and rapid successive saves of the same file
    /// coalesce into a single write of the newest state — so a high-frequency
    /// writer (the activated LLM loop) never stalls the main thread. The
    /// in-memory state stays authoritative for the session; `throws` is retained
    /// for source compatibility and background write failures are best-effort.
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

    /// Blocks until every queued write has finished. Call before process exit so
    /// the newest state reaches disk.
    public func flushSynchronously() {
        Self.ioQueue.sync {}
    }

    /// Blocks until every queued write across all state files has finished.
    /// Call from `applicationWillTerminate` so a clean quit never drops the last
    /// coalesced write.
    public static func flushAllPendingWrites() {
        ioQueue.sync {}
    }

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
            // Best-effort background persistence.
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

/// Coordinates the deterministic engine with the bounded on-device cache and decision ledger.
/// It has no network dependency; later sync and LLM-audit tiers can be layered around this API.
public final class LocalClassifierCoordinator {
    private let stateFile: LocalStateFile
    private let lock = NSLock()
    private var activeVerifiedPackage: VerifiedSeedPackage
    private var activeVerifiedManifest: ModelPackageManifest?
    private var engine: LocalClassifierEngine
    private var state: LocalClassifierState
    // Memoized creator-identity index for source-tag lookups. Rebuilding the
    // union-find over every collected entry per request dominated pill latency
    // (~11 ms per lookup over a few thousand entries); the index depends only on
    // the dataset's collected entries, so it is reused until those change.
    private var identityIndexCache: (datasetID: String, revision: Int, entryCount: Int, index: CreatorIdentityIndex)?
    // The on-device LLM used for per-video classification (local-LLM rework).
    // Defaults to a deterministic stub until a real MLX-backed model is wired;
    // settable so the app can inject one without touching the many initializers.
    private var onDeviceLLM: any OnDeviceLLM = StubOnDeviceLLM()

    public convenience init(verifiedPackage: VerifiedSeedPackage, stateFile: LocalStateFile, defaultPolicies: [NamedPolicy] = []) throws {
        try self.init(
            verifiedPackage: verifiedPackage,
            activeManifest: nil,
            stateFile: stateFile,
            defaultPolicies: defaultPolicies
        )
    }

    /// Use this initializer when reopening a locally staged active package.
    /// It retains the verified manifest identity in memory so an interrupted
    /// explicit backfill can safely resume only for that exact signed payload.
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

    /// Opens from the lifecycle's independently verified active package when
    /// one is available, otherwise from the bundled seed. This is a recovery
    /// helper, not a network/update path: lifecycle persistence and classifier
    /// persistence remain separate durable records and are intentionally not
    /// presented as one atomic transaction.
    public convenience init(
        lifecycle: LocalPackageLifecycle,
        fallbackVerifiedSeedPackage: VerifiedSeedPackage,
        stateFile: LocalStateFile,
        defaultPolicies: [NamedPolicy] = []
    ) throws {
        if let active = try lifecycle.activePackage() {
            try self.init(
                verifiedModelPackage: active,
                stateFile: stateFile,
                defaultPolicies: defaultPolicies
            )
        } else {
            try self.init(
                verifiedPackage: fallbackVerifiedSeedPackage,
                stateFile: stateFile,
                defaultPolicies: defaultPolicies
            )
        }
    }

    private init(
        verifiedPackage: VerifiedSeedPackage,
        activeManifest: ModelPackageManifest?,
        stateFile: LocalStateFile,
        defaultPolicies: [NamedPolicy]
    ) throws {
        let identity: ActiveModelIdentity
        if let activeManifest {
            identity = .init(
                kind: .signedPackage,
                packageID: activeManifest.packageID,
                taxonomyVersion: activeManifest.taxonomyVersion,
                modelVersion: activeManifest.modelVersion,
                seedChecksum: nil,
                releaseSequence: activeManifest.releaseSequence,
                payloadSHA256: activeManifest.payloadSHA256
            )
        } else {
            identity = .init(seed: verifiedPackage)
        }
        guard identity.isStructurallyValid else {
            throw PackageManifestValidationError.storedPackageMismatch
        }

        var loaded = try stateFile.load()
        let originalState = loaded
        if loaded.policies.isEmpty { loaded.policies = defaultPolicies }
        // Capability rules are durable catalog constraints. Reconcile a
        // catalog from an earlier build before it is exposed so a manual-only
        // platform cannot retain a stale model or LLM-assist assignment.
        loaded.workspaceCatalog.reconcileClassifierTypes()
        try loaded.workspaceCatalog.validate()
        let taxonomy = try verifiedPackage.taxonomy
        // Persisted policies are input, not trusted derived state. Validate
        // before publishing an engine so a removed/renamed taxonomy tag cannot
        // silently become an allow-all or get discarded during bootstrap.
        try PolicyCatalog(taxonomy: taxonomy).validate(loaded.policies)

        let priorIdentity = loaded.activeModelIdentity
        let identityChanged = priorIdentity != identity
        let cacheIsCurrent = loaded.hasOnlyCurrentCacheRows(for: identity)
        let backfillIsCurrent = Self.isCurrentBackfill(
            loaded.cacheBackfill,
            for: identity
        )
        let hasActiveBackfillContinuation = Self.hasValidBackfillContinuation(
            loaded.cacheBackfill,
            for: identity,
            cacheKeys: loaded.cache.map(\.key)
        )
        let hasProvisionalCacheRows = loaded.cache.contains {
            $0.replayState != .causallyReplayed
        }
        // During a valid explicit two-stage backfill, stale/provisional cache
        // rows are expected and must resume rather than being restarted on each
        // relaunch. If that continuation is missing or malformed, however,
        // those rows can never become audit-eligible without a fresh replay.
        let requiresDerivedStateRecovery = identityChanged
            || !backfillIsCurrent
            || (!cacheIsCurrent && !hasActiveBackfillContinuation)
            || (hasProvisionalCacheRows && !hasActiveBackfillContinuation)
        if requiresDerivedStateRecovery {
            loaded.resetDerivedModelState(for: identity)
        } else {
            loaded.activeModelIdentity = identity
        }

        if let activeManifest {
            let candidateStamp = PackageReleaseStamp(manifest: activeManifest)
            if let highWater = loaded.highestAcceptedSignedRelease {
                if candidateStamp.isStrictlyNewer(than: highWater) {
                    loaded.highestAcceptedSignedRelease = candidateStamp
                } else if candidateStamp == highWater,
                          priorIdentity != identity,
                          !loaded.signedRollbackIdentities.contains(identity) {
                    throw PackageManifestValidationError.nonMonotonicUpdate(
                        current: highWater,
                        candidate: candidateStamp
                    )
                } else if candidateStamp != highWater,
                          !loaded.signedRollbackIdentities.contains(identity) {
                    // A lifecycle-backed bootstrap may recover only an exact
                    // locally recorded rollback identity. Matching the old
                    // active-state field alone must not bypass the durable
                    // signed-release high-water mark.
                    throw PackageManifestValidationError.nonMonotonicUpdate(
                        current: highWater,
                        candidate: candidateStamp
                    )
                }
            } else {
                loaded.highestAcceptedSignedRelease = candidateStamp
            }
            loaded.rememberSignedIdentityForRollback(identity)
            if requiresDerivedStateRecovery, !loaded.cache.isEmpty {
                // Reopening a verified signed package must not strand stale or
                // provisional retained rows. This only persists an explicit
                // continuation; it never runs classification automatically.
                loaded.cacheBackfill = .init(
                    packageID: activeManifest.packageID,
                    modelVersion: activeManifest.modelVersion,
                    releaseSequence: activeManifest.releaseSequence,
                    payloadSHA256: activeManifest.payloadSHA256
                )
            }
        }

        let candidateEngine = try LocalClassifierEngine(
            verifiedPackage: verifiedPackage,
            policies: loaded.policies,
            sourceProfiles: loaded.sourceProfiles,
            personalModel: loaded.personalModel,
            sequence: loaded.sequence,
            settings: loaded.settings
        )
        // Identity migration/reset is durable before an engine becomes visible.
        // A failed save leaves the caller without a coordinator rather than
        // publishing an in-memory model that disagrees with disk state.
        if loaded != originalState {
            try stateFile.save(loaded)
        }
        self.stateFile = stateFile
        self.activeVerifiedPackage = verifiedPackage
        self.activeVerifiedManifest = activeManifest
        self.engine = candidateEngine
        self.state = loaded
    }

    public func classify(_ entry: EntryEvidence) throws -> ClassificationResult {
        try classifyWithLedger(entry).result
    }

    public func classifyWithLedger(_ entry: EntryEvidence) throws -> (result: ClassificationResult, ledgerID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        let workspaceClassifier = try state.workspaceCatalog.workspaceClassifier(
            for: entry.platform,
            policies: engine.policies
        )
        // Causal replay protects the legacy source-prior engine only. The
        // workspace neural model has no source-profile mutation, so it can
        // serve an explicit classifier type immediately and deterministically.
        let requiresCausalReplay = workspaceClassifier == nil && state.cacheBackfill != nil
        let result: ClassificationResult
        if let workspaceClassifier {
            result = try workspaceClassifier.classify(entry)
        } else if requiresCausalReplay {
            // Do not let a foreground entry mutate a partial causal source
            // profile. It receives the same explicitly provisional direct-only
            // treatment as stage one and restarts the retained snapshot.
            result = try classifyDirectOnly(entry)
        } else {
            result = try engine.classify(entry)
        }
        state.record(
            entry: entry,
            result: result,
            modelIdentity: state.activeModelIdentity,
            replayState: requiresCausalReplay ? .awaitingCausalReplay : .causallyReplayed
        )
        if requiresCausalReplay {
            restartBackfillAfterCacheMutation()
        }
        synchronizeEngineState()
        try stateFile.save(state)
        guard let ledgerID = state.ledger.last?.id else { throw LocalClassifierStoreError.missingLedgerEntry }
        return (result, ledgerID)
    }

    public func setCorrection(ledgerID: UUID, correction: UserCorrection?) throws {
        lock.lock()
        defer { lock.unlock() }
        state.setCorrection(ledgerID: ledgerID, correction: correction)
        try stateFile.save(state)
    }

    public func updateSettings(_ settings: ClassifierSettings) throws {
        lock.lock()
        defer { lock.unlock() }
        engine.settings = settings
        if state.cacheBackfill != nil {
            restartBackfillAfterCacheMutation()
        }
        synchronizeEngineState()
        state.trimRetainedData()
        try stateFile.save(state)
    }

    /// Stores a supervised label for the current local taxonomy. This does not
    /// change a classification until `retrainLocalModel` is explicitly called,
    /// making collection and token-free model rebuilding independently
    /// controllable.
    @discardableResult
    public func recordLocalTrainingExample(
        evidence: EntryEvidence,
        positiveLeafTagIDs: [String],
        negativeLeafTagIDs: [String] = [],
        origin: LocalTrainingLabelOrigin = .explicitUser,
        at date: Date = .now
    ) throws -> LocalTrainingExample {
        lock.lock()
        defer { lock.unlock() }
        let example = try makeValidatedTrainingExample(
            evidence: evidence,
            positiveLeafTagIDs: positiveLeafTagIDs,
            negativeLeafTagIDs: negativeLeafTagIDs,
            origin: origin,
            at: date
        )
        state.trainingCorpus.upsert(example, limit: state.settings.cacheCapacity)
        try stateFile.save(state)
        return example
    }

    /// Rebuilds the bounded local correction layer from retained explicit
    /// labels. The seed package remains immutable and no network, provider,
    /// account, or browser path is involved.
    @discardableResult
    public func retrainLocalModel(epochs: Int = 3, at date: Date = .now) throws -> LocalTrainingRun {
        lock.lock()
        defer { lock.unlock() }
        var replacementEngine = engine
        let report = try replacementEngine.rebuildPersonalModel(
            from: state.trainingCorpus.examples,
            epochs: epochs
        )
        let run = LocalTrainingRun(
            exampleCount: report.exampleCount,
            labelUpdateCount: report.labelUpdateCount,
            epochs: epochs,
            taxonomyVersion: replacementEngine.package.taxonomyVersion,
            completedAtMilliseconds: Self.milliseconds(date)
        )
        var replacementState = state
        replacementState.trainingCorpus.lastRun = run
        synchronize(workingEngine: replacementEngine, into: &replacementState)
        try stateFile.save(replacementState)
        engine = replacementEngine
        state = replacementState
        backupCurrentModelIfConfigured(state: replacementState, at: date)
        return run
    }

    /// The optional configuration is persisted locally. Enabling it does not
    /// send or mount anything; it merely makes future successful local model
    /// rebuilds write a private snapshot to the chosen folder.
    public func updateLocalBackupConfiguration(_ configuration: LocalBackupConfiguration?) throws {
        lock.lock()
        defer { lock.unlock() }
        if let configuration, configuration.isEnabled {
            _ = try configuration.directoryURL()
        }
        state.backupConfiguration = configuration
        try stateFile.save(state)
    }

    public func updateWorkspaceCatalog(_ catalog: WorkspaceCatalog) throws {
        lock.lock()
        defer { lock.unlock() }
        var reconciledCatalog = catalog
        reconciledCatalog.reconcileClassifierTypes()
        try reconciledCatalog.validate()
        state.workspaceCatalog = reconciledCatalog
        try stateFile.save(state)
    }

    /// Returns only locally enabled collection bindings. The browser asks for
    /// this small inventory before it sends any rendered public-content
    /// metadata, so an off toggle prevents title/creator data leaving the page.
    public func enabledCollectionPlatformIDs() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return state.workspaceCatalog.bindings
            .filter(\.collectionEnabled)
            .map(\.id)
            .sorted()
    }

    /// Returns a display-only projection of approved tags for one verified
    /// source. This does not classify an entry, create a ledger record, or
    /// persist browser state.
    public func sourceTags(platformID: String, sourceID: String, creatorNames: [String] = []) throws -> SourceTagsProjection {
        lock.lock()
        defer { lock.unlock() }
        guard let binding = state.workspaceCatalog.bindings.first(where: { $0.id == platformID }),
              binding.collectionEnabled else {
            throw PlatformCollectionError.disabled(platformID)
        }
        let dataset = state.workspaceCatalog.datasets.first(where: { $0.id == binding.datasetID })
        // A platform may host several classifier types, each owning its own tree.
        // A card unions their tags in list order (deduped by id); the union is
        // "predicted" only when every contributing tag came from a model guess.
        let classifiers = try state.workspaceCatalog.workspaceClassifiers(
            for: platformID,
            policies: engine.policies,
            identityIndex: dataset.map(memoizedIdentityIndex(for:))
        )
        var tags: [TagNode] = []
        var seen = Set<String>()
        var anyApproved = false
        for classifier in classifiers {
            let resolved = classifierSourceTags(
                classifier,
                platformID: platformID,
                sourceID: sourceID,
                creatorNames: creatorNames,
                dataset: dataset
            )
            guard !resolved.tags.isEmpty else { continue }
            if !resolved.predicted { anyApproved = true }
            for tag in resolved.tags where seen.insert(tag.id).inserted {
                tags.append(tag)
            }
        }
        return SourceTagsProjection(tags: tags, predicted: !tags.isEmpty && !anyApproved)
    }

    /// One classifier type's tags for a source: an approved decision by linked
    /// identity, then by supplied collaboration names, then the local model's
    /// on-demand prediction over the creator's collected titles. The caller
    /// already holds `lock`.
    private func classifierSourceTags(
        _ classifier: WorkspaceNeuralClassifier,
        platformID: String,
        sourceID: String,
        creatorNames: [String],
        dataset: ClassificationDataset?
    ) -> (tags: [TagNode], predicted: Bool) {
        let direct = classifier.sourceTags(platformID: platformID, sourceID: sourceID)
        if !direct.isEmpty { return (direct, false) }
        // A collaboration card exposes no creator link, only unlinked names. When
        // the linked identity resolves nothing, fall back to matching a supplied
        // display name against an approved classification.
        if !creatorNames.isEmpty {
            let named = classifier.sourceTags(platformID: platformID, anyOfCreatorNames: creatorNames)
            if !named.isEmpty { return (named, false) }
        }
        // Fallback (computed on demand, not stored): with no approved human/LLM
        // decision, project the local model's aggregated prediction so the feed
        // pill still shows a guess.
        let identityForms = classifier.identityIndex.members(of: sourceID)
        let candidateTitles = (dataset?.collectedEntries ?? [])
            .filter { identityForms.contains($0.creatorID) }
            .map(\.title)
        let predicted = classifier.predictedSourceTags(candidateTitles: candidateTitles)
        return (predicted, !predicted.isEmpty)
    }

    /// Returns a creator-identity index for `dataset`, reusing the cached one
    /// while the dataset's collected entries are unchanged. Collecting an entry
    /// or approving a label does not advance the dataset revision, so the entry
    /// count is included in the key to catch newly collected creators. The caller
    /// already holds `lock`.
    private func memoizedIdentityIndex(for dataset: ClassificationDataset) -> CreatorIdentityIndex {
        if let cache = identityIndexCache,
           cache.datasetID == dataset.id,
           cache.revision == dataset.revision,
           cache.entryCount == dataset.collectedEntries.count {
            return cache.index
        }
        let index = CreatorIdentityIndex(entries: dataset.collectedEntries)
        identityIndexCache = (dataset.id, dataset.revision, dataset.collectedEntries.count, index)
        return index
    }

    // MARK: - Per-video classification (local-LLM rework)

    /// Whether any classifier type targets this platform. When none do, the
    /// per-video path returns a definitive empty result rather than queuing
    /// classification forever (which would leave a stuck "Tagging" pill).
    public func hasClassifierTypes(platformID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return state.workspaceCatalog.classifierTypes.contains { $0.applicablePlatformID == platformID }
    }

    /// Injects the on-device LLM used for per-video classification.
    public func setOnDeviceLLM(_ llm: any OnDeviceLLM) {
        lock.lock()
        defer { lock.unlock() }
        onDeviceLLM = llm
    }

    /// The decision cache: the union of every applicable classifier type's stored
    /// `VideoClassification` for this video, if any exists. Returns nil when the
    /// video has not been classified yet (the caller then triggers classification).
    public func cachedVideoTags(platformID: String, entryID: String) -> SourceTagsProjection? {
        lock.lock()
        defer { lock.unlock() }
        let catalog = state.workspaceCatalog
        let types = Self.orderedTypes(for: platformID, in: catalog)
        guard !types.isEmpty else { return nil }
        let hasAny = types.contains { type in
            catalog.videoClassification(classifierTypeID: type.id, platformID: platformID, entryID: entryID) != nil
        }
        guard hasAny else { return nil }
        return Self.videoTagsProjection(entryID: entryID, platformID: platformID, types: types, catalog: catalog)
    }

    /// Classify one video with the on-device LLM across every applicable
    /// classifier type on its platform, persist the results (refreshing the
    /// derived creator histograms), and return the union of tags. The LLM call
    /// runs OUTSIDE the lock (the lock is only held to snapshot inputs and to
    /// persist outputs), so it never blocks other requests during inference.
    public func classifyVideo(
        platformID: String,
        entryID: String,
        creatorID: String,
        title: String,
        summary: String? = nil,
        text: String? = nil
    ) async throws -> SourceTagsProjection {
        lock.lock()
        let catalog = state.workspaceCatalog
        let llm = onDeviceLLM
        lock.unlock()

        guard let binding = catalog.bindings.first(where: { $0.id == platformID }), binding.collectionEnabled else {
            throw PlatformCollectionError.disabled(platformID)
        }
        let types = Self.orderedTypes(for: platformID, in: catalog)
        guard !types.isEmpty else { return SourceTagsProjection(tags: [], predicted: false) }

        let pipeline = VideoClassificationPipeline(llm: llm)
        var classifications: [VideoClassification] = []
        for type in types {
            guard let tree = catalog.trees.first(where: { $0.id == type.treeID }),
                  type.treeRevision == tree.revision else { continue }
            let classification = try await pipeline.classify(
                title: title, summary: summary, text: text,
                entryID: entryID, creatorID: creatorID, platformID: platformID,
                classifierType: type, tree: tree, catalog: catalog, houseRules: nil
            )
            classifications.append(classification)
        }

        lock.lock()
        for classification in classifications {
            state.workspaceCatalog.upsertVideoClassification(classification)
        }
        try? stateFile.save(state)
        let saved = state.workspaceCatalog
        lock.unlock()

        let projection = Self.videoTagsProjection(entryID: entryID, platformID: platformID, types: types, catalog: saved)
        VaultDevLog.shared.log("classify", "video", [
            "platform": platformID, "entry": entryID, "creator": creatorID,
            "types": "\(types.count)", "classified": "\(classifications.count)", "tags": "\(projection.tags.count)"
        ])
        return projection
    }

    private static func orderedTypes(for platformID: String, in catalog: WorkspaceCatalog) -> [ClassifierTypeAsset] {
        catalog.classifierTypes
            .filter { $0.applicablePlatformID == platformID }
            .sorted { ($0.order, $0.id) < ($1.order, $1.id) }
    }

    /// Union the per-type video classifications for one video into display tags,
    /// in classifier-type order, deduped by id.
    private static func videoTagsProjection(
        entryID: String,
        platformID: String,
        types: [ClassifierTypeAsset],
        catalog: WorkspaceCatalog
    ) -> SourceTagsProjection {
        var tags: [TagNode] = []
        var seen = Set<String>()
        for type in types {
            guard let classification = catalog.videoClassification(classifierTypeID: type.id, platformID: platformID, entryID: entryID),
                  let tree = catalog.trees.first(where: { $0.id == type.treeID }),
                  let taxonomy = try? tree.inferenceTaxonomy() else { continue }
            for scored in classification.tags {
                guard let node = taxonomy.nodes[scored.tagID], seen.insert(node.id).inserted else { continue }
                tags.append(node)
            }
        }
        return SourceTagsProjection(tags: tags, predicted: false)
    }

    /// Persists one bounded, already-rendered platform entry. This is separate
    /// from classification and labels: a collected entry is never eligible for
    /// model training until an explicit manual or approved LLM record exists.
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
              binding.collectionEnabled else {
            throw PlatformCollectionError.disabled(entry.platform)
        }
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
        guard metadata["isAdvertisement"] != "true" else {
            throw PlatformCollectionError.advertisement
        }
        let entryType = metadata["entryType"]?.lowercased() ?? "content"
        guard entryType != "advertisement", entryType != "ad" else {
            throw PlatformCollectionError.advertisement
        }
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
                key != "sourceName" &&
                key != "canonicalURL" &&
                key != "entryType" &&
                key != "isAdvertisement" &&
                key != "sourceIconURL"
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

    /// Policies are authored by the local app and validated against the active
    /// taxonomy before they ever reach an extension request. A failed update
    /// leaves the previous in-memory and persisted set untouched.
    public func replacePolicies(_ policies: [NamedPolicy]) throws {
        lock.lock()
        defer { lock.unlock() }
        try PolicyCatalog(taxonomy: engine.taxonomy).validate(policies)
        engine.policies = policies
        if state.cacheBackfill != nil {
            restartBackfillAfterCacheMutation()
        }
        synchronizeEngineState()
        try stateFile.save(state)
    }

    /// Activates only a package capability created by
    /// `PackageManifestValidator`. Cached decisions keep their original
    /// package IDs; ordinary future classifications use the new atomic
    /// tree/model pair. Existing policies must be valid in the replacement
    /// taxonomy so policy semantics cannot silently broaden or disappear
    /// during an update.
    ///
    /// `VerifiedModelPackage` has no public initializer, so consumers outside
    /// this module cannot wrap an arbitrary `VerifiedSeedPackage` and bypass
    /// the signed-manifest validation path. This is a forward-only path: its
    /// signed release must advance the coordinator's durable high-water mark.
    public func activateVerifiedModelPackage(_ verifiedPackage: VerifiedModelPackage) throws {
        try replacePackage(
            verifiedPackage.seedPackage,
            manifest: verifiedPackage.manifest,
            disposition: .forward
        )
    }

    /// Explicit rollback only. The package must be an exact signed identity
    /// previously activated by this local coordinator; a merely valid older
    /// signed candidate cannot use this path to bypass replay protection.
    public func activateRecordedRollbackModelPackage(_ verifiedPackage: VerifiedModelPackage) throws {
        try replacePackage(
            verifiedPackage.seedPackage,
            manifest: verifiedPackage.manifest,
            disposition: .explicitRollback
        )
    }

    private enum SignedActivationDisposition {
        case forward
        case explicitRollback
    }

    private func replacePackage(
        _ verifiedPackage: VerifiedSeedPackage,
        manifest: ModelPackageManifest,
        disposition: SignedActivationDisposition
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        let replacementTaxonomy = try verifiedPackage.taxonomy
        try PolicyCatalog(taxonomy: replacementTaxonomy).validate(engine.policies)
        let identity = ActiveModelIdentity(
            kind: .signedPackage,
            packageID: manifest.packageID,
            taxonomyVersion: manifest.taxonomyVersion,
            modelVersion: manifest.modelVersion,
            seedChecksum: nil,
            releaseSequence: manifest.releaseSequence,
            payloadSHA256: manifest.payloadSHA256
        )
        guard identity.isStructurallyValid else {
            throw PackageManifestValidationError.storedPackageMismatch
        }
        let candidateStamp = PackageReleaseStamp(manifest: manifest)
        switch disposition {
        case .forward:
            if let highWater = state.highestAcceptedSignedRelease,
               !candidateStamp.isStrictlyNewer(than: highWater) {
                throw PackageManifestValidationError.nonMonotonicUpdate(
                    current: highWater,
                    candidate: candidateStamp
                )
            }
        case .explicitRollback:
            guard state.signedRollbackIdentities.contains(identity) else {
                let highWater = state.highestAcceptedSignedRelease ?? candidateStamp
                throw PackageManifestValidationError.nonMonotonicUpdate(
                    current: highWater,
                    candidate: candidateStamp
                )
            }
        }

        let replacementEngine = try LocalClassifierEngine(
            verifiedPackage: verifiedPackage,
            policies: engine.policies,
            // Direct-score distributions from an old package must never be
            // blended into a new package. The explicit backfill API rebuilds
            // these profiles from retained evidence when the user asks it to.
            sourceProfiles: [:],
            personalModel: engine.personalModel,
            sequence: engine.sequence,
            settings: engine.settings
        )
        var replacementState = state
        if let currentIdentity = replacementState.activeModelIdentity,
           currentIdentity.kind == .signedPackage {
            replacementState.rememberSignedIdentityForRollback(currentIdentity)
        }
        replacementState.resetDerivedModelState(for: identity)
        replacementState.cacheBackfill = .init(
            packageID: verifiedPackage.package.packageID,
            modelVersion: verifiedPackage.package.modelVersion,
            releaseSequence: manifest.releaseSequence,
            payloadSHA256: manifest.payloadSHA256
        )
        if disposition == .forward {
            replacementState.highestAcceptedSignedRelease = candidateStamp
        }
        replacementState.rememberSignedIdentityForRollback(identity)
        synchronize(workingEngine: replacementEngine, into: &replacementState)
        // The state file must win the publication race. A failed durable write
        // leaves the old engine/state pair visible to callers.
        try stateFile.save(replacementState)
        engine = replacementEngine
        activeVerifiedPackage = verifiedPackage
        activeVerifiedManifest = manifest
        state = replacementState
    }

    /// Explicitly re-evaluates a bounded cache batch after a successful
    /// verified-package activation. It never creates a decision-ledger row and
    /// never changes cache order, evidence, timestamps, or capacity.
    ///
    /// Stage one refreshes the newest rows first using direct evidence only and
    /// marks every result as provisional. Stage two then replays the retained
    /// FIFO order oldest-to-newest. Only stage two records source observations,
    /// and only after scoring each target, so an entry can never contribute to
    /// its own prior or leak backward into an older row.
    ///
    /// This method is synchronous and has no scheduler. A future
    /// user-controlled background mode can invoke it repeatedly while the
    /// returned report has `remainingEntries > 0`.
    public func backfillCachedEntries(
        _ request: CacheBackfillRequest,
        at date: Date = .now
    ) throws -> CacheBackfillReport {
        lock.lock()
        defer { lock.unlock() }

        guard (1...CacheBackfillRequest.maximumEntryLimit).contains(request.maximumEntries) else {
            throw CacheBackfillError.invalidMaximumEntries(request.maximumEntries)
        }

        guard var progress = state.cacheBackfill else {
            throw CacheBackfillError.noEligibleVerifiedPackage
        }
        guard let activeManifest = activeVerifiedManifest,
              progress.packageID == engine.package.packageID,
              progress.modelVersion == engine.package.modelVersion,
              progress.packageID == activeVerifiedPackage.package.packageID,
              progress.modelVersion == activeVerifiedPackage.package.modelVersion,
              progress.releaseSequence == activeManifest.releaseSequence,
              progress.payloadSHA256 == activeManifest.payloadSHA256 else {
            throw CacheBackfillError.packageMismatch
        }

        let staleEntriesBeforeBatch = state.cache.filter { !isCurrentCachedEntry($0) }.count
        let startedBackfill = !progress.isStarted
        var causalEngine = engine
        if startedBackfill {
            // Array order is the persisted FIFO order. It is also the stable
            // tiebreaker when several entries share the same wall-clock time.
            progress.start(withFIFOKeys: state.cache.map(\.key), at: date)
            causalEngine = try freshCausalReplayEngine()
        }

        var updatedCache = state.cache
        guard progressQueuesAreValid(progress, cacheKeys: updatedCache.map(\.key)) else {
            throw CacheBackfillError.invalidContinuation
        }
        var cacheIndexByKey: [String: Int] = [:]
        for (index, cached) in updatedCache.enumerated() {
            guard cacheIndexByKey[cached.key] == nil else {
                throw CacheBackfillError.invalidContinuation
            }
            cacheIndexByKey[cached.key] = index
        }
        var directRefreshedEntries = 0
        var causallyReplayedEntries = 0
        var skippedMissingEntries = 0

        switch progress.phase {
        case .directRefresh:
            // This engine is intentionally thrown away. It has no source
            // profile and records no observations, so newest-first work cannot
            // influence the later FIFO causal replay.
            var directEngine = try freshDirectOnlyEngine()
            let keys = Array(progress.directRefreshPendingCacheKeys.prefix(request.maximumEntries))
            for key in keys {
                guard let index = cacheIndexByKey[key] else {
                    skippedMissingEntries += 1
                    continue
                }
                // Work only on copies. Any validation/classification failure
                // leaves engine, state, cache, and ledger exactly as before.
                let refreshed = try directEngine.classify(
                    updatedCache[index].evidence,
                    recordSourceObservation: false
                )
                updatedCache[index].result = refreshed
                updatedCache[index].modelIdentity = state.activeModelIdentity
                updatedCache[index].replayState = .awaitingCausalReplay
                directRefreshedEntries += 1
            }
            progress.directRefreshPendingCacheKeys.removeFirst(keys.count)
            progress.directRefreshCompletedEntryCount += directRefreshedEntries
            if progress.directRefreshPendingCacheKeys.isEmpty {
                // Capture the current retained FIFO after direct work. Cache
                // mutation while active restarts the whole continuation, so
                // this remains a stable causal order for stage two.
                progress.beginCausalReplay(withFIFOKeys: updatedCache.map(\.key))
            }

        case .causalReplay:
            let keys = Array(progress.causalReplayPendingCacheKeys.prefix(request.maximumEntries))
            for key in keys {
                guard let index = cacheIndexByKey[key] else {
                    skippedMissingEntries += 1
                    continue
                }
                // The only source-observation path is FIFO. `classify` scores
                // before appending this row's direct signals, preserving the
                // no-self/no-future source-prior invariant.
                let reclassified = try causalEngine.classify(updatedCache[index].evidence)
                updatedCache[index].result = reclassified
                updatedCache[index].modelIdentity = state.activeModelIdentity
                updatedCache[index].replayState = .causallyReplayed
                causallyReplayedEntries += 1
            }
            progress.causalReplayPendingCacheKeys.removeFirst(keys.count)
            progress.causalReplayCompletedEntryCount += causallyReplayedEntries
        }

        var updatedState = state
        updatedState.cache = updatedCache
        if progress.phase == .causalReplay && progress.causalReplayPendingCacheKeys.isEmpty {
            updatedState.cacheBackfill = nil
        } else {
            updatedState.cacheBackfill = progress
        }
        synchronize(workingEngine: causalEngine, into: &updatedState)
        // Persist before publishing the updated engine/state pair. The cache
        // and source profiles therefore advance atomically at this boundary.
        try stateFile.save(updatedState)
        engine = causalEngine
        state = updatedState

        return .init(
            packageID: engine.package.packageID,
            modelVersion: engine.package.modelVersion,
            startedBackfill: startedBackfill,
            reclassifiedEntries: directRefreshedEntries + causallyReplayedEntries,
            skippedMissingEntries: skippedMissingEntries,
            remainingEntries: progress.remainingEntryCount(retainedCacheEntryCount: updatedCache.count),
            retainedCacheEntries: state.cache.count,
            staleEntriesBeforeBatch: staleEntriesBeforeBatch,
            isComplete: updatedState.cacheBackfill == nil,
            phase: progress.phase,
            directRefreshedEntries: directRefreshedEntries,
            causallyReplayedEntries: causallyReplayedEntries
        )
    }

    public func policies() -> [NamedPolicy] {
        lock.lock()
        defer { lock.unlock() }
        return engine.policies
    }

    public func snapshot() -> LocalClassifierState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    private func synchronizeEngineState() {
        synchronize(workingEngine: engine, into: &state)
    }

    private func synchronize(workingEngine: LocalClassifierEngine, into targetState: inout LocalClassifierState) {
        targetState.sequence = workingEngine.sequence
        targetState.policies = workingEngine.policies
        targetState.sourceProfiles = workingEngine.sourceProfiles
        targetState.personalModel = workingEngine.personalModel
        targetState.settings = workingEngine.settings
    }

    private func makeValidatedTrainingExample(
        evidence: EntryEvidence,
        positiveLeafTagIDs: [String],
        negativeLeafTagIDs: [String],
        origin: LocalTrainingLabelOrigin,
        at date: Date
    ) throws -> LocalTrainingExample {
        try EntryEvidenceValidator().validate(evidence)
        let positives = Array(Set(positiveLeafTagIDs)).sorted()
        let negatives = Array(Set(negativeLeafTagIDs)).sorted()
        guard !positives.isEmpty || !negatives.isEmpty else {
            throw LocalTrainingError.noLabels
        }
        guard Set(positives).isDisjoint(with: negatives) else {
            throw LocalTrainingError.overlappingLabels
        }
        for tagID in positives + negatives where !engine.taxonomy.predictableLeafIDs.contains(tagID) {
            throw LocalTrainingError.unknownLeafTag(tagID)
        }
        let timestamp = Self.milliseconds(date)
        return .init(
            cacheKey: LocalClassifierState.cacheKey(for: evidence),
            evidence: evidence,
            positiveLeafTagIDs: positives,
            negativeLeafTagIDs: negatives,
            origin: origin,
            taxonomyVersion: engine.package.taxonomyVersion,
            createdAtMilliseconds: timestamp,
            updatedAtMilliseconds: timestamp
        )
    }

    /// A backup failure must never roll back a successfully saved model rebuild
    /// or package activation. The UI still provides an explicit `backup now`
    /// action that surfaces any destination error to the owner.
    private func backupCurrentModelIfConfigured(state: LocalClassifierState, at date: Date) {
        guard let configuration = state.backupConfiguration, configuration.isEnabled,
              let directory = try? configuration.directoryURL() else { return }
        _ = try? LocalModelBackup().backup(
            state: state,
            package: activeVerifiedPackage,
            in: directory,
            at: date
        )
    }

    /// Creates the only engine allowed to rebuild source profiles. Its source
    /// state is always empty at the beginning of a two-stage continuation.
    private func freshCausalReplayEngine() throws -> LocalClassifierEngine {
        try LocalClassifierEngine(
            verifiedPackage: activeVerifiedPackage,
            policies: engine.policies,
            sourceProfiles: [:],
            personalModel: engine.personalModel,
            sequence: engine.sequence,
            settings: engine.settings
        )
    }

    /// A deliberately disposable classifier for provisional newest-first
    /// refreshes and foreground cache mutations while a backfill is active.
    /// It never changes the coordinator's sequence or source profile.
    private func freshDirectOnlyEngine() throws -> LocalClassifierEngine {
        try LocalClassifierEngine(
            verifiedPackage: activeVerifiedPackage,
            policies: engine.policies,
            sourceProfiles: [:],
            personalModel: engine.personalModel,
            sequence: engine.sequence,
            settings: engine.settings
        )
    }

    private func classifyDirectOnly(_ entry: EntryEvidence) throws -> ClassificationResult {
        var directEngine = try freshDirectOnlyEngine()
        return try directEngine.classify(entry, recordSourceObservation: false)
    }

    private func progressQueuesAreValid(
        _ progress: CacheBackfillProgress,
        cacheKeys: [String]
    ) -> Bool {
        Self.hasCanonicalBackfillQueues(progress, cacheKeys: cacheKeys)
    }

    /// A changed/evicted cache row can no longer be trusted as an already
    /// replayed source observation. Preserve cache order/evidence/timestamps
    /// and ledger history, discard only derived/provisional state, and require
    /// the next explicit call to restart both stages from the retained FIFO
    /// snapshot.
    private func restartBackfillAfterCacheMutation() {
        guard state.cacheBackfill != nil else { return }
        engine.sourceProfiles = [:]
        for index in state.cache.indices {
            state.cache[index].replayState = .awaitingCausalReplay
        }
        state.cacheBackfill?.restart()
    }

    private func isCurrentCachedEntry(_ cached: CachedEntry) -> Bool {
        guard let activeIdentity = state.activeModelIdentity else { return false }
        return cached.replayState == .causallyReplayed
            && cached.modelIdentity == activeIdentity
            && activeIdentity.matches(cached.result)
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded(.towardZero))
    }

    private static func isCurrentBackfill(
        _ progress: CacheBackfillProgress?,
        for identity: ActiveModelIdentity
    ) -> Bool {
        guard let progress else { return true }
        guard identity.kind == .signedPackage,
              let releaseSequence = identity.releaseSequence,
              let payloadSHA256 = identity.payloadSHA256 else {
            return false
        }
        return progress.packageID == identity.packageID
            && progress.modelVersion == identity.modelVersion
            && progress.releaseSequence == releaseSequence
            && progress.payloadSHA256 == payloadSHA256
    }

    private static func hasValidBackfillContinuation(
        _ progress: CacheBackfillProgress?,
        for identity: ActiveModelIdentity,
        cacheKeys: [String]
    ) -> Bool {
        guard let progress, isCurrentBackfill(progress, for: identity),
              hasCanonicalBackfillQueues(progress, cacheKeys: cacheKeys) else {
            return false
        }
        return true
    }

    /// A resumed queue must be an exact remaining suffix of the immutable
    /// retained FIFO snapshot. Duplicate-only validation is insufficient: a
    /// reordered causal queue could make newer evidence influence an older
    /// result. Every cache mutation restarts the continuation, so canonical
    /// suffix validation is both safe and deterministic.
    private static func hasCanonicalBackfillQueues(
        _ progress: CacheBackfillProgress,
        cacheKeys: [String]
    ) -> Bool {
        guard Set(cacheKeys).count == cacheKeys.count,
              progress.directRefreshCompletedEntryCount >= 0,
              progress.causalReplayCompletedEntryCount >= 0 else {
            return false
        }
        if !progress.isStarted {
            return progress.phase == .directRefresh
                && progress.directRefreshPendingCacheKeys.isEmpty
                && progress.causalReplayPendingCacheKeys.isEmpty
                && progress.directRefreshCompletedEntryCount == 0
                && progress.causalReplayCompletedEntryCount == 0
        }
        switch progress.phase {
        case .directRefresh:
            let pending = progress.directRefreshPendingCacheKeys
            let expected = Array(cacheKeys.reversed().suffix(pending.count))
            return pending.count <= cacheKeys.count
                && pending == expected
                && progress.directRefreshCompletedEntryCount == cacheKeys.count - pending.count
                && !pending.isEmpty
                && progress.causalReplayPendingCacheKeys.isEmpty
                && progress.causalReplayCompletedEntryCount == 0
        case .causalReplay:
            let pending = progress.causalReplayPendingCacheKeys
            let expected = Array(cacheKeys.suffix(pending.count))
            return pending.count <= cacheKeys.count
                && pending == expected
                && progress.directRefreshCompletedEntryCount == cacheKeys.count
                && progress.causalReplayCompletedEntryCount == cacheKeys.count - pending.count
                && progress.directRefreshPendingCacheKeys.isEmpty
                && !pending.isEmpty
        }
    }
}

private extension LocalClassifierState {
    mutating func trimRetainedData() {
        let cacheLimit = max(1, settings.cacheCapacity)
        if cache.count > cacheLimit { cache.removeFirst(cache.count - cacheLimit) }
        let ledgerLimit = max(cacheLimit, 1_000)
        if ledger.count > ledgerLimit { ledger.removeFirst(ledger.count - ledgerLimit) }
        trainingCorpus.trim(to: cacheLimit)
    }
}
