import Foundation

// Ties the pieces together for one video: read the derived creator prior +
// matched knowledge from the catalog, assemble the prompt, run the on-device
// LLM, map the model's readable tag names back to tag ids, and produce a
// `VideoClassification`. Storage (upsert + histogram update) is the caller's
// step, so this stays a pure transform and is easy to test with the stub LLM.

public struct VideoClassificationPipeline: Sendable {
    public let llm: any OnDeviceLLM
    /// Upper bound on tags per video. The engine now emits up to this many names
    /// (grammar-bounded), so it is a real knob — but see `secondaryConfidenceFloor`:
    /// only the top tag is unconditional; additional tags must clear the floor, so
    /// a single-topic video still resolves to one tag even at a high cap.
    public let maximumTags: Int
    /// Fewest tags to keep (0 = may decline). ≥1 forbids declining and forces the
    /// best guesses even below the secondary floor; see LocalLLMSettings.minimumTags.
    public let minimumTags: Int
    /// A secondary (non-top) tag is kept only when its confidence is at least this.
    /// Ungated multi-tag floods low-confidence guesses (eval 2026-09-16: at cap 3,
    /// micro-precision 0.56→0.21, exact-set 57%→24%); gating the extras at the
    /// policy's own block floor keeps genuine multi-topic recall without that
    /// precision collapse. The top tag is always kept (single-tag behavior is
    /// exactly preserved at cap 1, or when no secondary clears the floor).
    public let secondaryConfidenceFloor: Int
    public let promptVersion: String
    /// Minimum cross-creator title similarity for a correction to be retrieved as
    /// a per-video exemplar (see CorrectionRetriever). Exposed so the eval A/B can
    /// sweep it; production uses the retriever's tuned default.
    public let correctionSimilarityFloor: Double
    /// At or below this top confidence (or on a decline) the pipeline retries with
    /// the creator's stored description. A classification constant — it was
    /// formerly borrowed from the research `confidenceTriggerLevel` setting.
    public static let defaultCreatorGroundingConfidenceFloor = 2

    public init(
        llm: any OnDeviceLLM,
        maximumTags: Int = 5,
        minimumTags: Int = 0,
        secondaryConfidenceFloor: Int = 4,
        // p2 = bare tag-name reply, confidence derived from token odds (2026-09-21).
        // Cached p1 rows stay valid: the currency check matches the model file only.
        // p3 = compact creator line, no "Video:" label (2026-09-22).
        promptVersion: String = "p3",
        correctionSimilarityFloor: Double = CorrectionRetriever.defaultMinimumSimilarity
    ) {
        self.llm = llm
        self.maximumTags = maximumTags
        self.minimumTags = TagBounds(minimum: minimumTags, maximum: maximumTags).minimum
        self.secondaryConfidenceFloor = secondaryConfidenceFloor
        self.promptVersion = promptVersion
        self.correctionSimilarityFloor = correctionSimilarityFloor
    }

    /// One video's evidence for a batched classification.
    public struct Input: Sendable {
        public let title: String
        public let summary: String?
        public let text: String?
        public let entryID: String
        public let creatorID: String
        public init(title: String, summary: String? = nil, text: String? = nil, entryID: String, creatorID: String) {
            self.title = title
            self.summary = summary
            self.text = text
            self.entryID = entryID
            self.creatorID = creatorID
        }
    }

    /// Single-video convenience: a batch of one, so there is exactly one code path.
    public func classify(
        title: String,
        summary: String? = nil,
        text: String? = nil,
        entryID: String,
        creatorID: String,
        platformID: String,
        classifierType: ClassifierTypeAsset,
        tree: TagTreeAsset,
        catalog: WorkspaceCatalog,
        houseRules: String? = nil,
        allowDecline: Bool? = nil,
        confidenceThresholds: [Double]? = nil,
        knowledgeTTLDays: Int = ResearchSettings.defaultKnowledgeTTLDays,
        maxKnowledgePerVideo: Int = ResearchSettings.defaultMaxKnowledgePerVideo,
        creatorGroundingConfidenceFloor: Int = VideoClassificationPipeline.defaultCreatorGroundingConfidenceFloor
    ) async throws -> VideoClassification {
        try await classifyBatch(
            [Input(title: title, summary: summary, text: text, entryID: entryID, creatorID: creatorID)],
            platformID: platformID, classifierType: classifierType, tree: tree, catalog: catalog,
            houseRules: houseRules, allowDecline: allowDecline, confidenceThresholds: confidenceThresholds,
            knowledgeTTLDays: knowledgeTTLDays, maxKnowledgePerVideo: maxKnowledgePerVideo,
            creatorGroundingConfidenceFloor: creatorGroundingConfidenceFloor
        )[0]
    }

    /// Classifies a screenful of videos against one classifier type. All primary
    /// decodes go to the engine as ONE batch (`classifyAll` → a multi-sequence pass
    /// on engines that support it; LATENCY-REFINEMENT Phase 1); the videos that come
    /// back weak AND have a keyed creator then share a second, creator-grounded
    /// batch. Results are positional. Note: videos in one batch do not see each
    /// other in the creator prior (it reflects the catalog before the batch).
    public func classifyBatch(
        _ inputs: [Input],
        platformID: String,
        classifierType: ClassifierTypeAsset,
        tree: TagTreeAsset,
        catalog: WorkspaceCatalog,
        houseRules: String? = nil,
        allowDecline: Bool? = nil,
        confidenceThresholds: [Double]? = nil,
        knowledgeTTLDays: Int = ResearchSettings.defaultKnowledgeTTLDays,
        maxKnowledgePerVideo: Int = ResearchSettings.defaultMaxKnowledgePerVideo,
        creatorGroundingConfidenceFloor: Int = VideoClassificationPipeline.defaultCreatorGroundingConfidenceFloor
    ) async throws -> [VideoClassification] {
        guard !inputs.isEmpty else { return [] }
        let timing = ProcessInfo.processInfo.environment["VAULT_DECODE_TIMING"] == "1"
        let tStart = DispatchTime.now()
        // Evidence gathering (creator prior + matched knowledge + correction
        // exemplars) is shared with `primaryPromptParts`, so the calibration eval
        // drives the model on the exact same prompt this path builds.
        let evidence = inputs.map { input in
            gatherEvidence(
                title: input.title, entryID: input.entryID, creatorID: input.creatorID, platformID: platformID,
                classifierType: classifierType, tree: tree, catalog: catalog,
                knowledgeTTLDays: knowledgeTTLDays, maxKnowledgePerVideo: maxKnowledgePerVideo
            )
        }
        func parts(_ index: Int, knowledge: [KnowledgeEntry]) -> ClassificationPromptParts {
            ClassificationPromptAssembler.assemble(
                tree: tree, houseRules: houseRules, maximumTags: maximumTags, minimumTags: minimumTags,
                title: inputs[index].title, summary: inputs[index].summary, text: inputs[index].text,
                creatorPrior: evidence[index].creatorPrior, creatorVideoCount: evidence[index].creatorVideoCount,
                knowledge: knowledge, correctionExemplars: evidence[index].correctionExemplars
            )
        }
        func request(_ parts: ClassificationPromptParts) -> LLMClassificationRequest {
            LLMClassificationRequest(
                staticPrefix: parts.staticPrefix, dynamicSuffix: parts.dynamicSuffix,
                allowedTagNames: parts.allowedTagNames, maximumTags: maximumTags, minimumTags: minimumTags,
                allowDecline: allowDecline, confidenceThresholds: confidenceThresholds
            )
        }

        // Primary decode: each video's own content plus any matched term
        // knowledge. The creator description is deliberately withheld here.
        let primaryParts = inputs.indices.map { parts($0, knowledge: evidence[$0].termKnowledge) }
        let tAssembled = DispatchTime.now()
        let primaryResults = try await llm.classifyAll(primaryParts.map(request))
        if timing {
            let ms = { (a: DispatchTime, b: DispatchTime) in Double(b.uptimeNanoseconds - a.uptimeNanoseconds) / 1_000_000 }
            FileHandle.standardError.write(Data(String(
                format: "[pipeline-timing] videos=%d  evidence+assemble=%.0f  classifyAll=%.0fms\n",
                inputs.count, ms(tStart, tAssembled), ms(tAssembled, DispatchTime.now())).utf8))
        }
        var tags = zip(primaryResults, primaryParts).map { scoredTags(from: $0, parts: $1) }
        var knowledgeUsed = evidence.map(\.termKnowledge)
        var grounded = [Bool](repeating: false, count: inputs.count)

        // Low-confidence creator fallback: when the content signal is weak (a
        // decline, or a top confidence at/under the floor) and this creator is
        // already keyed, infer the tag from the creator's stored description.
        let weak: [(index: Int, knowledge: [KnowledgeEntry])] = inputs.indices.compactMap { index in
            guard (tags[index].map(\.confidence).max() ?? 0) <= creatorGroundingConfidenceFloor,
                  let creatorEntry = catalog.creatorKnowledgeEntry(for: inputs[index].creatorID) else { return nil }
            return (index, evidence[index].termKnowledge + [creatorEntry])
        }
        if !weak.isEmpty {
            let groundedParts = weak.map { parts($0.index, knowledge: $0.knowledge) }
            let groundedResults = try await llm.classifyAll(groundedParts.map(request))
            for (slot, candidate) in weak.enumerated() {
                let groundedTags = scoredTags(from: groundedResults[slot], parts: groundedParts[slot])
                // Only adopt the creator-grounded result if it actually produced a
                // tag (or improved confidence); otherwise keep the primary outcome.
                let primaryTop = tags[candidate.index].map(\.confidence).max() ?? 0
                guard !groundedTags.isEmpty, (groundedTags.map(\.confidence).max() ?? 0) >= primaryTop else { continue }
                tags[candidate.index] = groundedTags
                knowledgeUsed[candidate.index] = candidate.knowledge
                grounded[candidate.index] = true
            }
        }

        return inputs.indices.map { index in
            VideoClassification(
                classifierTypeID: classifierType.id,
                platformID: platformID,
                entryID: inputs[index].entryID,
                creatorID: inputs[index].creatorID,
                treeID: tree.id,
                treeRevision: tree.revision,
                tags: tags[index],
                knowledgeRefs: knowledgeUsed[index].map(\.id),
                source: (grounded[index] || !knowledgeUsed[index].isEmpty) ? .modelKnowledge : .model,
                modelVersion: "\(llm.modelVersion)+\(promptVersion)"
            )
        }
    }

    /// The creator prior + correction exemplars + matched term knowledge for one
    /// video — the evidence that `classify`'s primary decode and `primaryPromptParts`
    /// both build on. Extracted so the two paths can never drift apart.
    private func gatherEvidence(
        title: String,
        entryID: String,
        creatorID: String,
        platformID: String,
        classifierType: ClassifierTypeAsset,
        tree: TagTreeAsset,
        catalog: WorkspaceCatalog,
        knowledgeTTLDays: Int,
        maxKnowledgePerVideo: Int
    ) -> (creatorPrior: [CreatorPriorTag], creatorVideoCount: Int, correctionExemplars: [CorrectionExemplar], termKnowledge: [KnowledgeEntry]) {
        let nameByID = Dictionary(tree.nodes.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })

        // Derived creator prior: how often THIS creator's already-classified
        // videos carry each tag (share of videoCount). A consistent creator is a
        // strong prior for an otherwise-ambiguous title; the assembler frames it.
        var creatorPrior: [CreatorPriorTag] = []
        var creatorVideoCount = 0
        if let histogram = catalog.creatorHistogram(classifierTypeID: classifierType.id, platformID: platformID, creatorID: creatorID), histogram.videoCount > 0 {
            creatorVideoCount = histogram.videoCount
            creatorPrior = histogram.stats
                .compactMap { tagID, stat -> CreatorPriorTag? in
                    guard let name = nameByID[tagID] else { return nil }
                    return CreatorPriorTag(tagName: name, count: stat.count, share: Double(stat.count) / Double(histogram.videoCount),
                                           averageConfidence: stat.averageConfidence, confidenceStdev: stat.confidenceStdev)
                }
                .sorted { $0.share == $1.share ? $0.tagName < $1.tagName : $0.share > $1.share }
        }

        // Grounded generalization: the user's own past corrections most similar
        // to THIS video, as concrete few-shot exemplars (see CorrectionRetriever).
        // Relevance-ranked per video, not a static recency block — so the model
        // generalizes from the corrections that actually bear on this title.
        let correctionExemplars = CorrectionRetriever.retrieve(
            title: title,
            creatorID: creatorID,
            excludingEntryID: entryID,
            from: catalog.correctionExamples.filter { $0.classifierTypeID == classifierType.id },
            tree: tree,
            minimumSimilarity: correctionSimilarityFloor
        )

        // Matched term knowledge. The creator description is deliberately withheld
        // here (it enters only via the low-confidence creator fallback).
        let termKnowledge = catalog.matchedKnowledge(
            title: title,
            creatorID: creatorID,
            limit: maxKnowledgePerVideo,
            ttlDays: knowledgeTTLDays
        )
        return (creatorPrior, creatorVideoCount, correctionExemplars, termKnowledge)
    }

    /// The exact prompt parts `classify`'s primary decode would build for one
    /// video. Exposed so the calibration eval (RESEARCH-REDESIGN Phase 0) can run
    /// `classifyWithModelConfidence` on the real production prompt without
    /// duplicating the evidence-gathering, and so both stay in lockstep.
    public func primaryPromptParts(
        title: String,
        summary: String? = nil,
        text: String? = nil,
        entryID: String,
        creatorID: String,
        platformID: String,
        classifierType: ClassifierTypeAsset,
        tree: TagTreeAsset,
        catalog: WorkspaceCatalog,
        houseRules: String? = nil,
        knowledgeTTLDays: Int = ResearchSettings.defaultKnowledgeTTLDays,
        maxKnowledgePerVideo: Int = ResearchSettings.defaultMaxKnowledgePerVideo
    ) -> ClassificationPromptParts {
        let evidence = gatherEvidence(
            title: title, entryID: entryID, creatorID: creatorID, platformID: platformID,
            classifierType: classifierType, tree: tree, catalog: catalog,
            knowledgeTTLDays: knowledgeTTLDays, maxKnowledgePerVideo: maxKnowledgePerVideo
        )
        return ClassificationPromptAssembler.assemble(
            tree: tree,
            houseRules: houseRules,
            maximumTags: maximumTags,
            minimumTags: minimumTags,
            title: title,
            summary: summary,
            text: text,
            creatorPrior: evidence.creatorPrior,
            creatorVideoCount: evidence.creatorVideoCount,
            knowledge: evidence.termKnowledge,
            correctionExemplars: evidence.correctionExemplars
        )
    }

    /// Maps one engine result's readable tag names back to tree ids and applies
    /// the top-tag / secondary-floor gate.
    private func scoredTags(from result: LLMClassificationResult, parts: ClassificationPromptParts) -> [ScoredTag] {
        // Map readable names back to tag ids; silently drop any name not in the
        // tree (a constrained decoder should prevent these, but a stub or a loose
        // runtime might not). Dedupe by id, keeping the highest confidence.
        var confidenceByTagID: [String: Int] = [:]
        for scored in result.tags {
            guard let tagID = parts.nameToTagID[scored.name] else { continue }
            confidenceByTagID[tagID] = max(confidenceByTagID[tagID] ?? 0, scored.confidence)
        }
        var scoredTags: [ScoredTag] = confidenceByTagID.map { tagID, confidence in
            ScoredTag(tagID: tagID, confidence: confidence)
        }
        scoredTags.sort { lhs, rhs in
            lhs.confidence == rhs.confidence ? lhs.tagID < rhs.tagID : lhs.confidence > rhs.confidence
        }
        // Keep the top tag unconditionally (the primary decision — identical to
        // the former single-tag behavior); add further tags only when they clear
        // the secondary-confidence floor, so an over-eager multi-tag decode can't
        // flood a single-topic video with low-confidence guesses.
        let mustKeep = max(1, minimumTags)
        let gated = scoredTags.enumerated()
            .filter { $0.offset < mustKeep || $0.element.confidence >= secondaryConfidenceFloor }
            .map(\.element)
        return Array(gated.prefix(maximumTags))
    }
}
