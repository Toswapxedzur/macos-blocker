import Foundation

/// Errors raised only after a platform explicitly opts into a workspace
/// classifier type. They prevent a changed tree, dataset, or model from
/// silently falling through to an unrelated legacy classifier.
public enum WorkspaceClassifierError: Error, Equatable, LocalizedError, Sendable {
    case missingClassifierType(String)
    case incompatibleClassifierType(String)
    case missingLocalModel(String)

    public var errorDescription: String? {
        switch self {
        case .missingClassifierType(let id):
            return "The selected classifier type no longer exists: \(id)."
        case .incompatibleClassifierType(let id):
            return "The selected classifier type is not compatible with this platform: \(id)."
        case .missingLocalModel(let id):
            return "The selected classifier type has no ready local neural model: \(id)."
        }
    }
}

public extension TagTreeAsset {
    /// Converts the editable local tree into the taxonomy used for inference.
    /// Retired tags remain structural ancestors but cannot receive a score.
    func inferenceTaxonomy() throws -> Taxonomy {
        try Taxonomy(nodes: nodes.map { node in
            .init(
                id: node.id,
                name: node.name,
                parentID: node.parentID,
                predictable: !node.isRetired
            )
        })
    }
}

/// Performs deterministic on-device inference for an explicitly selected
/// classifier type. Browser calls can only reach this component through a
/// platform binding; provider profiles are intentionally not consulted here.
public struct WorkspaceNeuralClassifier: Sendable {
    public static let threshold = 0.50
    public static let maximumScores = 256
    public static let maximumSelectedTags = 64

    public let classifierType: ClassifierTypeAsset
    public let model: LocalModelAsset
    public let taxonomy: Taxonomy
    public let policies: [NamedPolicy]

    public init(
        classifierType: ClassifierTypeAsset,
        model: LocalModelAsset,
        taxonomy: Taxonomy,
        policies: [NamedPolicy]
    ) {
        self.classifierType = classifierType
        self.model = model
        self.taxonomy = taxonomy
        self.policies = policies
    }

    public func classify(_ entry: EntryEvidence) throws -> ClassificationResult {
        try EntryEvidenceValidator().validate(entry)

        // A type may be deliberately configured for human/LLM entry review.
        // It is selected, so it must not silently use the old seed engine; it
        // simply has no automatic decision source for this entry.
        guard classifierType.entryDecisionSources.contains(.localModel) else {
            return .init(
                entryID: entry.entryID,
                sourceID: entry.sourceID,
                surface: entry.surface,
                evidenceState: .limited,
                threshold: 1,
                selectedLeafTagIDs: [],
                ancestorTagIDs: [],
                scores: [],
                decisions: [],
                packageID: "workspace-classifier-type-\(classifierType.id)",
                modelVersion: "manual-entry-decision"
            )
        }

        guard let neuralModel = model.embeddedNeuralModel else {
            throw WorkspaceClassifierError.missingLocalModel(classifierType.id)
        }
        let readableText = [entry.evidence.title, entry.evidence.summary, entry.evidence.text]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let allowedTags = taxonomy.predictableLeafIDs
        var scores: [TagScore] = []
        for prediction in neuralModel.predictions(for: readableText) {
            guard allowedTags.contains(prediction.labelID), prediction.probability.isFinite else { continue }
            let probability = min(1, max(0, prediction.probability))
            scores.append(.init(
                tagID: prediction.labelID,
                directScore: probability,
                sourceScore: nil,
                finalScore: probability
            ))
        }
        scores.sort { lhs, rhs in
            lhs.finalScore == rhs.finalScore ? lhs.tagID < rhs.tagID : lhs.finalScore > rhs.finalScore
        }
        scores = Array(scores.prefix(Self.maximumScores))
        let selected = scores
            .filter { $0.finalScore >= Self.threshold }
            .prefix(Self.maximumSelectedTags)
            .map { $0.tagID }
        var result = ClassificationResult(
            entryID: entry.entryID,
            sourceID: entry.sourceID,
            surface: entry.surface,
            evidenceState: readableText.isEmpty ? .limited : .sufficient,
            threshold: Self.threshold,
            selectedLeafTagIDs: selected,
            ancestorTagIDs: taxonomy.ancestorClosure(for: selected),
            scores: scores,
            decisions: [],
            packageID: "workspace-classifier-type-\(classifierType.id)",
            modelVersion: "local-neural-\(model.id)-v\(model.version)"
        )
        result.decisions = PolicyEvaluator(taxonomy: taxonomy).evaluate(
            result: result,
            policies: policies,
            requestedPolicyIDs: entry.policyIDs
        )
        return result
    }
}

public extension WorkspaceCatalog {
    /// Returns `nil` only when the platform has not selected a classifier type
    /// yet. That preserves a deliberate migration path for existing profiles;
    /// once selected, an invalid type is an error rather than a fallback.
    func workspaceClassifier(for platformID: String, policies: [NamedPolicy]) throws -> WorkspaceNeuralClassifier? {
        guard let binding = bindings.first(where: { $0.id == platformID }),
              let classifierTypeID = binding.activeClassifierTypeID else {
            return nil
        }
        guard let classifierType = classifierTypes.first(where: { $0.id == classifierTypeID }) else {
            throw WorkspaceClassifierError.missingClassifierType(classifierTypeID)
        }
        guard classifierType.treeID == binding.treeID,
              classifierType.datasetID == binding.datasetID,
              classifierType.applicablePlatformID == binding.id,
              let tree = trees.first(where: { $0.id == binding.treeID }),
              let dataset = datasets.first(where: { $0.id == binding.datasetID }),
              classifierType.treeRevision == tree.revision,
              classifierType.datasetRevision == dataset.revision else {
            throw WorkspaceClassifierError.incompatibleClassifierType(classifierTypeID)
        }
        guard classifierType.entryDecisionSources.contains(.localModel) else {
            return .init(
                classifierType: classifierType,
                model: .init(
                    name: "No automatic local model",
                    treeID: tree.id,
                    treeRevision: tree.revision,
                    datasetID: dataset.id,
                    datasetRevision: dataset.revision
                ),
                taxonomy: try tree.inferenceTaxonomy(),
                policies: policies
            )
        }
        guard let modelID = classifierType.localModelID,
              binding.activeModelID == modelID,
              let model = models.first(where: { $0.id == modelID }),
              model.isReady,
              model.embeddedNeuralModel != nil,
              model.treeID == tree.id,
              model.treeRevision == tree.revision,
              model.datasetID == dataset.id,
              model.datasetRevision == dataset.revision else {
            throw WorkspaceClassifierError.missingLocalModel(classifierTypeID)
        }
        return .init(
            classifierType: classifierType,
            model: model,
            taxonomy: try tree.inferenceTaxonomy(),
            policies: policies
        )
    }
}
