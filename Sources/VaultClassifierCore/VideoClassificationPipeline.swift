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
    /// Keep only the creator's top-N history rows in the prompt (nil = all). Every
    /// row is ~19 prompt tokens that must be PREFILLED per video — compute-bound and
    /// not amortized by batching — so a prolific creator's 10-row history costs
    /// ~800 ms on a 7B (LATENCY-REFINEMENT, measured 2026-09-17).
    public let creatorPriorRowLimit: Int?

    public init(
        llm: any OnDeviceLLM,
        maximumTags: Int = 5,
        secondaryConfidenceFloor: Int = 4,
        promptVersion: String = "p1",
        correctionSimilarityFloor: Double = CorrectionRetriever.defaultMinimumSimilarity,
        creatorPriorRowLimit: Int? = nil
    ) {
        self.llm = llm
        self.maximumTags = maximumTags
        self.secondaryConfidenceFloor = secondaryConfidenceFloor
        self.promptVersion = promptVersion
        self.correctionSimilarityFloor = correctionSimilarityFloor
        self.creatorPriorRowLimit = creatorPriorRowLimit.map { max(1, $0) }
    }

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
        // Evidence gathering (creator prior + matched knowledge + correction
        // exemplars) is shared with `primaryPromptParts`, so the calibration eval
        // drives the model on the exact same prompt this path builds.
        let evidence = gatherEvidence(
            title: title, entryID: entryID, creatorID: creatorID, platformID: platformID,
            classifierType: classifierType, tree: tree, catalog: catalog,
            knowledgeTTLDays: knowledgeTTLDays, maxKnowledgePerVideo: maxKnowledgePerVideo
        )
        let creatorPrior = evidence.creatorPrior
        let creatorVideoCount = evidence.creatorVideoCount
        let termKnowledge = evidence.termKnowledge

        // Primary decode: the video's own content plus any matched term
        // knowledge. The creator description is deliberately withheld here.
        let primary = try await decode(
            tree: tree, houseRules: houseRules, title: title, summary: summary, text: text,
            creatorPrior: creatorPrior, creatorVideoCount: creatorVideoCount, knowledge: termKnowledge,
            correctionExemplars: evidence.correctionExemplars,
            allowDecline: allowDecline, confidenceThresholds: confidenceThresholds
        )

        // Low-confidence creator fallback: when the content signal is weak (a
        // decline, or a top confidence at/under the floor) and this creator is
        // already keyed, infer the tag from the creator's stored description.
        let primaryTop = primary.map(\.confidence).max() ?? 0
        if primaryTop <= creatorGroundingConfidenceFloor,
           let creatorEntry = catalog.creatorKnowledgeEntry(for: creatorID) {
            let groundedKnowledge = termKnowledge + [creatorEntry]
            let grounded = try await decode(
                tree: tree, houseRules: houseRules, title: title, summary: summary, text: text,
                creatorPrior: creatorPrior, creatorVideoCount: creatorVideoCount, knowledge: groundedKnowledge,
                correctionExemplars: evidence.correctionExemplars,
                allowDecline: allowDecline, confidenceThresholds: confidenceThresholds
            )
            // Only adopt the creator-grounded result if it actually produced a
            // tag (or improved confidence); otherwise keep the primary outcome.
            let groundedTop = grounded.map(\.confidence).max() ?? 0
            if !grounded.isEmpty, groundedTop >= primaryTop {
                return VideoClassification(
                    classifierTypeID: classifierType.id,
                    platformID: platformID,
                    entryID: entryID,
                    creatorID: creatorID,
                    treeID: tree.id,
                    treeRevision: tree.revision,
                    tags: grounded,
                    knowledgeRefs: groundedKnowledge.map(\.id),
                    source: .modelKnowledge,
                    modelVersion: "\(llm.modelVersion)+\(promptVersion)"
                )
            }
        }

        return VideoClassification(
            classifierTypeID: classifierType.id,
            platformID: platformID,
            entryID: entryID,
            creatorID: creatorID,
            treeID: tree.id,
            treeRevision: tree.revision,
            tags: primary,
            knowledgeRefs: termKnowledge.map(\.id),
            source: termKnowledge.isEmpty ? .model : .modelKnowledge,
            modelVersion: "\(llm.modelVersion)+\(promptVersion)"
        )
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
            if let creatorPriorRowLimit { creatorPrior = Array(creatorPrior.prefix(creatorPriorRowLimit)) }
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
            title: title,
            summary: summary,
            text: text,
            creatorPrior: evidence.creatorPrior,
            creatorVideoCount: evidence.creatorVideoCount,
            knowledge: evidence.termKnowledge,
            correctionExemplars: evidence.correctionExemplars
        )
    }

    /// One assemble-and-decode pass: builds the prompt from the given knowledge
    /// set, runs the LLM, and maps readable tag names back to tree ids.
    private func decode(
        tree: TagTreeAsset,
        houseRules: String?,
        title: String,
        summary: String?,
        text: String?,
        creatorPrior: [CreatorPriorTag],
        creatorVideoCount: Int,
        knowledge: [KnowledgeEntry],
        correctionExemplars: [CorrectionExemplar],
        allowDecline: Bool?,
        confidenceThresholds: [Double]?
    ) async throws -> [ScoredTag] {
        let parts = ClassificationPromptAssembler.assemble(
            tree: tree,
            houseRules: houseRules,
            maximumTags: maximumTags,
            title: title,
            summary: summary,
            text: text,
            creatorPrior: creatorPrior,
            creatorVideoCount: creatorVideoCount,
            knowledge: knowledge,
            correctionExemplars: correctionExemplars
        )
        let result = try await llm.classify(LLMClassificationRequest(
            staticPrefix: parts.staticPrefix,
            dynamicSuffix: parts.dynamicSuffix,
            allowedTagNames: parts.allowedTagNames,
            maximumTags: maximumTags,
            allowDecline: allowDecline,
            confidenceThresholds: confidenceThresholds
        ))
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
        let gated = scoredTags.enumerated()
            .filter { $0.offset == 0 || $0.element.confidence >= secondaryConfidenceFloor }
            .map(\.element)
        return Array(gated.prefix(maximumTags))
    }
}
