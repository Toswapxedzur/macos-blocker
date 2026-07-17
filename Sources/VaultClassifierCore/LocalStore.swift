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
    /// be selected for or dispatched to a personal audit.
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
        // legacy results out of personal-audit paths.
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

    public var auditGrade: PolicyAuditGrade {
        if evidenceState != .sufficient { return .insufficientEvidence }
        switch correction {
        case .falseAllow: return .falseAllow
        case .falseDim, .falseBlock: return .falseDimOrBlock
        case nil: return actions.values.max() == nil || actions.values.max() == .allow ? .correctAllow : .correctDimOrBlock
        }
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
    public var nativeReplayWindow: NativeReplayWindow
    public var auditState: LocalAuditState
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

    public init(schemaVersion: Int = 1, sequence: Int64 = 0, settings: ClassifierSettings = .init(), policies: [NamedPolicy] = [], sourceProfiles: [String: SourceProfile] = [:], personalModel: PersonalFTRLModel = .init(), trainingCorpus: LocalTrainingCorpus = .init(), workspaceCatalog: WorkspaceCatalog = .starter(), backupConfiguration: LocalBackupConfiguration? = nil, nativeReplayWindow: NativeReplayWindow = .init(), auditState: LocalAuditState = .init(), cacheBackfill: CacheBackfillProgress? = nil, activeModelIdentity: ActiveModelIdentity? = nil, highestAcceptedSignedRelease: PackageReleaseStamp? = nil, signedRollbackIdentities: [ActiveModelIdentity] = [], cache: [CachedEntry] = [], ledger: [DecisionLedgerEntry] = []) {
        self.schemaVersion = schemaVersion
        self.sequence = sequence
        self.settings = settings
        self.policies = policies
        self.sourceProfiles = sourceProfiles
        self.personalModel = personalModel
        self.trainingCorpus = trainingCorpus
        self.workspaceCatalog = workspaceCatalog
        self.backupConfiguration = backupConfiguration
        self.nativeReplayWindow = nativeReplayWindow
        self.auditState = auditState
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
        case schemaVersion, sequence, settings, policies, sourceProfiles, personalModel, trainingCorpus, workspaceCatalog, backupConfiguration, nativeReplayWindow, auditState, cacheBackfill, activeModelIdentity, highestAcceptedSignedRelease, signedRollbackIdentities, cache, ledger
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        sequence = try container.decodeIfPresent(Int64.self, forKey: .sequence) ?? 0
        settings = try container.decodeIfPresent(ClassifierSettings.self, forKey: .settings) ?? .init()
        policies = try container.decodeIfPresent([NamedPolicy].self, forKey: .policies) ?? []
        sourceProfiles = try container.decodeIfPresent([String: SourceProfile].self, forKey: .sourceProfiles) ?? [:]
        personalModel = try container.decodeIfPresent(PersonalFTRLModel.self, forKey: .personalModel) ?? .init()
        trainingCorpus = try container.decodeIfPresent(LocalTrainingCorpus.self, forKey: .trainingCorpus) ?? .init()
        workspaceCatalog = try container.decodeIfPresent(WorkspaceCatalog.self, forKey: .workspaceCatalog) ?? .starter()
        backupConfiguration = try container.decodeIfPresent(LocalBackupConfiguration.self, forKey: .backupConfiguration)
        nativeReplayWindow = try container.decodeIfPresent(NativeReplayWindow.self, forKey: .nativeReplayWindow) ?? .init()
        auditState = try container.decodeIfPresent(LocalAuditState.self, forKey: .auditState) ?? .init()
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
    }

    public static func cacheKey(for entry: EntryEvidence) -> String {
        if let entryID = entry.entryID, !entryID.isEmpty { return "\(entry.platform):\(entryID)" }
        let encoded = (try? JSONEncoder().encode(entry)) ?? Data(entry.requestID.utf8)
        let digest = SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
        return "\(entry.platform):\(digest)"
    }

    /// Applies a model-bound invalidation while retaining raw cache evidence,
    /// decision history, user corrections, and conservative audit accounting.
    /// Cached rows are deliberately not rewritten: their old identity keeps
    /// them visibly stale until an explicit backfill replaces their result.
    public mutating func resetDerivedModelState(for identity: ActiveModelIdentity) {
        activeModelIdentity = identity
        sourceProfiles = [:]
        cacheBackfill = nil
        for index in cache.indices {
            cache[index].replayState = .awaitingCausalReplay
        }
        auditState.invalidatePackageBoundRecords(except: identity)
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

public final class LocalStateFile {
    public let url: URL

    public init(url: URL) { self.url = url }

    public func load(or defaultState: LocalClassifierState = .init()) throws -> LocalClassifierState {
        guard FileManager.default.fileExists(atPath: url.path) else { return defaultState }
        return try JSONDecoder().decode(LocalClassifierState.self, from: Data(contentsOf: url))
    }

    public func save(_ state: LocalClassifierState) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
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
            // Remove only stale legacy audit data without needlessly changing
            // a compatible source prior/cache.
            loaded.auditState.invalidatePackageBoundRecords(except: identity)
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
        let requiresCausalReplay = state.cacheBackfill != nil
        let result: ClassificationResult
        if requiresCausalReplay {
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
        guard let ledgerID = state.ledger.last?.id else { throw LocalIPCError.malformedFrame }
        return (result, ledgerID)
    }

    public func setCorrection(ledgerID: UUID, correction: UserCorrection?) throws {
        lock.lock()
        defer { lock.unlock() }
        state.setCorrection(ledgerID: ledgerID, correction: correction)
        try stateFile.save(state)
    }

    public func verifyAndRecordNativeEnvelope(_ envelope: NativeEnvelope) throws {
        lock.lock()
        defer { lock.unlock() }
        let secret = try DevicePairingSecretStore.ensure()
        try state.nativeReplayWindow.verifyAndRecord(envelope, secret: secret)
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
        try catalog.validate()
        state.workspaceCatalog = catalog
        try stateFile.save(state)
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

    /// A nil configuration means audits are off. Provider credentials remain
    /// outside this state file and outside the extension/native-host boundary.
    public func updateAuditConfiguration(_ configuration: LocalAuditConfiguration?) throws {
        lock.lock()
        defer { lock.unlock() }
        // A disabled configuration is a valid persisted preference. Only an
        // actual dispatch uses `validateForSubmission`, which additionally
        // requires `isEnabled`.
        if let configuration {
            try configuration.provider.validate()
            try configuration.budgetLimits.validate()
        }
        state.auditState.configuration = configuration
        state.auditState.trim()
        try stateFile.save(state)
    }

    public func enqueueUserMarkedAudit(ledgerID: UUID, at date: Date = .now) throws -> AuditedEntry {
        lock.lock()
        defer { lock.unlock() }
        guard let ledger = state.ledger.first(where: { $0.id == ledgerID }),
              let cached = state.cache.first(where: { $0.key == ledger.cacheKey }) else {
            throw LocalAuditStoreError.auditNotFound
        }
        guard isCurrentCachedEntry(cached),
              ledger.packageID == cached.result.packageID,
              ledger.modelVersion == cached.result.modelVersion else {
            throw LocalAuditStoreError.staleModelIdentity
        }
        let candidate = try makeAuditCandidate(
            cached: cached,
            intent: .userMarkedDecisionReview,
            factors: [.init(kind: .userMarked, severity: 1)],
            origin: .userSupplied,
            at: date
        )
        state.auditState.upsertCandidate(candidate)
        try stateFile.save(state)
        return candidate
    }

    /// Selects allowed entries using transparent local signals, never provider
    /// confidence, clicks, or watch time. Selection does not send any data.
    @discardableResult
    public func enqueueSuggestedFalseAllowAudits(limit: Int, at date: Date = .now) throws -> [AuditedEntry] {
        lock.lock()
        defer { lock.unlock() }
        guard limit > 0 else { return [] }
        guard state.settings.allowLocalLLMAudit else { return [] }
        guard let configuration = state.auditState.configuration,
              configuration.isEnabled,
              configuration.selectionMode != .userMarkedOnly else {
            return []
        }
        let existing = Set(state.auditState.candidates.map { "\($0.intent.rawValue):\($0.evidence.evidenceDigest):\($0.localResult.modelVersion)" })
        var targeted: [AuditedEntry] = []
        var randomEligible: [(candidate: AuditedEntry, rank: UInt64)] = []
        for cached in state.cache where isCurrentCachedEntry(cached)
            && cached.result.strongestAction == .allow
            && cached.result.evidenceState == .sufficient {
            guard let context = try? auditPolicyContext(for: cached.evidence) else { continue }
            let digest = try UntrustedQuotedEvidence.digest(for: cached.evidence)
            let identity = "\(AuditIntent.potentialFalseAllow.rawValue):\(digest):\(cached.result.modelVersion)"
            guard !existing.contains(identity) else { continue }
            let targetedFactors = Self.falseAllowRiskFactors(for: cached.result, menuLeafTagIDs: context.menuLeafTagIDs)
            if !targetedFactors.isEmpty,
               let candidate = try? makeAuditCandidate(
                    cached: cached,
                    intent: .potentialFalseAllow,
                    factors: targetedFactors,
                    origin: .importedLocalRecord,
                    at: date
               ), candidate.eligibility.isEligible {
                targeted.append(candidate)
            }
            if configuration.selectionMode == .targetedWithRandomSample,
               let candidate = try? makeAuditCandidate(
                    cached: cached,
                    intent: .potentialFalseAllow,
                    factors: [.init(kind: .randomSample, severity: 0.01)],
                    origin: .importedLocalRecord,
                    at: date
               ), candidate.eligibility.isEligible {
                randomEligible.append((candidate, Self.deterministicAuditRank(
                    evidenceDigest: digest,
                    modelVersion: cached.result.modelVersion,
                    context: context
                )))
            }
        }

        let randomQuota = configuration.selectionMode == .targetedWithRandomSample
            ? Self.randomSampleQuota(for: limit)
            : 0
        let targetedLimit = max(0, limit - randomQuota)
        let selectedTargeted = targeted.sorted {
            $0.risk.priority == $1.risk.priority
                ? $0.evidence.evidenceDigest < $1.evidence.evidenceDigest
                : $0.risk.priority > $1.risk.priority
        }.prefix(targetedLimit)
        let selectedTargetedIdentities = Set(selectedTargeted.map { $0.evidence.evidenceDigest })
        let selectedRandom = randomEligible
            .filter { !selectedTargetedIdentities.contains($0.candidate.evidence.evidenceDigest) }
            .sorted { lhs, rhs in
                lhs.rank == rhs.rank
                    ? lhs.candidate.evidence.evidenceDigest < rhs.candidate.evidence.evidenceDigest
                    : lhs.rank < rhs.rank
            }
            .prefix(randomQuota)
            .map(\.candidate)
        let selected = Array(selectedTargeted) + selectedRandom
        for candidate in selected { state.auditState.upsertCandidate(candidate) }
        if !selected.isEmpty { try stateFile.save(state) }
        return selected
    }

    /// Reserves a conservative local budget before a future fixed provider
    /// adapter is allowed to make a request. It is not a claimed hard cap on
    /// provider reasoning tokens. Call `markAuditRequestPossiblySent` before
    /// dispatch; only a reservation that has not been sent can be cancelled
    /// and released.
    public func prepareAuditRequest(
        auditID: UUID,
        usageCeiling: AuditUsage,
        at date: Date = .now
    ) throws -> (request: LocalAuditRequest, reservation: AuditBudgetReservation) {
        lock.lock()
        defer { lock.unlock() }
        guard state.settings.allowLocalLLMAudit else {
            throw LocalAuditStoreError.localAuditDisabledByResourceSettings
        }
        guard let configuration = state.auditState.configuration else {
            throw LocalAuditStoreError.configurationMissing
        }
        guard let candidate = state.auditState.candidates.first(where: { $0.auditID == auditID }) else {
            throw LocalAuditStoreError.auditNotFound
        }
        guard isCurrentAuditCandidate(candidate) else {
            throw LocalAuditStoreError.staleModelIdentity
        }
        guard configuration.isEnabled else { throw LocalAuditStoreError.configurationMissing }
        let context: AuditPolicyContext
        do {
            context = try auditPolicyContext(for: candidate.evidence.quotedEntry)
        } catch {
            throw LocalAuditStoreError.policyContextUnavailable
        }
        let candidateRecords = state.auditState.budgetLedger.records.filter { $0.candidateAuditID == candidate.auditID }
        guard !candidateRecords.contains(where: { [.reserved, .possiblySent].contains($0.state) }) else {
            throw LocalAuditStoreError.attemptAlreadyInFlight
        }
        // Preserve the old stable first-attempt ID for adapter compatibility;
        // every subsequent retry receives a distinct attempt identifier.
        let attemptID = candidateRecords.isEmpty ? candidate.auditID : UUID()
        let timestamp = Self.milliseconds(date)
        let request = try LocalAuditRequest(
            candidate: candidate,
            policyContext: context,
            configuration: configuration,
            usageCeiling: usageCeiling,
            requestedAtMilliseconds: timestamp,
            attemptID: attemptID
        )
        let reservation = try state.auditState.budgetLedger.reserve(
            auditID: request.attemptID,
            candidateAuditID: request.auditID,
            usageCeiling: usageCeiling,
            limits: configuration.budgetLimits,
            at: timestamp
        )
        try stateFile.save(state)
        return (request, reservation)
    }

    /// Validates a provider response against the exact locally reserved request
    /// and records it locally. It never trains a personal model automatically:
    /// a person must later call `applyConfirmedFalseAllowAudit` for a currently
    /// policy-changing false allow.
    public func settleAuditResult(
        _ unvalidated: UnvalidatedAuditResult,
        for request: LocalAuditRequest,
        reservationID: UUID
    ) throws -> ValidatedAuditResult {
        lock.lock()
        defer { lock.unlock() }
        guard state.auditState.candidates.contains(where: { $0.auditID == request.auditID && $0 == request.candidate }),
              isCurrentAuditCandidate(request.candidate),
              let reservation = state.auditState.budgetLedger.records.first(where: { $0.id == reservationID }),
              reservation.auditID == request.attemptID,
              reservation.candidateAuditID == request.auditID,
              [.reserved, .possiblySent, .uncertain].contains(reservation.state) else {
            throw LocalAuditStoreError.reservationMismatch
        }
        let currentContext: AuditPolicyContext
        do {
            currentContext = try auditPolicyContext(for: request.candidate.evidence.quotedEntry)
        } catch {
            throw LocalAuditStoreError.policyContextUnavailable
        }
        guard request.policyContext == currentContext else {
            throw LocalAuditStoreError.policyContextMismatch
        }
        var validated = try AuditResultValidator().validate(
            unvalidated,
            for: request,
            allowedLeafTagIDs: currentContext.menuLeafTagIDs
        )
        if validated.finding == .potentialFalseAllow,
           policyChangingDecisions(for: validated.leafTagIDs, candidate: request.candidate, context: currentContext).isEmpty {
            throw LocalAuditStoreError.auditFindingNotApplicable
        }
        validated.modelIdentity = state.activeModelIdentity
        try state.auditState.budgetLedger.settle(reservationID: reservationID, actualUsage: validated.usage)
        state.auditState.upsertResult(validated)
        try stateFile.save(state)
        return validated
    }

    /// Call immediately before entering a provider transport. Once marked, a
    /// timeout/cancellation cannot turn into a free retry because a provider
    /// may already have billed the request.
    public func markAuditRequestPossiblySent(_ reservationID: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        guard state.settings.allowLocalLLMAudit else {
            throw LocalAuditStoreError.localAuditDisabledByResourceSettings
        }
        guard let reservation = state.auditState.budgetLedger.records.first(where: { $0.id == reservationID }),
              let candidate = state.auditState.candidates.first(where: { $0.auditID == reservation.candidateAuditID }),
              isCurrentAuditCandidate(candidate) else {
            throw LocalAuditStoreError.staleModelIdentity
        }
        try state.auditState.budgetLedger.markPossiblySent(reservationID: reservationID)
        try stateFile.save(state)
    }

    /// Preserve the reservation after a potentially dispatched request fails
    /// without a trustworthy result. A later retry gets a distinct attempt ID;
    /// a late attributable response may still settle this reservation.
    public func markAuditRequestUncertain(_ reservationID: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        try state.auditState.budgetLedger.markUncertain(reservationID: reservationID)
        try stateFile.save(state)
    }

    public func cancelAuditReservation(_ reservationID: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        try state.auditState.budgetLedger.cancel(reservationID: reservationID)
        try stateFile.save(state)
    }

    /// Applies a model update only after a local person explicitly confirms a
    /// stored validated audit. The finding is re-evaluated against the current
    /// active policy/taxonomy, so an old provider suggestion cannot train a
    /// tag that no longer changes the selected policy.
    public func applyConfirmedFalseAllowAudit(
        auditID: UUID,
        policyID: String,
        at date: Date = .now
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard state.auditState.configuration?.localLearningMode == .localValidatedOnly else {
            throw LocalAuditStoreError.localLearningDisabled
        }
        guard let result = state.auditState.results.first(where: { $0.auditID == auditID }),
              result.finding == .potentialFalseAllow,
              let candidate = state.auditState.candidates.first(where: { $0.auditID == auditID }) else {
            throw LocalAuditStoreError.auditFindingNotApplicable
        }
        guard isCurrentAuditCandidate(candidate),
              result.modelIdentity == state.activeModelIdentity else {
            throw LocalAuditStoreError.staleModelIdentity
        }
        guard !state.auditState.learningApplications.contains(where: { $0.auditID == auditID }) else {
            throw LocalAuditStoreError.auditAlreadyApplied
        }
        let context: AuditPolicyContext
        do {
            context = try auditPolicyContext(for: candidate.evidence.quotedEntry)
        } catch {
            throw LocalAuditStoreError.policyContextUnavailable
        }
        guard let decision = policyChangingDecisions(for: result.leafTagIDs, candidate: candidate, context: context)
            .first(where: { $0.policyID == policyID }) else {
            throw LocalAuditStoreError.auditFindingNotApplicable
        }
        let applicableLeaves = decision.matchedTagIDs.filter { result.leafTagIDs.contains($0) }
        guard !applicableLeaves.isEmpty else { throw LocalAuditStoreError.auditFindingNotApplicable }
        let trainingExample = try makeValidatedTrainingExample(
            evidence: candidate.evidence.quotedEntry,
            positiveLeafTagIDs: applicableLeaves,
            negativeLeafTagIDs: [],
            origin: .confirmedPersonalAudit,
            at: date
        )
        var replacementState = state
        replacementState.trainingCorpus.upsert(trainingExample, limit: replacementState.settings.cacheCapacity)
        var replacementEngine = engine
        let report = try replacementEngine.rebuildPersonalModel(
            from: replacementState.trainingCorpus.examples,
            epochs: 3
        )
        replacementState.trainingCorpus.lastRun = .init(
            exampleCount: report.exampleCount,
            labelUpdateCount: report.labelUpdateCount,
            epochs: 3,
            taxonomyVersion: replacementEngine.package.taxonomyVersion,
            completedAtMilliseconds: Self.milliseconds(date)
        )
        replacementState.auditState.recordLearningApplication(.init(
            auditID: auditID,
            policyID: policyID,
            leafTagIDs: applicableLeaves,
            appliedAtMilliseconds: Self.milliseconds(date)
        ))
        if replacementState.cacheBackfill != nil {
            // A pending cache continuation must be recomputed from the new
            // correction model rather than mixing direct scores from before
            // this confirmed label was added.
            replacementEngine.sourceProfiles = [:]
            for index in replacementState.cache.indices {
                replacementState.cache[index].replayState = .awaitingCausalReplay
            }
            replacementState.cacheBackfill?.restart()
        }
        synchronize(workingEngine: replacementEngine, into: &replacementState)
        try stateFile.save(replacementState)
        engine = replacementEngine
        state = replacementState
        backupCurrentModelIfConfigured(state: replacementState, at: date)
    }

    public func redactedAuditDiagnostics(at date: Date = .now) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        let export = state.auditState.redactedExport(generatedAtMilliseconds: Self.milliseconds(date))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(export)
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

    private func makeAuditCandidate(
        cached: CachedEntry,
        intent: AuditIntent,
        factors: [AuditRiskFactor],
        origin: AuditEvidenceOrigin,
        at date: Date
    ) throws -> AuditedEntry {
        guard let modelIdentity = state.activeModelIdentity,
              isCurrentCachedEntry(cached) else {
            throw LocalAuditStoreError.staleModelIdentity
        }
        let timestamp = Self.milliseconds(date)
        let evidence = try UntrustedQuotedEvidence(
            origin: origin,
            capturedAtMilliseconds: timestamp,
            quotedEntry: cached.evidence
        )
        let risk = try AuditRiskRecord(factors: factors, assessedAtMilliseconds: timestamp)
        let candidate = try AuditedEntry(
            evidence: evidence,
            localResult: cached.result,
            modelIdentity: modelIdentity,
            intent: intent,
            risk: risk,
            createdAtMilliseconds: timestamp
        )
        guard candidate.eligibility.isEligible else { throw LocalAuditStoreError.auditNotFound }
        return candidate
    }

    private func isCurrentCachedEntry(_ cached: CachedEntry) -> Bool {
        guard let activeIdentity = state.activeModelIdentity else { return false }
        return cached.replayState == .causallyReplayed
            && cached.modelIdentity == activeIdentity
            && activeIdentity.matches(cached.result)
    }

    /// Recheck both the identity and the exact retained cache snapshot before
    /// a queued audit can be sent, settled, or used for local polishing. This
    /// prevents an old cache row from crossing a package replacement boundary.
    private func isCurrentAuditCandidate(_ candidate: AuditedEntry) -> Bool {
        guard let activeIdentity = state.activeModelIdentity,
              candidate.modelIdentity == activeIdentity,
              activeIdentity.matches(candidate.localResult) else {
            return false
        }
        let cacheKey = LocalClassifierState.cacheKey(for: candidate.evidence.quotedEntry)
        return state.cache.contains { cached in
            cached.key == cacheKey
                && isCurrentCachedEntry(cached)
                && cached.evidence == candidate.evidence.quotedEntry
                && cached.result == candidate.localResult
        }
    }

    /// Build the only taxonomy/policy data that may leave the local app with an
    /// audit request. It is deliberately rebuilt from active state rather than
    /// trusting browser-provided policy IDs or a stale queued candidate.
    private func auditPolicyContext(for entry: EntryEvidence) throws -> AuditPolicyContext {
        let requested: [NamedPolicy]
        if entry.policyIDs.isEmpty {
            requested = engine.policies
        } else {
            let requestedIDs = Set(entry.policyIDs)
            requested = engine.policies.filter { requestedIDs.contains($0.id) }
        }
        let orderedPolicies = requested.sorted { $0.id < $1.id }
        guard !orderedPolicies.isEmpty else { throw LocalAuditStoreError.policyContextUnavailable }
        try PolicyCatalog(taxonomy: engine.taxonomy).validate(orderedPolicies)

        let policies = orderedPolicies.map { policy in
            AuditPolicyContextPolicy(
                policyID: policy.id,
                includeAnyTagIDs: policy.includeAnyTagIDs.sorted(),
                includeAllTagIDs: policy.includeAllTagIDs.sorted(),
                excludeTagIDs: policy.excludeTagIDs.sorted(),
                action: entry.surface == .feed ? policy.feedAction : policy.pageAction
            )
        }
        let criterionIDs = Set(policies.flatMap(\.criterionTagIDs))
        let leafIDs = engine.taxonomy.predictableLeafIDs
            .filter { leafID in criterionIDs.contains { engine.taxonomy.isDescendant(leafID, of: $0) } }
            .sorted()
        let leaves = leafIDs.compactMap { leafID -> AuditPolicyContextLeaf? in
            guard let node = engine.taxonomy.nodes[leafID] else { return nil }
            return .init(tagID: node.id, name: node.name)
        }
        return try .init(
            requestedPolicyIDs: policies.map(\.policyID),
            policies: policies,
            leafLabels: leaves
        )
    }

    /// Re-evaluate provider-selected leaves as if they were the local result.
    /// Returning only dim/block decisions makes a false allow policy-changing
    /// rather than merely a plausible tag suggestion.
    private func policyChangingDecisions(
        for leafTagIDs: [String],
        candidate: AuditedEntry,
        context: AuditPolicyContext
    ) -> [PolicyDecision] {
        guard Set(leafTagIDs).isSubset(of: context.menuLeafTagIDs) else { return [] }
        var reviewed = candidate.localResult
        reviewed.selectedLeafTagIDs = leafTagIDs.sorted()
        reviewed.ancestorTagIDs = engine.taxonomy.ancestorClosure(for: reviewed.selectedLeafTagIDs)
        reviewed.decisions = []
        return PolicyEvaluator(taxonomy: engine.taxonomy)
            .evaluate(result: reviewed, policies: engine.policies, requestedPolicyIDs: context.requestedPolicyIDs)
            .filter { $0.action > .allow }
    }

    /// Targeted candidates must be close to, or disagree about, a leaf that
    /// could actually change an active requested policy. This avoids auditing
    /// every otherwise allowed entry merely because some unrelated taxonomy
    /// score exists.
    private static func falseAllowRiskFactors(
        for result: ClassificationResult,
        menuLeafTagIDs: Set<String>
    ) -> [AuditRiskFactor] {
        let policyScores = result.scores.filter { menuLeafTagIDs.contains($0.tagID) }
        guard !policyScores.isEmpty else { return [] }
        let nearestMargin = policyScores.map { abs($0.finalScore - result.threshold) }.min() ?? 1
        var factors: [AuditRiskFactor] = []
        if nearestMargin < 0.15 {
            let marginSeverity = min(1, max(0.01, (0.15 - nearestMargin) / 0.15))
            factors.append(.init(kind: .nearPolicyMargin, severity: marginSeverity, measuredValue: nearestMargin))
        }
        if let largestDisagreement = policyScores.compactMap({ score -> Double? in
            guard let source = score.sourceScore else { return nil }
            return abs(score.directScore - source)
        }).max(), largestDisagreement >= 0.20 {
            factors.append(.init(kind: .sourceDirectDisagreement, severity: min(1, largestDisagreement), measuredValue: largestDisagreement))
        }
        return factors
    }

    private static func randomSampleQuota(for limit: Int) -> Int {
        // Keep targeted candidates dominant. Tiny manually requested batches
        // stay entirely targeted; larger runs receive a deterministic 20%
        // sample capped at eight entries.
        guard limit >= 5 else { return 0 }
        return min(8, max(1, limit / 5))
    }

    private static func deterministicAuditRank(
        evidenceDigest: String,
        modelVersion: String,
        context: AuditPolicyContext
    ) -> UInt64 {
        let material = [
            "vault-classifier-audit-random-v1",
            evidenceDigest,
            modelVersion,
            context.requestedPolicyIDs.joined(separator: ","),
            context.leafLabels.map(\.tagID).joined(separator: ","),
        ].joined(separator: "|")
        return SHA256.hash(data: Data(material.utf8)).prefix(8).reduce(UInt64(0)) { partial, byte in
            (partial << 8) | UInt64(byte)
        }
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
