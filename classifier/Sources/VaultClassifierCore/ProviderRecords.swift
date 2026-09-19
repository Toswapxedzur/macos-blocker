import Foundation

// Persisted cloud-provider state: token usage, request/test records, credentials and API-key profiles (the research lane's data; execution lives elsewhere).
// (Split out of the former WorkspaceAssets.swift; CLASSIFIER-INDEPENDENCE §7.)

private func nonnegativeSaturatingSum(_ lhs: Int, _ rhs: Int) -> Int {
    let addition = max(0, lhs).addingReportingOverflow(max(0, rhs))
    return addition.overflow ? Int.max : addition.partialValue
}

public struct TokenUsageRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var provider: String
    public var model: String
    public var tokenCount: Int
    public var status: String
    /// Grounded-research budgets are independent for each classifier type.
    /// Nil identifies legacy/global records and remains readable.
    public var classifierTypeID: String?
    public var createdAtMilliseconds: Int64

    public init(id: String = UUID().uuidString, provider: String, model: String, tokenCount: Int, status: String, classifierTypeID: String? = nil, createdAtMilliseconds: Int64 = WorkspaceCatalog.now()) {
        self.id = id
        self.provider = provider
        self.model = model
        self.tokenCount = max(0, tokenCount)
        self.status = status
        self.classifierTypeID = classifierTypeID
        self.createdAtMilliseconds = createdAtMilliseconds
    }

    private enum CodingKeys: String, CodingKey {
        case id, provider, model, tokenCount, status, classifierTypeID, createdAtMilliseconds
        case inputTokens, outputTokens
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        provider = try container.decode(String.self, forKey: .provider)
        model = try container.decode(String.self, forKey: .model)
        if let aggregate = try container.decodeIfPresent(Int.self, forKey: .tokenCount) {
            tokenCount = max(0, aggregate)
        } else {
            tokenCount = nonnegativeSaturatingSum(
                try container.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0,
                try container.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
            )
        }
        status = try container.decode(String.self, forKey: .status)
        classifierTypeID = try container.decodeIfPresent(String.self, forKey: .classifierTypeID)
        createdAtMilliseconds = try container.decode(Int64.self, forKey: .createdAtMilliseconds)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(provider, forKey: .provider)
        try container.encode(model, forKey: .model)
        try container.encode(tokenCount, forKey: .tokenCount)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(classifierTypeID, forKey: .classifierTypeID)
        try container.encode(createdAtMilliseconds, forKey: .createdAtMilliseconds)
    }
}

/// A bounded local ledger for explicit provider requests. It tracks only the
/// outcome and token accounting. A parser failure may retain a bounded
/// response-shape summary made only from structural field names and counts;
/// credentials, headers, request text, and response text are never retained.
public struct ProviderRequestRecord: Codable, Equatable, Sendable, Identifiable {
    /// Cap on the stored response-shape summary; the test protocol trims to it too.
    public static let maximumResponseShapeCharacters = 256
    public var id: String
    public var profileID: String
    public var provider: String
    public var model: String
    public var operation: String
    public var endpoint: String
    public var method: String
    public var statusCode: Int?
    /// A redacted JSON-envelope description for a 2xx response that could not
    /// be parsed. It never contains response values or text.
    public var responseShape: String?
    public var durationMilliseconds: Int
    public var tokenCount: Int?
    /// Nil for connection tests. LLM classification runs identify the one
    /// classifier type whose daily aggregate allowance they consume.
    public var classifierTypeID: String?
    public var outcome: String
    public var createdAtMilliseconds: Int64

    public init(
        id: String = UUID().uuidString,
        profileID: String,
        provider: String,
        model: String,
        operation: String,
        endpoint: String,
        method: String,
        statusCode: Int?,
        responseShape: String? = nil,
        durationMilliseconds: Int,
        tokenCount: Int?,
        classifierTypeID: String? = nil,
        outcome: String,
        createdAtMilliseconds: Int64 = WorkspaceCatalog.now()
    ) {
        self.id = id
        self.profileID = profileID
        self.provider = provider
        self.model = model
        self.operation = operation
        self.endpoint = endpoint
        self.method = method
        self.statusCode = statusCode
        let cleanedResponseShape = responseShape?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.responseShape = cleanedResponseShape.isEmpty ? nil : String(cleanedResponseShape.prefix(ProviderRequestRecord.maximumResponseShapeCharacters))
        self.durationMilliseconds = durationMilliseconds
        self.tokenCount = tokenCount.map { max(0, $0) }
        let cleanedClassifierTypeID = classifierTypeID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.classifierTypeID = cleanedClassifierTypeID.isEmpty ? nil : cleanedClassifierTypeID
        self.outcome = outcome
        self.createdAtMilliseconds = createdAtMilliseconds
    }

    private enum CodingKeys: String, CodingKey {
        case id, profileID, provider, model, operation, endpoint, method,
             statusCode, responseShape, durationMilliseconds, tokenCount,
             classifierTypeID, outcome, createdAtMilliseconds
        case inputTokens, outputTokens
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        profileID = try container.decode(String.self, forKey: .profileID)
        provider = try container.decode(String.self, forKey: .provider)
        model = try container.decode(String.self, forKey: .model)
        operation = try container.decode(String.self, forKey: .operation)
        endpoint = try container.decode(String.self, forKey: .endpoint)
        method = try container.decode(String.self, forKey: .method)
        statusCode = try container.decodeIfPresent(Int.self, forKey: .statusCode)
        responseShape = try container.decodeIfPresent(String.self, forKey: .responseShape)
        durationMilliseconds = try container.decode(Int.self, forKey: .durationMilliseconds)
        if let aggregate = try container.decodeIfPresent(Int.self, forKey: .tokenCount) {
            tokenCount = max(0, aggregate)
        } else {
            let input = try container.decodeIfPresent(Int.self, forKey: .inputTokens)
            let output = try container.decodeIfPresent(Int.self, forKey: .outputTokens)
            tokenCount = input == nil && output == nil
                ? nil
                : nonnegativeSaturatingSum(input ?? 0, output ?? 0)
        }
        classifierTypeID = try container.decodeIfPresent(String.self, forKey: .classifierTypeID)
        outcome = try container.decode(String.self, forKey: .outcome)
        createdAtMilliseconds = try container.decode(Int64.self, forKey: .createdAtMilliseconds)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(profileID, forKey: .profileID)
        try container.encode(provider, forKey: .provider)
        try container.encode(model, forKey: .model)
        try container.encode(operation, forKey: .operation)
        try container.encode(endpoint, forKey: .endpoint)
        try container.encode(method, forKey: .method)
        try container.encodeIfPresent(statusCode, forKey: .statusCode)
        try container.encodeIfPresent(responseShape, forKey: .responseShape)
        try container.encode(durationMilliseconds, forKey: .durationMilliseconds)
        try container.encodeIfPresent(tokenCount, forKey: .tokenCount)
        try container.encodeIfPresent(classifierTypeID, forKey: .classifierTypeID)
        try container.encode(outcome, forKey: .outcome)
        try container.encode(createdAtMilliseconds, forKey: .createdAtMilliseconds)
    }
}

/// A normalized provider key or token used to build an explicit provider
/// request. Its storage and presentation are owned by `APIKeyProviderProfile`.
public struct ProviderCredentialRecord: Codable, Equatable, Sendable {
    public static let maximumCharacters = 2_048

    public var values: [ProviderCredentialField: String]

    public init(values: [ProviderCredentialField: String]) {
        self.values = Dictionary(uniqueKeysWithValues: values.map { field, value in
            (field, value.trimmingCharacters(in: .whitespacesAndNewlines))
        })
    }

    public func validate(for descriptor: ProviderProtocolDescriptor) throws {
        guard Set(values.keys) == Set(descriptor.credentialFields) else {
            throw ProviderCredentialError.invalidCredential
        }
        for field in descriptor.credentialFields {
            guard let value = values[field], Self.isValid(value) else {
                throw ProviderCredentialError.missingCredential(field)
            }
        }
    }

    public static func isValid(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= maximumCharacters else { return false }
        return value.unicodeScalars.allSatisfy { $0.properties.generalCategory != .control }
    }
}

public enum ProviderCredentialError: Error, LocalizedError, Sendable {
    case invalidCredential
    case missingCredential(ProviderCredentialField)

    public var errorDescription: String? {
        switch self {
        case .invalidCredential: return "The provider credential is malformed."
        case .missingCredential: return "Enter a valid API key or token."
        }
    }
}

/// A local provider profile includes its ordinary saved API key or token plus
/// the connection settings needed for the selected provider protocol.
public enum APIKeyProviderType: String, Codable, Sendable, CaseIterable {
    case openAI
    case openAICompatible
    case deepSeek
    case gemini
    case anthropic
    case mistral
    case cohere
    case groq
    case openRouter
    case ollama
    case youtubeData
    case twitch
    case reddit
    case xPlatform
    case tikTok
    case instagramGraph
    case facebookGraph
    case serper
    case youSearch
    case custom

    public var supportsLLMConfiguration: Bool {
        ProviderProtocolRegistry.descriptor(for: self).supportsLLMConfiguration
    }

    /// Serper / You.com: retired with the raw-search research mode (kept decodable).
    public var isRetiredSearchProvider: Bool {
        ProviderProtocolRegistry.descriptor(for: self).isRetiredSearchProvider
    }

    /// A provider-native search invocation has an explicit request grammar in
    /// this app. Do not advertise search merely because a provider's separate
    /// consumer product or agent integration can browse the web.
    public var supportsProviderNativeWebSearch: Bool {
        switch self {
        case .openAI, .gemini, .anthropic:
            return true
        default:
            return false
        }
    }

    /// Standard provider integrations whose documented generation grammar
    /// supports client-executed function calls. Custom and generic compatible
    /// endpoints are intentionally excluded because Probe cannot establish
    /// that contract from an arbitrary `/models` response.
    public var supportsAttachedWebSearchTool: Bool {
        switch self {
        case .openAI, .deepSeek, .gemini, .anthropic, .mistral, .cohere, .groq, .openRouter:
            return true
        case .ollama:
            // Probe retains every installed model and annotates each model's
            // declared tool capability.
            return true
        default:
            return false
        }
    }

    public var defaultProfileName: String {
        switch self {
        case .openAI: return "OpenAI key"
        case .openAICompatible: return "OpenAI-compatible API"
        case .deepSeek: return "DeepSeek key"
        case .gemini: return "Gemini key"
        case .anthropic: return "Anthropic key"
        case .mistral: return "Mistral key"
        case .cohere: return "Cohere key"
        case .groq: return "Groq key"
        case .openRouter: return "OpenRouter key"
        case .ollama: return "Ollama profile"
        case .youtubeData: return "YouTube Data API key"
        case .twitch: return "Twitch credential"
        case .reddit: return "Reddit credential"
        case .xPlatform: return "X API credential"
        case .tikTok: return "TikTok credential"
        case .instagramGraph: return "Instagram Graph API credential"
        case .facebookGraph: return "Facebook Graph API credential"
        case .serper: return "Serper key"
        case .youSearch: return "You.com Search key"
        case .custom: return "Custom API key"
        }
    }

    public var defaultModelIdentifier: String {
        switch self {
        case .openAI: return "gpt-4.1-mini"
        case .openAICompatible: return ""
        case .deepSeek: return "deepseek-v4-flash"
        case .gemini: return "gemini-3.1-flash-lite"
        case .anthropic: return "claude-sonnet-4-5"
        case .mistral: return "mistral-large-latest"
        case .cohere: return "command-a-plus-05-2026"
        case .groq: return "llama-3.3-70b-versatile"
        case .openRouter: return "openai/gpt-4.1-mini"
        case .ollama: return "llama3.3"
        case .youtubeData, .twitch, .reddit, .xPlatform, .tikTok,
             .instagramGraph, .facebookGraph, .serper, .youSearch: return ""
        case .custom: return "custom-model"
        }
    }

    /// A removed profile type is reset to an inert configurable profile while
    /// its enclosing catalog is reconciled. It never restores the old adapter.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if let type = APIKeyProviderType(rawValue: raw) {
            self = type
            return
        }
        self = .openAICompatible
    }
}

public struct APIKeyProviderProfile: Codable, Equatable, Sendable, Identifiable {
    public static let maximumNameLength = 128
    public static let maximumEndpointLength = 2_048
    public static let maximumTestModelIdentifierLength = 256

    public var id: String
    public var name: String
    public var type: APIKeyProviderType
    /// An optional endpoint override supports compatible cloud, self-hosted,
    /// and custom entries. It is connection configuration only; the selected
    /// LLM model and classification limits belong to `ClassifierTypeAsset`.
    public var customEndpoint: String?
    /// Non-secret protocol settings such as cloud account, region, or API
    /// version. The versioned descriptor controls which keys are allowed.
    public var protocolConfiguration: [String: String]
    /// A non-secret model used only by the compact connection test when the
    /// provider does not publish a fixed test model. Classifier types still
    /// choose their own model for classification.
    public var testModelIdentifier: String?
    /// A plain, locally persisted API key or token. This is intentionally shown
    /// and edited as an ordinary text field in the local WebView.
    public var credential: String?
    public var updatedAtMilliseconds: Int64

    public init(
        id: String = UUID().uuidString,
        name: String? = nil,
        type: APIKeyProviderType,
        customEndpoint: String? = nil,
        protocolConfiguration: [String: String]? = nil,
        testModelIdentifier: String? = nil,
        credential: String? = nil,
        updatedAtMilliseconds: Int64 = WorkspaceCatalog.now()
    ) {
        self.id = id
        self.name = name ?? type.defaultProfileName
        self.type = type
        self.customEndpoint = customEndpoint
        self.protocolConfiguration = protocolConfiguration ?? ProviderProtocolRegistry.descriptor(for: type).defaultConfiguration()
        self.testModelIdentifier = testModelIdentifier
        let normalizedCredential = credential?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.credential = normalizedCredential.isEmpty ? nil : normalizedCredential
        self.updatedAtMilliseconds = updatedAtMilliseconds
    }

    public func validate() throws {
        let cleanedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, id.count <= 128,
              !cleanedName.isEmpty, cleanedName.count <= Self.maximumNameLength else {
            throw APIKeyProviderProfileError.invalidConfiguration
        }

        let descriptor = ProviderProtocolRegistry.descriptor(for: type)
        let normalizedEndpoint = customEndpoint?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedEndpoint?.count ?? 0 <= Self.maximumEndpointLength else {
            throw APIKeyProviderProfileError.invalidConfiguration
        }
        let normalizedTestModelIdentifier = testModelIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedTestModelIdentifier?.count ?? 0 <= Self.maximumTestModelIdentifierLength else {
            throw APIKeyProviderProfileError.invalidConfiguration
        }
        let normalizedCredential = credential?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedCredential?.count ?? 0 <= ProviderCredentialRecord.maximumCharacters,
              normalizedCredential?.unicodeScalars.allSatisfy({ $0.properties.generalCategory != .control }) ?? true else {
            throw APIKeyProviderProfileError.invalidConfiguration
        }
        do {
            try descriptor.validateConfiguration(protocolConfiguration, endpointOverride: normalizedEndpoint, requireDispatchReadiness: false)
        } catch {
            throw APIKeyProviderProfileError.invalidConfiguration
        }
    }

    /// Used by an explicit provider run before it reads the saved credential.
    /// Editing a profile intentionally permits incomplete values.
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
        case id, name, type, customEndpoint, protocolConfiguration, testModelIdentifier, credential, updatedAtMilliseconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        let rawType = try container.decode(String.self, forKey: .type)
        let isRetiredType = APIKeyProviderType(rawValue: rawType) == nil
        type = APIKeyProviderType(rawValue: rawType) ?? .openAICompatible
        // The catalog reconciler removes this invalid placeholder before it is
        // exposed. That keeps old local state from crashing the app without
        // preserving a removed adapter behind a compatibility path.
        name = isRetiredType ? "" : try container.decode(String.self, forKey: .name)
        customEndpoint = try container.decodeIfPresent(String.self, forKey: .customEndpoint)
        protocolConfiguration = try container.decodeIfPresent([String: String].self, forKey: .protocolConfiguration)
            ?? ProviderProtocolRegistry.descriptor(for: type).defaultConfiguration()
        testModelIdentifier = try container.decodeIfPresent(String.self, forKey: .testModelIdentifier)
        let descriptor = ProviderProtocolRegistry.descriptor(for: type)
        if let plainCredential = try? container.decode(String.self, forKey: .credential) {
            let normalizedCredential = plainCredential.trimmingCharacters(in: .whitespacesAndNewlines)
            credential = normalizedCredential.isEmpty ? nil : normalizedCredential
        } else if let legacyCredential = try? container.decode(ProviderCredentialRecord.self, forKey: .credential),
                  let descriptorField = descriptor.credentialFields.first,
                  (try? legacyCredential.validate(for: descriptor)) != nil {
            credential = legacyCredential.values[descriptorField]
        } else {
            credential = nil
        }
        updatedAtMilliseconds = try container.decodeIfPresent(Int64.self, forKey: .updatedAtMilliseconds) ?? WorkspaceCatalog.now()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(type.rawValue, forKey: .type)
        try container.encodeIfPresent(customEndpoint, forKey: .customEndpoint)
        try container.encode(protocolConfiguration, forKey: .protocolConfiguration)
        try container.encodeIfPresent(testModelIdentifier, forKey: .testModelIdentifier)
        try container.encodeIfPresent(credential, forKey: .credential)
        try container.encode(updatedAtMilliseconds, forKey: .updatedAtMilliseconds)
    }
}

public enum APIKeyProviderProfileError: Error, Equatable, LocalizedError, Sendable {
    case invalidConfiguration

    public var errorDescription: String? {
        "The provider profile configuration is invalid."
    }
}
