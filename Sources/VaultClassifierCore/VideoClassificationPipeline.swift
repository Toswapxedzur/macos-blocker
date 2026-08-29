import Foundation

// Ties the pieces together for one video: read the derived creator prior +
// matched knowledge from the catalog, assemble the prompt, run the on-device
// LLM, map the model's readable tag names back to tag ids, and produce a
// `VideoClassification`. Storage (upsert + histogram update) is the caller's
// step, so this stays a pure transform and is easy to test with the stub LLM.

public struct VideoClassificationPipeline: Sendable {
    public let llm: any OnDeviceLLM
    /// App-wide cap. The shipping grammar emits one name, so this is deliberately
    /// not exposed as a per-type override.
    public let maximumTags: Int
    public let promptVersion: String

    public init(llm: any OnDeviceLLM, maximumTags: Int = 5, promptVersion: String = "p1") {
        self.llm = llm
        self.maximumTags = maximumTags
        self.promptVersion = promptVersion
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
        creatorGroundingConfidenceFloor: Int = ResearchSettings.defaultConfidenceTriggerLevel
    ) async throws -> VideoClassification {
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

        // Primary decode: the video's own content plus any matched term
        // knowledge. The creator description is deliberately withheld here.
        let termKnowledge = catalog.matchedKnowledge(
            title: title,
            creatorID: creatorID,
            limit: maxKnowledgePerVideo,
            ttlDays: knowledgeTTLDays
        )
        let primary = try await decode(
            tree: tree, houseRules: houseRules, title: title, summary: summary, text: text,
            creatorPrior: creatorPrior, creatorVideoCount: creatorVideoCount, knowledge: termKnowledge,
            allowDecline: allowDecline, confidenceThresholds: confidenceThresholds
        )

        // Low-confidence creator fallback: when the content signal is weak (a
        // decline, or a top confidence at/under the floor) and this creator is
        // already keyed, infer the tag from the creator's stored description.
        let primaryTop = primary.tags.map(\.confidence).max() ?? 0
        if primaryTop <= creatorGroundingConfidenceFloor,
           let creatorEntry = catalog.creatorKnowledgeEntry(for: creatorID) {
            let groundedKnowledge = termKnowledge + [creatorEntry]
            let grounded = try await decode(
                tree: tree, houseRules: houseRules, title: title, summary: summary, text: text,
                creatorPrior: creatorPrior, creatorVideoCount: creatorVideoCount, knowledge: groundedKnowledge,
                allowDecline: allowDecline, confidenceThresholds: confidenceThresholds
            )
            // Only adopt the creator-grounded result if it actually produced a
            // tag (or improved confidence); otherwise keep the primary outcome.
            let groundedTop = grounded.tags.map(\.confidence).max() ?? 0
            if !grounded.tags.isEmpty, groundedTop >= primaryTop {
                return VideoClassification(
                    classifierTypeID: classifierType.id,
                    platformID: platformID,
                    entryID: entryID,
                    creatorID: creatorID,
                    treeID: tree.id,
                    treeRevision: tree.revision,
                    tags: grounded.tags,
                    unknownTerms: grounded.unknownTerms,
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
            tags: primary.tags,
            unknownTerms: primary.unknownTerms,
            knowledgeRefs: termKnowledge.map(\.id),
            source: termKnowledge.isEmpty ? .model : .modelKnowledge,
            modelVersion: "\(llm.modelVersion)+\(promptVersion)"
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
        allowDecline: Bool?,
        confidenceThresholds: [Double]?
    ) async throws -> (tags: [ScoredTag], unknownTerms: [String]) {
        let parts = ClassificationPromptAssembler.assemble(
            tree: tree,
            houseRules: houseRules,
            maximumTags: maximumTags,
            title: title,
            summary: summary,
            text: text,
            creatorPrior: creatorPrior,
            creatorVideoCount: creatorVideoCount,
            knowledge: knowledge
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
        return (Array(scoredTags.prefix(maximumTags)), result.unknownTerms)
    }
}
