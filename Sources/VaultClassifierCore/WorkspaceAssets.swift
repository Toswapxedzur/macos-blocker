import Foundation

/// User-owned assets behind the five Vault Classifier workspaces. These remain
/// local profile data; neither a browser nor a provider may mutate them.
public struct TagTreeNode: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var parentID: String?
    public var isRetired: Bool
    /// A node's local canvas coordinates are presentation data, separate from
    /// its semantic parent relation and tree revision.
    public var positionX: Double?
    public var positionY: Double?

    public init(id: String = UUID().uuidString, name: String, parentID: String? = nil, isRetired: Bool = false, positionX: Double? = nil, positionY: Double? = nil) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.isRetired = isRetired
        self.positionX = positionX
        self.positionY = positionY
    }

    /// The web canvas must always receive a concrete position. Legacy nodes
    /// predate free placement, so only those use this stable display fallback;
    /// an explicit zero remains a real user-authored coordinate.
    public func resolvedCanvasPosition(index: Int) -> TagTreeCanvasPosition {
        if let positionX, let positionY,
           positionX.isFinite, positionY.isFinite,
           positionX >= 0, positionY >= 0 {
            return .init(x: positionX, y: positionY)
        }
        return .init(x: 24 + Double(index % 4) * 154, y: 24 + Double(index / 4) * 48)
    }
}

public struct TagTreeCanvasPosition: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct TagTreeAsset: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var revision: Int
    public var nodes: [TagTreeNode]
    public var updatedAtMilliseconds: Int64

    public init(id: String = UUID().uuidString, name: String, revision: Int = 1, nodes: [TagTreeNode], updatedAtMilliseconds: Int64 = WorkspaceCatalog.now()) {
        self.id = id
        self.name = name
        self.revision = revision
        self.nodes = nodes
        self.updatedAtMilliseconds = updatedAtMilliseconds
    }

    /// Returns the selected node and every reachable descendant. The visited
    /// set also makes an invalid cyclic legacy tree safe to traverse.
    public func subtreeNodeIDs(rootID: String) -> Set<String> {
        guard nodes.contains(where: { $0.id == rootID }) else { return [] }
        var nodeIDs: Set<String> = []
        var pendingIDs = [rootID]

        while let nodeID = pendingIDs.popLast(), nodeIDs.insert(nodeID).inserted {
            pendingIDs.append(contentsOf: nodes.compactMap { node in
                node.parentID == nodeID ? node.id : nil
            })
        }
        return nodeIDs
    }
}

public enum ClassificationRecordOrigin: String, Codable, Sendable, CaseIterable {
    case manual
    case llmAssist
    case legacy
}

public enum ClassificationReviewStatus: String, Codable, Sendable, CaseIterable {
    case approved
    case pending
    case rejected
}

public struct ClassificationRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var tagIDs: [String]
    public var origin: ClassificationRecordOrigin
    public var review: ClassificationReviewStatus
    public var platformID: String
    public var treeRevision: Int
    public var modelVersion: String?
    public var supersedesID: String?
    public var createdAtMilliseconds: Int64

    public init(id: String = UUID().uuidString, title: String, tagIDs: [String], origin: ClassificationRecordOrigin, review: ClassificationReviewStatus, platformID: String, treeRevision: Int, modelVersion: String? = nil, supersedesID: String? = nil, createdAtMilliseconds: Int64 = WorkspaceCatalog.now()) {
        self.id = id
        self.title = title
        self.tagIDs = tagIDs.sorted()
        self.origin = origin
        self.review = review
        self.platformID = platformID
        self.treeRevision = treeRevision
        self.modelVersion = modelVersion
        self.supersedesID = supersedesID
        self.createdAtMilliseconds = createdAtMilliseconds
    }
}

public struct ClassificationDataset: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var records: [ClassificationRecord]
    public var revision: Int

    public init(id: String = UUID().uuidString, name: String, records: [ClassificationRecord] = [], revision: Int = 1) {
        self.id = id
        self.name = name
        self.records = records
        self.revision = revision
    }
}

/// Optional base packages that a local model may be configured to use. The
/// identifier is deliberately a package identity, not a provider endpoint or
/// credential. Selecting one stays local and is safe to persist before its
/// package is available on this Mac.
public enum LocalBaseEmbedding: String, Codable, Sendable, CaseIterable {
    case allMiniLML6V2 = "all-MiniLM-L6-v2"
    case allMPNetBaseV2 = "all-mpnet-base-v2"
    case multilingualE5Small = "multilingual-e5-small"
    case multilingualE5Base = "multilingual-e5-base"
    case multilingualE5Large = "multilingual-e5-large"
    case bgeM3 = "bge-m3"
}

public struct LocalModelAsset: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var treeID: String
    public var treeRevision: Int
    public var datasetID: String
    public var datasetRevision: Int
    public var version: Int
    public var isReady: Bool
    /// The browser platform whose approved records this model trains on. A
    /// model remains a reusable asset; this only scopes its training corpus.
    public var trainingPlatformID: String?
    /// `nil` means use the compact on-device embedding learned from the local
    /// corpus. A non-nil value records the requested downloadable base package.
    public var baseEmbeddingID: LocalBaseEmbedding?
    /// The trained local artifact is persisted with the model asset so an
    /// explicit run survives an app restart without any server dependency.
    public var embeddedNeuralModel: EmbeddedNeuralTextClassifier?
    public var embeddedTrainingReport: EmbeddedNeuralTrainingReport?
    public var trainedAtMilliseconds: Int64?

    public init(id: String = UUID().uuidString, name: String, treeID: String, treeRevision: Int, datasetID: String, datasetRevision: Int, version: Int = 1, isReady: Bool = false, trainingPlatformID: String? = nil, baseEmbeddingID: LocalBaseEmbedding? = nil, embeddedNeuralModel: EmbeddedNeuralTextClassifier? = nil, embeddedTrainingReport: EmbeddedNeuralTrainingReport? = nil, trainedAtMilliseconds: Int64? = nil) {
        self.id = id
        self.name = name
        self.treeID = treeID
        self.treeRevision = treeRevision
        self.datasetID = datasetID
        self.datasetRevision = datasetRevision
        self.version = version
        self.isReady = isReady
        self.trainingPlatformID = trainingPlatformID
        self.baseEmbeddingID = baseEmbeddingID
        self.embeddedNeuralModel = embeddedNeuralModel
        self.embeddedTrainingReport = embeddedTrainingReport
        self.trainedAtMilliseconds = trainedAtMilliseconds
    }
}

public enum LocalModelTrainingError: Error, Equatable, LocalizedError, Sendable {
    case incompatibleTree
    case incompatibleDataset
    case missingPlatform
    case noApprovedExamples

    public var errorDescription: String? {
        switch self {
        case .incompatibleTree:
            return "The local model is not configured for this tag tree revision."
        case .incompatibleDataset:
            return "The local model is not configured for this classification dataset revision."
        case .missingPlatform:
            return "Choose a classification-data platform before training this local model."
        case .noApprovedExamples:
            return "Add approved manual or LLM-assisted labels for this tree and platform before training."
        }
    }
}

/// Converts immutable, approved classification rows into on-device neural
/// samples. It never treats browsing activity, pending LLM suggestions, legacy
/// imports, or labels from another tree revision as training data.
public enum LocalModelTrainer {
    public static let defaultEpochs = 48

    public static func approvedExamples(
        for tree: TagTreeAsset,
        dataset: ClassificationDataset,
        platformID: String
    ) -> [EmbeddedNeuralTrainingExample] {
        let availableTagIDs = Set(tree.nodes.lazy.filter { !$0.isRetired }.map(\.id))
        return dataset.records.compactMap { record in
            guard record.review == .approved,
                  record.origin == .manual || record.origin == .llmAssist,
                  record.platformID == platformID,
                  record.treeRevision == tree.revision,
                  !record.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            let positiveLabelIDs = record.tagIDs.filter { availableTagIDs.contains($0) }
            guard !positiveLabelIDs.isEmpty else { return nil }
            return .init(text: record.title, positiveLabelIDs: positiveLabelIDs)
        }
    }

    public static func train(
        _ model: LocalModelAsset,
        tree: TagTreeAsset,
        dataset: ClassificationDataset,
        epochs: Int = defaultEpochs,
        configuration: EmbeddedNeuralModelConfiguration = .init()
    ) throws -> LocalModelAsset {
        guard model.treeID == tree.id, model.treeRevision == tree.revision else {
            throw LocalModelTrainingError.incompatibleTree
        }
        guard model.datasetID == dataset.id, model.datasetRevision == dataset.revision else {
            throw LocalModelTrainingError.incompatibleDataset
        }
        guard let platformID = model.trainingPlatformID, !platformID.isEmpty else {
            throw LocalModelTrainingError.missingPlatform
        }
        let examples = approvedExamples(for: tree, dataset: dataset, platformID: platformID)
        let labelIDs = Array(Set(examples.flatMap(\.positiveLabelIDs))).sorted()
        guard !examples.isEmpty, !labelIDs.isEmpty else {
            throw LocalModelTrainingError.noApprovedExamples
        }

        var classifier = try EmbeddedNeuralTextClassifier(
            configuration: configuration,
            labelIDs: labelIDs,
            trainingExamples: examples
        )
        let report = try classifier.train(examples, epochs: epochs)
        var trained = model
        trained.version += 1
        trained.isReady = true
        trained.embeddedNeuralModel = classifier
        trained.embeddedTrainingReport = report
        trained.trainedAtMilliseconds = WorkspaceCatalog.now()
        return trained
    }
}

public struct PlatformBinding: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var browser: String
    public var treeID: String
    public var datasetID: String
    public var activeModelID: String?
    public var policyID: String?

    public init(id: String = "youtube", name: String = "YouTube", browser: String = "Chrome and Edge", treeID: String, datasetID: String, activeModelID: String? = nil, policyID: String? = nil) {
        self.id = id
        self.name = name
        self.browser = browser
        self.treeID = treeID
        self.datasetID = datasetID
        self.activeModelID = activeModelID
        self.policyID = policyID
    }
}

public struct TokenUsageRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var provider: String
    public var model: String
    public var inputTokens: Int
    public var outputTokens: Int
    public var status: String
    public var createdAtMilliseconds: Int64

    public init(id: String = UUID().uuidString, provider: String, model: String, inputTokens: Int, outputTokens: Int, status: String, createdAtMilliseconds: Int64 = WorkspaceCatalog.now()) {
        self.id = id
        self.provider = provider
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.status = status
        self.createdAtMilliseconds = createdAtMilliseconds
    }
}

public enum WorkspaceCatalogError: Error, Equatable, LocalizedError, Sendable {
    case duplicateIdentifier(String)
    case missingTree(String)
    case missingDataset(String)
    case missingModel(String)
    case incompatibleActiveModel(String)

    public var errorDescription: String? {
        switch self {
        case .duplicateIdentifier(let value): return "Duplicate local asset identifier: \(value)."
        case .missingTree(let value): return "The platform binding references a missing tag tree: \(value)."
        case .missingDataset(let value): return "The platform binding references a missing classification dataset: \(value)."
        case .missingModel(let value): return "The platform binding references a missing local model: \(value)."
        case .incompatibleActiveModel(let value): return "The active local model is not compatible with the platform tree and dataset: \(value)."
        }
    }
}

public struct WorkspaceCatalog: Codable, Equatable, Sendable {
    public var trees: [TagTreeAsset]
    public var datasets: [ClassificationDataset]
    public var models: [LocalModelAsset]
    public var bindings: [PlatformBinding]
    public var tokenUsage: [TokenUsageRecord]

    public init(trees: [TagTreeAsset] = [], datasets: [ClassificationDataset] = [], models: [LocalModelAsset] = [], bindings: [PlatformBinding] = [], tokenUsage: [TokenUsageRecord] = []) {
        self.trees = trees
        self.datasets = datasets
        self.models = models
        self.bindings = bindings
        self.tokenUsage = tokenUsage
    }

    public static func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1_000) }

    public static func starter() -> WorkspaceCatalog {
        // A personal tree begins as an empty canvas. The Vault taxonomy remains
        // an optional import rather than an imposed first node or hierarchy.
        let tree = TagTreeAsset(id: "vault-starter", name: "Vault starter tree", nodes: [])
        let dataset = ClassificationDataset(id: "local-dataset", name: "Local classification data")
        let model = LocalModelAsset(id: "local-neural-model", name: "Local neural model", treeID: tree.id, treeRevision: tree.revision, datasetID: dataset.id, datasetRevision: dataset.revision, trainingPlatformID: "youtube")
        return .init(trees: [tree], datasets: [dataset], models: [model], bindings: [.init(treeID: tree.id, datasetID: dataset.id)])
    }

    public func validate() throws {
        try unique(trees.map(\.id) + datasets.map(\.id) + models.map(\.id) + bindings.map(\.id))
        for binding in bindings {
            guard let tree = trees.first(where: { $0.id == binding.treeID }) else { throw WorkspaceCatalogError.missingTree(binding.treeID) }
            guard let dataset = datasets.first(where: { $0.id == binding.datasetID }) else { throw WorkspaceCatalogError.missingDataset(binding.datasetID) }
            guard let activeModelID = binding.activeModelID else { continue }
            guard let model = models.first(where: { $0.id == activeModelID }) else { throw WorkspaceCatalogError.missingModel(activeModelID) }
            guard model.isReady, model.treeID == tree.id, model.treeRevision == tree.revision, model.datasetID == dataset.id, model.datasetRevision == dataset.revision else {
                throw WorkspaceCatalogError.incompatibleActiveModel(activeModelID)
            }
        }
    }

    private func unique(_ identifiers: [String]) throws {
        guard Set(identifiers).count == identifiers.count else {
            throw WorkspaceCatalogError.duplicateIdentifier("workspace catalog")
        }
    }
}
