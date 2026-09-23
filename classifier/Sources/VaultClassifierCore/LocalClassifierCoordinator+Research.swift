import Foundation

// The research lane's store side: queue wiring and snapshot, user-chosen term lookup, attempt/knowledge/mutation recording.
// Split out of LocalStore.swift (CLASSIFIER-INDEPENDENCE §7, Phase 5):
// same type, same behaviour.
extension LocalClassifierCoordinator {
    public func setGroundedResearchQueue(_ queue: GroundedResearchQueue?) {
        lock.withLock { groundedResearchQueue = queue }
    }

    public func groundedResearchQueueSnapshot(for task: ResearchTask) -> GroundedResearchQueueSnapshot {
        lock.withLock {
            let settings = state.settings.research
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

    /// Looks up a term the USER chose (Knowledge → add term) through the same
    /// grounded research lane a creator uses; the result lands in
    /// `recordResearchKnowledge`, which re-classifies the weakly tagged videos whose
    /// title holds the term. Terms are never picked automatically. Returns false
    /// when research is off / unconfigured, the subject is not a usable term, or
    /// it is already queued.
    @discardableResult
    public func researchTerm(_ rawSubject: String) async -> Bool {
        let subject = rawSubject.trimmingCharacters(in: .whitespacesAndNewlines)
        guard KnowledgeEntry.isSpecificTermSubject(subject),
              let researchSubject = ResearchSubject(kind: .term, subject: subject) else { return false }
        let target: (queue: GroundedResearchQueue, type: ClassifierTypeAsset)? = lock.withLock {
            guard let queue = groundedResearchQueue,
                  let type = state.workspaceCatalog.classifierTypes.first(where: {
                      Self.effectiveResearchSettings(global: state.settings.research, for: $0) != nil
                  }) else { return nil }
            return (queue, type)
        }
        guard let target else { return false }
        return await target.queue.enqueue(.init(
            classifierTypeID: target.type.id,
            platformID: target.type.applicablePlatformID ?? "",
            entryID: "",
            creatorID: "",
            subjects: [researchSubject],
            urgency: 5
        ))
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

        // Re-classify the affected videos in ONE multi-sequence engine pass per
        // platform (they are a known set), not one lone prefill each: a single
        // video costs about as much as a full batch, so the loop this replaces
        // paid the unbatchable prompt prefill `affected.count` times.
        let byPlatform = Dictionary(grouping: affected, by: \.platformID)
        var seenPlatforms = Set<String>()
        let platformOrder = affected.map(\.platformID).filter { seenPlatforms.insert($0).inserted }
        for platformID in platformOrder {
            guard let group = byPlatform[platformID] else { continue }
            for start in stride(from: 0, to: group.count, by: Self.reclassificationChunkSize) {
                let chunk = Array(group[start..<min(start + Self.reclassificationChunkSize, group.count)])
                let projections: [String: VideoTagsProjection] = try await Task.detached(priority: .utility) { [self] in
                    let inputs = chunk.map {
                        VideoClassificationPipeline.Input(
                            title: $0.title, summary: $0.summary, text: $0.text,
                            entryID: $0.entryID, creatorID: $0.creatorID)
                    }
                    var projections = (try? await classifyVideos(platformID: platformID, items: inputs)) ?? [:]
                    if projections.isEmpty {
                        // The batch failed as a whole — fall back to one video at a
                        // time so a single bad item cannot sink the rest.
                        for collected in chunk {
                            if let single = try? await classifyVideo(
                                platformID: platformID, entryID: collected.entryID, creatorID: collected.creatorID,
                                title: collected.title, summary: collected.summary, text: collected.text) {
                                projections[collected.entryID] = single
                            }
                        }
                    }
                    return projections
                }.value
                let callback = lock.withLock { onVideoReclassifiedCallback }
                for collected in chunk {
                    guard let projection = projections[collected.entryID] else { continue }
                    callback?(platformID, collected.entryID, projection)
                }
            }
        }
    }

    /// Videos handed to the engine together when research re-classifies — its
    /// parallel-sequence capacity. Must track `VaultLocalLLMEngine
    /// .maximumParallelSequences` (and the live pill path's chunk size); it is
    /// a literal here because Core deliberately cannot import the LLM layer.
    static let reclassificationChunkSize = 16

    static func pruneTokenUsage(_ records: inout [TokenUsageRecord]) {
        let todayStart = Int64(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 * 1_000)
        let required = Set(records.filter {
            $0.status == GroundedResearchQueue.researchUsageStatus &&
                $0.createdAtMilliseconds >= todayStart
        }.map(\.id))
        records = Array(records.enumerated().filter { offset, record in
            offset < 200 || required.contains(record.id)
        }.map(\.element).prefix(2_000))
    }
}
