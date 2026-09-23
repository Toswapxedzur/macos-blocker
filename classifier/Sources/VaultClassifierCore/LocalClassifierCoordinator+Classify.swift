import Foundation

// The classify path: cached projections, currency checks, batch classification against the resolved per-type engine, creator-research accumulation and tag projections.
// Split out of LocalStore.swift (CLASSIFIER-INDEPENDENCE §7, Phase 5):
// same type, same behaviour.
extension LocalClassifierCoordinator {
    public func cachedVideoTags(platformID: String, entryID: String) -> VideoTagsProjection? {
        lock.lock()
        defer { lock.unlock() }
        let catalog = state.workspaceCatalog
        let localLLM = state.settings.localLLM
        let types = Self.orderedTypes(for: platformID, in: catalog)
        guard !types.isEmpty else { return nil }
        // Only serve a cached projection when every stored classification for this
        // entry is still current for the model its type is configured to use. A
        // stale row (produced by the stub or a previously-selected model) is not
        // served, so the request falls through to a fresh classifyVideo. Human
        // corrections are always authoritative and never treated as stale.
        var sawClassification = false
        for type in types {
            guard let classification = catalog.videoClassification(
                classifierTypeID: type.id, platformID: platformID, entryID: entryID
            ) else { continue }
            sawClassification = true
            guard Self.isClassificationCurrent(classification, forType: type, localLLMSettings: localLLM) else {
                return nil
            }
        }
        guard sawClassification else { return nil }
        return Self.videoTagsProjection(entryID: entryID, platformID: platformID, types: types, catalog: catalog)
    }

    /// Whether a stored classification may be served from cache without
    /// reclassifying. It is current when a human confirmed it, or when it was
    /// produced by the model the type is configured to use now. The engine
    /// stamps `modelVersion` as `"llamacpp/<file>"` and the pipeline appends
    /// `"+<promptVersion>"`, so a prefix match against the configured file is
    /// exact. When no real model is configured we cannot reclassify anyway, so
    /// whatever exists is served rather than churned.
    /// (Edge case: if a type's configured model file was deleted, the engine
    /// falls back to the default, so its stored token won't match the requested
    /// file and the entry will reclassify each time it is requested — a bounded,
    /// self-correcting cost of an already-degraded configuration.)
    static func isClassificationCurrent(
        _ classification: VideoClassification,
        forType type: ClassifierTypeAsset,
        localLLMSettings: LocalLLMSettings
    ) -> Bool {
        if classification.source == .humanCorrected { return true }
        guard let expectedFile = type.modelFileName ?? localLLMSettings.modelFileName,
              !expectedFile.isEmpty else { return true }
        let expected = "llamacpp/" + expectedFile
        return classification.modelVersion == expected
            || classification.modelVersion.hasPrefix(expected + "+")
    }

    /// Single-video convenience: a batch of one (one code path).
    public func classifyVideo(
        platformID: String,
        entryID: String,
        creatorID: String,
        title: String,
        summary: String? = nil,
        text: String? = nil
    ) async throws -> VideoTagsProjection {
        try await classifyVideos(platformID: platformID, items: [
            .init(title: title, summary: summary, text: text, entryID: entryID, creatorID: creatorID)
        ])[entryID] ?? VideoTagsProjection(tags: [], predicted: false)
    }

    /// Classifies a screenful of videos for one platform. Per classifier type, every
    /// not-yet-corrected video goes to the engine as ONE batch (a multi-sequence
    /// decode on engines that support it — LATENCY-REFINEMENT Phase 1); state is
    /// saved once, then research is scheduled per video. Keyed by entry id.
    public func classifyVideos(
        platformID: String,
        items: [VideoClassificationPipeline.Input]
    ) async throws -> [String: VideoTagsProjection] {
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
        guard !types.isEmpty, !items.isEmpty else {
            return Dictionary(items.map { ($0.entryID, VideoTagsProjection(tags: [], predicted: false)) }, uniquingKeysWith: { first, _ in first })
        }

        var classifications: [VideoClassification] = []
        var researchCandidates: [(
            type: ClassifierTypeAsset,
            classification: VideoClassification,
            settings: ResearchSettings,
            input: VideoClassificationPipeline.Input
        )] = []

        for type in types {
            guard let tree = catalog.trees.first(where: { $0.id == type.treeID }),
                  type.treeRevision == tree.revision else { continue }
            let overrides = type.localModelOverrides
            var pending: [VideoClassificationPipeline.Input] = []
            for item in items {
                // A correction is authoritative for this taxonomy revision. Live
                // requests and research-triggered refreshes must not overwrite it
                // with a later model decision.
                if let corrected = catalog.videoClassification(
                    classifierTypeID: type.id,
                    platformID: platformID,
                    entryID: item.entryID
                ), corrected.source == .humanCorrected,
                   corrected.treeID == tree.id,
                   corrected.treeRevision == tree.revision {
                    classifications.append(corrected)
                } else {
                    pending.append(.init(
                        title: item.title, summary: item.summary, text: item.text,
                        entryID: item.entryID, creatorID: item.creatorID))
                }
            }
            guard !pending.isEmpty else { continue }

            let knowledgeSettings = type.researchOverrides ?? globalResearchSettings
            let llm = await Self.resolvedLLM(
                for: type,
                defaultLLM: defaultLLM,
                resolver: engineResolver,
                configuration: localLLMSettings
            )
            // The max source here is the resolved global cap (classificationMaximumTags),
            // while the min global comes from the local-LLM settings — each per-type
            // overridable — so we resolve them together through the one `TagBounds`.
            let bounds = TagBounds(
                minimum: overrides?.minimumTags ?? localLLMSettings.minimumTags,
                maximum: overrides?.maximumTags ?? maximumTags)
            let pipeline = VideoClassificationPipeline(
                llm: llm, maximumTags: bounds.maximum, minimumTags: bounds.minimum)
            let typeHouseRules = Self.effectiveHouseRules(global: houseRules, perType: overrides?.houseRules)
            let results = try await pipeline.classifyBatch(
                pending,
                platformID: platformID,
                classifierType: type,
                tree: tree,
                catalog: catalog,
                houseRules: typeHouseRules,
                allowDecline: overrides?.allowDecline,
                confidenceThresholds: overrides?.confidenceThresholds,
                knowledgeTTLDays: knowledgeSettings.knowledgeTTLDays,
                maxKnowledgePerVideo: knowledgeSettings.maxKnowledgePerVideo
            )
            classifications.append(contentsOf: results)
            guard let effectiveResearch = Self.effectiveResearchSettings(
                global: globalResearchSettings,
                for: type
            ) else { continue }
            for (input, classification) in zip(pending, results) {
                researchCandidates.append((type, classification, effectiveResearch, input))
            }
        }

        let tPersist = DispatchTime.now()
        defer {
            if ProcessInfo.processInfo.environment["VAULT_DECODE_TIMING"] == "1" {
                FileHandle.standardError.write(Data(String(
                    format: "[classify-timing] videos=%d  persist+after=%.0fms\n", items.count,
                    Double(DispatchTime.now().uptimeNanoseconds - tPersist.uptimeNanoseconds) / 1_000_000).utf8))
            }
        }
        let (saved, authorTasks) = try lock.withLock { () -> (WorkspaceCatalog, [ResearchTask]) in
            for classification in classifications { state.workspaceCatalog.upsertVideoClassification(classification) }
            // Author accumulation (§8): every model classification adds its derived
            // urgency to the creator's windowed accumulator; a creator that is
            // consistently hard to classify crosses the threshold → an author task.
            var authorTasks: [ResearchTask] = []
            let nowMilliseconds = WorkspaceCatalog.now()
            for candidate in researchCandidates where candidate.classification.source == .model {
                guard let meanUrgency = state.workspaceCatalog.recordCreatorResearchUrgency(
                    classifierTypeID: candidate.type.id,
                    creatorID: candidate.input.creatorID,
                    urgency: Self.researchUrgency(for: candidate.classification),
                    threshold: candidate.settings.authorThreshold,
                    nowMilliseconds: nowMilliseconds
                ), let creatorSubject = ResearchSubject(kind: .creator, subject: candidate.input.creatorID) else { continue }
                authorTasks.append(.init(
                    classifierTypeID: candidate.type.id, platformID: platformID, entryID: candidate.input.entryID,
                    creatorID: candidate.input.creatorID, subjects: [creatorSubject], urgency: meanUrgency
                ))
            }
            try stateFile.save(state)
            return (state.workspaceCatalog, authorTasks)
        }

        var projections: [String: VideoTagsProjection] = [:]
        for item in items {
            projections[item.entryID] = Self.videoTagsProjection(
                entryID: item.entryID, platformID: platformID, types: types, catalog: saved)
        }
        VaultDevLog.shared.log("classify", "videos", [
            "platform": platformID,
            "videos": "\(items.count)",
            "types": "\(types.count)",
            "classified": "\(classifications.count)",
            "tagged": "\(projections.values.filter { !$0.tags.isEmpty }.count)"
        ])
        if let researchQueue {
            // The §8 accumulator is the ONLY automatic research trigger: a creator
            // seen often enough whose videos stay hard to classify. Terms are never
            // picked automatically (the model picked ordinary words, and low
            // confidence marks vague titles, not unknown names) — the user adds them.
            for task in authorTasks { _ = await researchQueue.enqueue(task) }
        }
        return projections
    }

    static func resolvedLLM(
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

    static func effectiveHouseRules(global: String?, perType: String?) -> String? {
        // A type's own house rules REPLACE the global rules (intentional override).
        // Both are the user's own text; corrections never reach the model as text.
        let trimmedPerType = perType?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedPerType, !trimmedPerType.isEmpty { return trimmedPerType }
        let trimmedGlobal = global?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmedGlobal?.isEmpty == false) ? trimmedGlobal : nil
    }

    /// The derived research urgency for a model classification (inverse of its
    /// mean confidence; a decline = 5): the per-video sample the creator
    /// accumulator averages.
    public static func researchUrgency(for classification: VideoClassification) -> Int {
        ResearchUrgency.fromTagConfidences(classification.tags.map(\.confidence))
    }

    static func orderedTypes(for platformID: String, in catalog: WorkspaceCatalog) -> [ClassifierTypeAsset] {
        catalog.classifierTypes
            .filter { $0.applicablePlatformID == platformID }
            .sorted { ($0.order, $0.id) < ($1.order, $1.id) }
    }

    static func videoTagsProjection(
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
}
