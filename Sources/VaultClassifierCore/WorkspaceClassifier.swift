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
                description: node.description,
                parentID: node.parentID,
                predictable: !node.isRetired,
                colorHex: node.colorHex
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
    public let model: LocalModelAsset?
    public let taxonomy: Taxonomy
    public let policies: [NamedPolicy]
    public let creatorClassifications: [CreatorClassificationRecord]

    public init(
        classifierType: ClassifierTypeAsset,
        model: LocalModelAsset?,
        taxonomy: Taxonomy,
        policies: [NamedPolicy],
        creatorClassifications: [CreatorClassificationRecord]
    ) {
        self.classifierType = classifierType
        self.model = model
        self.taxonomy = taxonomy
        self.policies = policies
        self.creatorClassifications = creatorClassifications
    }

    public func classify(_ entry: EntryEvidence) throws -> ClassificationResult {
        try EntryEvidenceValidator().validate(entry)

        let readableText = [entry.evidence.title, entry.evidence.summary, entry.evidence.text]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        // LLM-assisted creator decisions may deliberately use an active
        // parent tag when that classifier type does not restrict its prompt
        // to leaves. Local neural predictions remain leaf-only, but every
        // explicit creator decision still contributes to policy evaluation.
        let allowedTags = Set(taxonomy.nodes.values.filter(\.predictable).map(\.id))
        let creatorID = entry.sourceID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var signals = creatorSignals(
            platformID: entry.platform,
            creatorID: creatorID,
            allowedTags: allowedTags
        )

        var localScores = [String: Double]()
        if let neuralModel = model?.embeddedNeuralModel, !readableText.isEmpty {
            for prediction in neuralModel.predictions(for: readableText) {
                guard allowedTags.contains(prediction.labelID), prediction.probability.isFinite else { continue }
                let probability = min(1, max(0, prediction.probability))
                localScores[prediction.labelID] = probability
                signals[prediction.labelID, default: [:]][.localModel] = probability
            }
        }

        var scores: [TagScore] = signals.compactMap { tagID, sourceScores -> TagScore? in
            let weightedScores = sourceScores.compactMap { source, score -> (Double, Double)? in
                let weight = classifierType.decisionWeight(for: source)
                return weight > 0 ? (score, weight) : nil
            }
            let weightTotal = weightedScores.reduce(0) { $0 + $1.1 }
            guard weightTotal > 0 else { return nil }
            let finalScore = weightedScores.reduce(0) { $0 + ($1.0 * $1.1) } / weightTotal
            let directSignals = sourceScores.filter { $0.key != .localModel }
            let directWeightTotal = directSignals.reduce(0) { $0 + classifierType.decisionWeight(for: $1.key) }
            let sourceScore = directWeightTotal > 0
                ? directSignals.reduce(0) { $0 + ($1.value * classifierType.decisionWeight(for: $1.key)) } / directWeightTotal
                : nil
            return .init(tagID: tagID, directScore: localScores[tagID] ?? 0, sourceScore: sourceScore, finalScore: finalScore)
        }
        scores.sort { lhs, rhs in
            if lhs.finalScore == rhs.finalScore { return lhs.tagID < rhs.tagID }
            return lhs.finalScore > rhs.finalScore
        }
        scores = Array(scores.prefix(Self.maximumScores))
        let selected = scores
            .filter { $0.finalScore >= Self.threshold }
            .prefix(Self.maximumSelectedTags)
            .map { $0.tagID }
        let modelVersionParts = [
            !creatorID.isEmpty && creatorClassifications.contains(where: { $0.classifierTypeID == classifierType.id && $0.platformID == entry.platform && $0.creatorID == creatorID && $0.origin == .manual && $0.review == .approved }) ? "human" : nil,
            !creatorID.isEmpty && creatorClassifications.contains(where: { $0.classifierTypeID == classifierType.id && $0.platformID == entry.platform && $0.creatorID == creatorID && $0.origin == .llmAssist && $0.review == .approved }) ? "llm" : nil,
            model.map { "local-neural-\($0.id)-v\($0.version)" },
        ].compactMap { $0 }
        var result = ClassificationResult(
            entryID: entry.entryID,
            sourceID: entry.sourceID,
            surface: entry.surface,
            evidenceState: scores.isEmpty && readableText.isEmpty ? .limited : .sufficient,
            threshold: Self.threshold,
            selectedLeafTagIDs: selected,
            ancestorTagIDs: taxonomy.ancestorClosure(for: selected),
            scores: scores,
            decisions: [],
            packageID: "workspace-classifier-type-\(classifierType.id)",
            modelVersion: modelVersionParts.isEmpty ? "weighted-none" : modelVersionParts.joined(separator: "+")
        )
        result.decisions = PolicyEvaluator(taxonomy: taxonomy).evaluate(
            result: result,
            policies: policies,
            requestedPolicyIDs: entry.policyIDs
        )
        return result
    }

    /// Resolves only durable, approved creator decisions. Per-entry neural
    /// predictions are deliberately excluded because browser annotations
    /// describe the source, not a guess about one visible title.
    public func sourceTags(platformID: String, sourceID: String) -> [TagNode] {
        let allowedTags = Set(taxonomy.nodes.values.filter(\.predictable).map(\.id))
        let signals = creatorSignals(
            platformID: platformID,
            creatorID: sourceID,
            allowedTags: allowedTags
        )
        return signals.compactMap { tagID, sourceScores -> (TagNode, Double)? in
            let weightedScores = sourceScores.compactMap { source, score -> (Double, Double)? in
                let weight = classifierType.decisionWeight(for: source)
                return weight > 0 ? (score, weight) : nil
            }
            let weightTotal = weightedScores.reduce(0) { $0 + $1.1 }
            guard weightTotal > 0,
                  let node = taxonomy.nodes[tagID] else {
                return nil
            }
            let finalScore = weightedScores.reduce(0) { $0 + ($1.0 * $1.1) } / weightTotal
            return finalScore >= Self.threshold ? (node, finalScore) : nil
        }
        .sorted { lhs, rhs in
            if lhs.1 == rhs.1 { return lhs.0.id < rhs.0.id }
            return lhs.1 > rhs.1
        }
        .prefix(Self.maximumSelectedTags)
        .map(\.0)
    }

    private func creatorSignals(
        platformID: String,
        creatorID: String,
        allowedTags: Set<String>
    ) -> [String: [ClassifierDecisionSource: Double]] {
        guard !creatorID.isEmpty else { return [:] }
        var signals = [String: [ClassifierDecisionSource: Double]]()
        for classification in creatorClassifications where
            classification.classifierTypeID == classifierType.id &&
            classification.platformID == platformID &&
            classification.creatorID == creatorID &&
            classification.treeID == classifierType.treeID &&
            classification.treeRevision == classifierType.treeRevision &&
            classification.review == .approved {
            let source: ClassifierDecisionSource?
            switch classification.origin {
            case .manual: source = .human
            case .llmAssist: source = .llmAssist
            case .legacy: source = nil
            }
            guard let source else { continue }
            for tagID in classification.tagIDs where allowedTags.contains(tagID) {
                signals[tagID, default: [:]][source] = 1
            }
            for tagID in classification.negativeTagIDs where allowedTags.contains(tagID) {
                signals[tagID, default: [:]][source] = 0
            }
        }
        return signals
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
        let model: LocalModelAsset?
        if let modelID = classifierType.localModelID {
            guard binding.activeModelID == modelID,
                  let resolvedModel = models.first(where: { $0.id == modelID }),
                  resolvedModel.isReady,
                  resolvedModel.embeddedNeuralModel != nil,
                  resolvedModel.treeID == tree.id,
                  resolvedModel.treeRevision == tree.revision,
                  resolvedModel.datasetID == dataset.id,
                  resolvedModel.datasetRevision == dataset.revision else {
                throw WorkspaceClassifierError.missingLocalModel(classifierTypeID)
            }
            model = resolvedModel
        } else {
            model = nil
        }
        return .init(
            classifierType: classifierType,
            model: model,
            taxonomy: try tree.inferenceTaxonomy(),
            policies: policies,
            creatorClassifications: dataset.creatorClassifications
        )
    }
}
