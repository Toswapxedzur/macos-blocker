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

/// A local credential profile describes how the user intends to use a provider.
/// It deliberately carries configuration only: the secret itself is stored in
/// Keychain and never becomes part of the workspace catalog or a web snapshot.
public enum APIKeyProviderType: String, Codable, Sendable, CaseIterable {
    case chatGPT
    case gemini
    case deepSeek
    case youtubeData
    case claude
    case mistral
    case cohere
    case groq
    case xAI
    case perplexity
    case openRouter
    case togetherAI
    case fireworksAI
    case huggingFace
    case replicate
    case azureOpenAI
    case awsBedrock
    case googleVertexAI
    case cloudflareWorkersAI
    case nvidiaNIM
    case cerebras
    case sambaNova
    case ai21
    case voyageAI
    case jinaAI
    case ollama
    case twitch
    case reddit
    case discord
    case xPlatform
    case tikTok
    case instagramGraph
    case facebookGraph
    case linkedIn
    case pinterest
    case bluesky
    case mastodon
    case vimeo
    case dailyMotion
    case spotify
    case soundCloud
    case steam
    case github
    case gitlab
    case slack
    case telegram
    case notion
    case microsoftGraph
    case braveSearch
    case tavily
    case serpAPI
    case firecrawl
    case googleCustomSearch
    case bingWebSearch
    case custom

    public var supportsLLMConfiguration: Bool {
        ProviderProtocolRegistry.descriptor(for: self).supportsLLMConfiguration
    }

    /// These compatibility values remain decodable only so an owner can
    /// remove an old profile. New UI or bridge input must not create them.
    public var isSelectableProfileType: Bool {
        switch self {
        case .discord, .github, .gitlab, .slack, .telegram, .notion, .microsoftGraph:
            return false
        default:
            return true
        }
    }

    public var defaultProfileName: String {
        switch self {
        case .chatGPT: return "ChatGPT key"
        case .gemini: return "Gemini key"
        case .deepSeek: return "DeepSeek key"
        case .youtubeData: return "YouTube Data API key"
        case .claude: return "Claude key"
        case .mistral: return "Mistral key"
        case .cohere: return "Cohere key"
        case .groq: return "Groq key"
        case .xAI: return "xAI key"
        case .perplexity: return "Perplexity key"
        case .openRouter: return "OpenRouter key"
        case .togetherAI: return "Together AI key"
        case .fireworksAI: return "Fireworks AI key"
        case .huggingFace: return "Hugging Face key"
        case .replicate: return "Replicate key"
        case .azureOpenAI: return "Azure OpenAI key"
        case .awsBedrock: return "AWS Bedrock key"
        case .googleVertexAI: return "Google Vertex AI key"
        case .cloudflareWorkersAI: return "Cloudflare Workers AI key"
        case .nvidiaNIM: return "NVIDIA NIM key"
        case .cerebras: return "Cerebras key"
        case .sambaNova: return "SambaNova key"
        case .ai21: return "AI21 key"
        case .voyageAI: return "Voyage AI key"
        case .jinaAI: return "Jina AI key"
        case .ollama: return "Ollama profile"
        case .twitch: return "Twitch credential"
        case .reddit: return "Reddit credential"
        case .discord: return "Discord credential"
        case .xPlatform: return "X credential"
        case .tikTok: return "TikTok credential"
        case .instagramGraph: return "Instagram Graph credential"
        case .facebookGraph: return "Facebook Graph credential"
        case .linkedIn: return "LinkedIn credential"
        case .pinterest: return "Pinterest credential"
        case .bluesky: return "Bluesky credential"
        case .mastodon: return "Mastodon credential"
        case .vimeo: return "Vimeo credential"
        case .dailyMotion: return "Dailymotion credential"
        case .spotify: return "Spotify credential"
        case .soundCloud: return "SoundCloud credential"
        case .steam: return "Steam Web API key"
        case .github: return "GitHub credential"
        case .gitlab: return "GitLab credential"
        case .slack: return "Slack credential"
        case .telegram: return "Telegram bot token"
        case .notion: return "Notion credential"
        case .microsoftGraph: return "Microsoft Graph credential"
        case .braveSearch: return "Brave Search API key"
        case .tavily: return "Tavily API key"
        case .serpAPI: return "SerpAPI key"
        case .firecrawl: return "Firecrawl API key"
        case .googleCustomSearch: return "Google Custom Search key"
        case .bingWebSearch: return "Bing Web Search key"
        case .custom: return "Custom API key"
        }
    }

    public var defaultModelIdentifier: String {
        switch self {
        case .chatGPT: return "gpt-4.1-mini"
        case .gemini: return "gemini-3.1-flash-lite"
        case .deepSeek: return "deepseek-chat"
        case .claude: return "claude-sonnet-4-5"
        case .mistral: return "mistral-large-latest"
        case .cohere: return "command-a-plus-05-2026"
        case .groq: return "llama-3.3-70b-versatile"
        case .xAI: return "grok-4.5"
        case .perplexity: return "sonar"
        case .openRouter: return "openai/gpt-4.1-mini"
        case .togetherAI: return "meta-llama/Llama-3.3-70B-Instruct-Turbo"
        case .fireworksAI: return "accounts/fireworks/models/llama-v3p3-70b-instruct"
        case .huggingFace: return "meta-llama/Llama-3.3-70B-Instruct"
        case .replicate: return "meta/meta-llama-3-70b-instruct"
        case .azureOpenAI: return "gpt-4.1-mini"
        case .awsBedrock: return "anthropic.claude-sonnet-4-5-20250929-v1:0"
        case .googleVertexAI: return "gemini-3.1-flash-lite"
        case .cloudflareWorkersAI: return "@cf/meta/llama-3.3-70b-instruct-fp8-fast"
        case .nvidiaNIM: return "meta/llama-3.3-70b-instruct"
        case .cerebras: return "gpt-oss-120b"
        case .sambaNova: return "Meta-Llama-3.3-70B-Instruct"
        case .ai21: return "jamba-large-1.7"
        case .voyageAI: return "voyage-4"
        case .jinaAI: return "jina-embeddings-v4"
        case .ollama: return "llama3.3"
        case .youtubeData, .twitch, .reddit, .discord, .xPlatform, .tikTok,
             .instagramGraph, .facebookGraph, .linkedIn, .pinterest, .bluesky,
             .mastodon, .vimeo, .dailyMotion, .spotify, .soundCloud, .steam,
             .github, .gitlab, .slack, .telegram, .notion, .microsoftGraph,
             .braveSearch, .tavily, .serpAPI, .firecrawl, .googleCustomSearch,
             .bingWebSearch: return ""
        case .custom: return "custom-model"
        }
    }
}

public struct APIKeyProviderProfile: Codable, Equatable, Sendable, Identifiable {
    public static let maximumNameLength = 128
    public static let maximumModelIdentifierLength = 256
    public static let maximumEndpointLength = 2_048
    public static let maximumBatchSize = 256
    public static let maximumTokenLimit = 1_000_000

    public var id: String
    public var name: String
    public var type: APIKeyProviderType
    /// This is relevant only for LLM provider types. A YouTube Data API profile
    /// remains a credential-only external-tool entry.
    public var modelIdentifier: String
    public var batchSize: Int
    public var maximumTokens: Int
    public var youtubeProviderID: String?
    public var searchEnabled: Bool
    /// An optional endpoint override supports compatible cloud, self-hosted,
    /// and custom entries. It is configuration only; this source slice makes
    /// no network dispatch.
    public var customEndpoint: String?
    /// Non-secret protocol settings such as cloud account, region, or API
    /// version. The versioned descriptor controls which keys are allowed.
    public var protocolConfiguration: [String: String]
    public var updatedAtMilliseconds: Int64

    public init(
        id: String = UUID().uuidString,
        name: String? = nil,
        type: APIKeyProviderType,
        modelIdentifier: String? = nil,
        batchSize: Int = 1,
        maximumTokens: Int = 1_024,
        youtubeProviderID: String? = nil,
        searchEnabled: Bool = false,
        customEndpoint: String? = nil,
        protocolConfiguration: [String: String]? = nil,
        updatedAtMilliseconds: Int64 = WorkspaceCatalog.now()
    ) {
        self.id = id
        self.name = name ?? type.defaultProfileName
        self.type = type
        self.modelIdentifier = modelIdentifier ?? type.defaultModelIdentifier
        self.batchSize = batchSize
        self.maximumTokens = maximumTokens
        self.youtubeProviderID = youtubeProviderID
        self.searchEnabled = searchEnabled
        self.customEndpoint = customEndpoint
        self.protocolConfiguration = protocolConfiguration ?? ProviderProtocolRegistry.descriptor(for: type).defaultConfiguration()
        self.updatedAtMilliseconds = updatedAtMilliseconds
    }

    public func validate() throws {
        let cleanedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, id.count <= 128,
              !cleanedName.isEmpty, cleanedName.count <= Self.maximumNameLength,
              batchSize > 0, batchSize <= Self.maximumBatchSize,
              maximumTokens > 0, maximumTokens <= Self.maximumTokenLimit else {
            throw APIKeyProviderProfileError.invalidConfiguration
        }

        let descriptor = ProviderProtocolRegistry.descriptor(for: type)
        if descriptor.supportsLLMConfiguration {
            let cleanedModel = modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanedModel.isEmpty, cleanedModel.count <= Self.maximumModelIdentifierLength else {
                throw APIKeyProviderProfileError.invalidConfiguration
            }
        } else if !modelIdentifier.isEmpty || youtubeProviderID != nil || searchEnabled || (customEndpoint != nil && !descriptor.allowsEndpointOverride) {
            throw APIKeyProviderProfileError.invalidConfiguration
        }

        let normalizedEndpoint = customEndpoint?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedEndpoint?.count ?? 0 <= Self.maximumEndpointLength else {
            throw APIKeyProviderProfileError.invalidConfiguration
        }
        do {
            try descriptor.validateConfiguration(protocolConfiguration, endpointOverride: normalizedEndpoint, requireDispatchReadiness: false)
        } catch {
            throw APIKeyProviderProfileError.invalidConfiguration
        }
    }

    /// Used by an explicit future provider run before it asks Keychain for a
    /// credential. Editing a profile intentionally permits incomplete values.
    public func validateForDispatch() throws {
        try validate()
        do {
            try ProviderProtocolRegistry.descriptor(for: type).validateConfiguration(
                protocolConfiguration,
                endpointOverride: customEndpoint,
                requireDispatchReadiness: true
            )
        } catch {
            throw APIKeyProviderProfileError.invalidConfiguration
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, type, modelIdentifier, batchSize, maximumTokens, youtubeProviderID, searchEnabled, customEndpoint, protocolConfiguration, updatedAtMilliseconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        type = try container.decode(APIKeyProviderType.self, forKey: .type)
        modelIdentifier = try container.decodeIfPresent(String.self, forKey: .modelIdentifier) ?? type.defaultModelIdentifier
        batchSize = try container.decodeIfPresent(Int.self, forKey: .batchSize) ?? 1
        maximumTokens = try container.decodeIfPresent(Int.self, forKey: .maximumTokens) ?? 1_024
        youtubeProviderID = try container.decodeIfPresent(String.self, forKey: .youtubeProviderID)
        searchEnabled = try container.decodeIfPresent(Bool.self, forKey: .searchEnabled) ?? false
        customEndpoint = try container.decodeIfPresent(String.self, forKey: .customEndpoint)
        protocolConfiguration = try container.decodeIfPresent([String: String].self, forKey: .protocolConfiguration)
            ?? ProviderProtocolRegistry.descriptor(for: type).defaultConfiguration()
        updatedAtMilliseconds = try container.decodeIfPresent(Int64.self, forKey: .updatedAtMilliseconds) ?? WorkspaceCatalog.now()
    }
}

public enum APIKeyProviderProfileError: Error, Equatable, LocalizedError, Sendable {
    case invalidConfiguration

    public var errorDescription: String? {
        "The provider profile configuration is invalid."
    }
}

public enum WorkspaceCatalogError: Error, Equatable, LocalizedError, Sendable {
    case duplicateIdentifier(String)
    case missingTree(String)
    case missingDataset(String)
    case missingModel(String)
    case incompatibleActiveModel(String)
    case invalidProviderProfile(String)
    case missingYouTubeProvider(String)

    public var errorDescription: String? {
        switch self {
        case .duplicateIdentifier(let value): return "Duplicate local asset identifier: \(value)."
        case .missingTree(let value): return "The platform binding references a missing tag tree: \(value)."
        case .missingDataset(let value): return "The platform binding references a missing classification dataset: \(value)."
        case .missingModel(let value): return "The platform binding references a missing local model: \(value)."
        case .incompatibleActiveModel(let value): return "The active local model is not compatible with the platform tree and dataset: \(value)."
        case .invalidProviderProfile(let value): return "The API provider profile is invalid: \(value)."
        case .missingYouTubeProvider(let value): return "The LLM profile references a missing YouTube Data API profile: \(value)."
        }
    }
}

public struct WorkspaceCatalog: Codable, Equatable, Sendable {
    public var trees: [TagTreeAsset]
    public var datasets: [ClassificationDataset]
    public var models: [LocalModelAsset]
    public var bindings: [PlatformBinding]
    public var tokenUsage: [TokenUsageRecord]
    /// Provider profile metadata remains local. Its credentials are stored by
    /// `ProviderCredentialStore` in Keychain, never in this Codable catalog.
    public var providerProfiles: [APIKeyProviderProfile]

    public init(trees: [TagTreeAsset] = [], datasets: [ClassificationDataset] = [], models: [LocalModelAsset] = [], bindings: [PlatformBinding] = [], tokenUsage: [TokenUsageRecord] = [], providerProfiles: [APIKeyProviderProfile] = []) {
        self.trees = trees
        self.datasets = datasets
        self.models = models
        self.bindings = bindings
        self.tokenUsage = tokenUsage
        self.providerProfiles = providerProfiles
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
        try unique(trees.map(\.id) + datasets.map(\.id) + models.map(\.id) + bindings.map(\.id) + providerProfiles.map(\.id))
        for binding in bindings {
            guard let tree = trees.first(where: { $0.id == binding.treeID }) else { throw WorkspaceCatalogError.missingTree(binding.treeID) }
            guard let dataset = datasets.first(where: { $0.id == binding.datasetID }) else { throw WorkspaceCatalogError.missingDataset(binding.datasetID) }
            guard let activeModelID = binding.activeModelID else { continue }
            guard let model = models.first(where: { $0.id == activeModelID }) else { throw WorkspaceCatalogError.missingModel(activeModelID) }
            guard model.isReady, model.treeID == tree.id, model.treeRevision == tree.revision, model.datasetID == dataset.id, model.datasetRevision == dataset.revision else {
                throw WorkspaceCatalogError.incompatibleActiveModel(activeModelID)
            }
        }
        for profile in providerProfiles {
            do {
                try profile.validate()
            } catch {
                throw WorkspaceCatalogError.invalidProviderProfile(profile.id)
            }
            guard let youtubeProviderID = profile.youtubeProviderID else { continue }
            guard profile.type.supportsLLMConfiguration,
                  providerProfiles.contains(where: { $0.id == youtubeProviderID && $0.type == .youtubeData }) else {
                throw WorkspaceCatalogError.missingYouTubeProvider(youtubeProviderID)
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case trees, datasets, models, bindings, tokenUsage, providerProfiles
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        trees = try container.decodeIfPresent([TagTreeAsset].self, forKey: .trees) ?? []
        datasets = try container.decodeIfPresent([ClassificationDataset].self, forKey: .datasets) ?? []
        models = try container.decodeIfPresent([LocalModelAsset].self, forKey: .models) ?? []
        bindings = try container.decodeIfPresent([PlatformBinding].self, forKey: .bindings) ?? []
        tokenUsage = try container.decodeIfPresent([TokenUsageRecord].self, forKey: .tokenUsage) ?? []
        providerProfiles = try container.decodeIfPresent([APIKeyProviderProfile].self, forKey: .providerProfiles) ?? []
    }

    private func unique(_ identifiers: [String]) throws {
        guard Set(identifiers).count == identifiers.count else {
            throw WorkspaceCatalogError.duplicateIdentifier("workspace catalog")
        }
    }
}
