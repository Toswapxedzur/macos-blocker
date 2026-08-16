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
        confidenceThresholds: [Double]? = nil
    ) async throws -> VideoClassification {
        let nameByID = Dictionary(tree.nodes.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })

        // Derived creator prior (id → readable name), for the weak view-history prior.
        let creatorPrior: [(tagName: String, averageConfidence: Double)]
        if let histogram = catalog.creatorHistogram(classifierTypeID: classifierType.id, platformID: platformID, creatorID: creatorID) {
            creatorPrior = histogram.averagedTags().compactMap { entry in
                nameByID[entry.tagID].map { (tagName: $0, averageConfidence: entry.averageConfidence) }
            }
        } else {
            creatorPrior = []
        }

        let knowledge = catalog.matchedKnowledge(title: title, creatorID: creatorID)

        let parts = ClassificationPromptAssembler.assemble(
            tree: tree,
            houseRules: houseRules,
            maximumTags: maximumTags,
            title: title,
            summary: summary,
            text: text,
            creatorPrior: creatorPrior,
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
        let topTags = Array(scoredTags.prefix(maximumTags))

        return VideoClassification(
            classifierTypeID: classifierType.id,
            platformID: platformID,
            entryID: entryID,
            creatorID: creatorID,
            treeID: tree.id,
            treeRevision: tree.revision,
            tags: topTags,
            unknownTerms: result.unknownTerms,
            knowledgeRefs: knowledge.map(\.id),
            source: knowledge.isEmpty ? .model : .modelKnowledge,
            modelVersion: "\(llm.modelVersion)+\(promptVersion)"
        )
    }
}
