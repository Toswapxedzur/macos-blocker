import Foundation

// The classify path: cached projections, currency checks, batch classification against the resolved per-type engine, creator-research accumulation and tag projections.
// Split out of LocalStore.swift (CLASSIFIER-INDEPENDENCE §7, Phase 5):
// same type, same behaviour.
extension LocalClassifierCoordinator {
    public func cachedVideoTags(platformID: String, entryID: String, input: VideoClassificationPipeline.Input? = nil) -> VideoTagsProjection? {
        lock.lock()
        defer { lock.unlock() }
        let catalog = state.workspaceCatalog
        let servingModelVersion = classificationEngine.modelVersion
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
            guard Self.isClassificationCurrent(classification, forType: type, servingModelVersion: servingModelVersion) else {
                return nil
            }
            // Browser tagging may arrive before collection updates the title.
            // Compare cloud rows with the actual request evidence when supplied.
            let entry = Self.collectedEntry(platformID: platformID, entryID: entryID, catalog: catalog)
            let observed = (type.classificationProvider == .chatGPT ? input : nil) ?? entry.map {
                VideoClassificationPipeline.Input(title: $0.title, summary: $0.summary, text: $0.text, entryID: $0.entryID, creatorID: $0.creatorID)
            }
            if type.classificationProvider == .chatGPT, classification.source != .humanCorrected {
                guard let observed, observed.entryID == entryID,
                      classification.inputFingerprint == CloudClassificationCurrency.input(title: observed.title,
                        summary: observed.summary, text: observed.text, creatorID: observed.creatorID, creatorName: entry?.creatorName) else { return nil }
            }
            if classification.source != .humanCorrected, let dictionaryProvider {
                guard let observed else { return nil }
                let evidence = dictionaryProvider.localEvidence(title: observed.title, creatorID: classification.creatorID)
                let enriched = evidence.overlay(on: catalog, title: observed.title, creatorID: classification.creatorID)
                guard classification.knowledgeFingerprint == DictionaryEvidence.fingerprint(title: observed.title, creatorID: classification.creatorID, catalog: enriched, settings: state.settings.research) else { return nil }
            }
        }
        guard sawClassification else { return nil }
        return Self.videoTagsProjection(entryID: entryID, platformID: platformID, types: types, catalog: catalog)
    }

    /// Human corrections remain authoritative; automatic rows must match cloud settings.
    static func isClassificationCurrent(
        _ classification: VideoClassification,
        forType type: ClassifierTypeAsset,
        servingModelVersion: String
    ) -> Bool {
        if classification.source == .humanCorrected { return true }
        return classification.modelVersion == type.cloudModelVersion + "+p4"
            && classification.tagBounds == type.tagging.tagBounds
            && classification.treeID == type.treeID
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
        try shutdownSignal.checkCancellation()
        let snapshot = lock.withLock {
            (
                state.workspaceCatalog,
                classificationEngine,
                state.settings.research,
                state.settings.classificationEnabled,
                self.dictionaryProvider,
                cloudEngineResolver
            )
        }
        let (
            catalog, defaultLLM, globalResearchSettings, classificationEnabled, dictionaryProvider, cloudResolver
        ) = snapshot

        guard let binding = catalog.bindings.first(where: { $0.id == platformID }), binding.collectionEnabled else {
            throw PlatformCollectionError.disabled(platformID)
        }
        let types = classificationEnabled ? Self.orderedTypes(for: platformID, in: catalog).filter { !$0.isPaused } : []
        guard !types.isEmpty, !items.isEmpty else {
            return Dictionary(items.map { ($0.entryID, VideoTagsProjection(tags: [], predicted: false)) }, uniquingKeysWith: { first, _ in first })
        }

        var dictionaryEvidence: [String: DictionaryEvidence] = [:]
        if let dictionaryProvider {
            for item in items {
                let attributes = Self.collectedEntry(platformID: platformID, entryID: item.entryID, catalog: catalog)?.attributes ?? [:]
                dictionaryEvidence[item.entryID] = await dictionaryProvider.evidence(
                    title: item.title,
                    creatorID: catalog.creatorKnowledgeEntry(for: item.creatorID) == nil ? item.creatorID : "",
                    subscriberCount: DictionaryKeys.subscriberCount(attributes))
            }
        }

        var classifications: [VideoClassification] = []
        for type in types {
            try shutdownSignal.checkCancellation()
            guard enabledClassificationPlatformIDs().contains(platformID) else { break }
            guard let tree = catalog.trees.first(where: { $0.id == type.treeID }),
                  type.treeRevision == tree.revision else { continue }
            let settings = type.tagging
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

            let llm: any ClassificationEngine
            if let cloudResolver {
                try type.chatGPT.validate()
                llm = try await cloudResolver.resolveCloudEngine(for: type)
            } else {
                llm = defaultLLM // Explicit injection only; production default throws notConfigured.
            }
            try shutdownSignal.checkCancellation()
            // Every group owns its Strict↔Broad position.
            let strictness = settings.strictness
            let bounds = settings.tagBounds
            let pipeline = VideoClassificationPipeline(
                llm: llm, maximumTags: bounds.maximum, minimumTags: bounds.minimum,
                secondaryConfidenceFloor: type.classificationProvider == .chatGPT
                    ? (strictness == .strictest || strictness == .strict ? 5 : strictness == .balanced ? 4 : 3) : 4)
            let trimmedRules = settings.houseRules.trimmingCharacters(in: .whitespacesAndNewlines)
            let typeHouseRules = trimmedRules.isEmpty ? nil : trimmedRules
            let results = try await pipeline.classifyBatch(
                pending,
                platformID: platformID,
                classifierType: type,
                tree: tree,
                catalog: catalog,
                houseRules: typeHouseRules,
                extraTagMinimumOdds: strictness.extraTagMinimumOdds,
                knowledgeTTLDays: globalResearchSettings.knowledgeTTLDays,
                maxKnowledgePerVideo: globalResearchSettings.maxKnowledgePerVideo,
                dictionaryEvidence: dictionaryEvidence
            )
            try shutdownSignal.checkCancellation()
            classifications.append(contentsOf: results)
        }

        let tPersist = DispatchTime.now()
        defer {
            if ProcessInfo.processInfo.environment["VAULT_DECODE_TIMING"] == "1" {
                FileHandle.standardError.write(Data(String(
                    format: "[classify-timing] videos=%d  persist+after=%.0fms\n", items.count,
                    Double(DispatchTime.now().uptimeNanoseconds - tPersist.uptimeNanoseconds) / 1_000_000).utf8))
            }
        }
        let saved = try lock.withLock { () -> WorkspaceCatalog in
            try shutdownSignal.checkCancellation()
            let activeIDs = state.settings.classificationEnabled
                ? Set(state.workspaceCatalog.classifierTypes.filter { !$0.isPaused }.map(\.id)) : []
            for classification in classifications where activeIDs.contains(classification.classifierTypeID) {
                if let original = catalog.classifierTypes.first(where: { $0.id == classification.classifierTypeID }),
                   let current = state.workspaceCatalog.classifierTypes.first(where: { $0.id == classification.classifierTypeID }),
                   (original.classificationProvider != current.classificationProvider
                    || original.chatGPT != current.chatGPT || original.tagging != current.tagging
                    || original.treeRevision != current.treeRevision) { throw CancellationError() }
                if state.workspaceCatalog.videoClassification(classifierTypeID: classification.classifierTypeID, platformID: classification.platformID, entryID: classification.entryID)?.source == .humanCorrected,
                   classification.source != .humanCorrected { continue }
                state.workspaceCatalog.upsertVideoClassification(classification)
            }
            try stateFile.save(state)
            return state.workspaceCatalog
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
        return projections
    }

    /// The research settings a type runs with, or nil when it must not research.
    /// A type may switch itself off, but it can never switch itself on while the
    /// app-wide consent (the master gate) is off.
    public static func effectiveResearchSettings(
        global: ResearchSettings,
        for classifierType: ClassifierTypeAsset
    ) -> ResearchSettings? {
        guard global.enabled, classifierType.researchEnabled ?? true else { return nil }
        return global
    }

    /// The derived research urgency for a model classification (inverse of its
    /// mean confidence; a decline = 5): the per-video sample the creator
    /// accumulator averages.
    public static func researchUrgency(for classification: VideoClassification) -> Int {
        ResearchUrgency.fromTagConfidences(classification.tags.map(\.confidence))
    }

    public static func orderedTypes(for platformID: String, in catalog: WorkspaceCatalog) -> [ClassifierTypeAsset] {
        catalog.classifierTypes
            .filter { $0.applicablePlatformIDs.contains(platformID) }
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
