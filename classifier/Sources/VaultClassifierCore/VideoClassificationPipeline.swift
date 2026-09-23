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

    public init(
        llm: any OnDeviceLLM,
        maximumTags: Int = 5,
        minimumTags: Int = 0,
        secondaryConfidenceFloor: Int = 4,
        // p2 = bare tag-name reply, confidence derived from token odds (2026-09-21).
        // Cached p1 rows stay valid: the currency check matches the model file only.
        // p4 = researched creator sentence on the creator line, single pass (2026-09-22).
        promptVersion: String = "p4"
    ) {
        self.llm = llm
        self.maximumTags = maximumTags
        self.minimumTags = TagBounds(minimum: minimumTags, maximum: maximumTags).minimum
        self.secondaryConfidenceFloor = secondaryConfidenceFloor
        self.promptVersion = promptVersion
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
        extraTagMinimumOdds: Double? = nil,
        knowledgeTTLDays: Int = ResearchSettings.defaultKnowledgeTTLDays,
        maxKnowledgePerVideo: Int = ResearchSettings.defaultMaxKnowledgePerVideo
    ) async throws -> VideoClassification {
        try await classifyBatch(
            [Input(title: title, summary: summary, text: text, entryID: entryID, creatorID: creatorID)],
            platformID: platformID, classifierType: classifierType, tree: tree, catalog: catalog,
            houseRules: houseRules, extraTagMinimumOdds: extraTagMinimumOdds,
            knowledgeTTLDays: knowledgeTTLDays, maxKnowledgePerVideo: maxKnowledgePerVideo
        )[0]
    }

    /// Classifies a screenful of videos against one classifier type. All primary
    /// decodes go to the engine as ONE batch (`classifyAll` → a multi-sequence pass
    /// on engines that support it; LATENCY-REFINEMENT Phase 1) — one pass per video;
    /// a researched creator's one-sentence description rides on the creator line.
    /// Results are positional. Note: videos in one batch do not see each
    /// other in the creator prior (it reflects the catalog before the batch).
    public func classifyBatch(
        _ inputs: [Input],
        platformID: String,
        classifierType: ClassifierTypeAsset,
        tree: TagTreeAsset,
        catalog: WorkspaceCatalog,
        houseRules: String? = nil,
        extraTagMinimumOdds: Double? = nil,
        knowledgeTTLDays: Int = ResearchSettings.defaultKnowledgeTTLDays,
        maxKnowledgePerVideo: Int = ResearchSettings.defaultMaxKnowledgePerVideo
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
                knowledge: knowledge,
                creatorSummary: evidence[index].creatorEntry?.meaning
            )
        }
        func request(_ parts: ClassificationPromptParts) -> LLMClassificationRequest {
            LLMClassificationRequest(
                staticPrefix: parts.staticPrefix, dynamicSuffix: parts.dynamicSuffix,
                allowedTagNames: parts.allowedTagNames, maximumTags: maximumTags, minimumTags: minimumTags,
                extraTagMinimumOdds: extraTagMinimumOdds
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
        let tags = zip(primaryResults, primaryParts).map { scoredTags(from: $0, parts: $1) }
        // ONE pass per video. The creator's stored sentence rides on the creator
        // line above; the former second decode over weak videos (full description,
        // a whole extra video's time) was measured worse than this on 450 videos.
        let knowledgeUsed = evidence.map { $0.termKnowledge + ($0.creatorEntry.map { [$0] } ?? []) }

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
                source: knowledgeUsed[index].isEmpty ? .model : .modelKnowledge,
                modelVersion: "\(llm.modelVersion)+\(promptVersion)"
            )
        }
    }

    /// The creator prior + matched term knowledge + creator sentence for one
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
    ) -> (creatorPrior: [CreatorPriorTag], creatorVideoCount: Int, termKnowledge: [KnowledgeEntry], creatorEntry: KnowledgeEntry?) {
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

        // Matched term knowledge. The creator description is deliberately withheld
        // here (it enters only via the low-confidence creator fallback).
        let termKnowledge = catalog.matchedKnowledge(
            title: title,
            creatorID: creatorID,
            limit: maxKnowledgePerVideo,
            ttlDays: knowledgeTTLDays
        )
        return (creatorPrior, creatorVideoCount, termKnowledge, catalog.creatorKnowledgeEntry(for: creatorID))
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
            creatorSummary: evidence.creatorEntry?.meaning
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
