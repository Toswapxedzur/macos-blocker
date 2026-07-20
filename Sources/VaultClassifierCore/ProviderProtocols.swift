import Foundation

/// A stable, versioned request grammar that another local module can inspect
/// before it ever retrieves a credential or starts a network request.
public enum ProviderProtocolFamily: String, Codable, Equatable, Sendable, CaseIterable {
    case openAIResponsesV1
    case openAIChatCompletionsV1
    case anthropicMessagesV1
    case geminiGenerateContentV1Beta
    case cohereChatV2
    case replicatePredictionsV1
    case awsBedrockConverseV1
    case googleVertexGenerateContentV1
    case cloudflareWorkersAIRunV4
    case voyageEmbeddingsV1
    case jinaEmbeddingsV1
    case ollamaChatV1
    case youtubeDataV3
    case twitchHelixV1
    case redditOAuthV1
    case xAPIV2
    case tikTokDisplayV2
    case metaGraphV1
    case soundCloudV2
    case steamWebV1
    case braveSearchV1
    case tavilySearchV1
    case serpAPIV1
    case firecrawlV2
    case googleCustomSearchV1
    case bingWebSearchV7
    case customJSONV1
}

public enum ProviderOperation: String, Codable, Equatable, Sendable, CaseIterable {
    case generateText
    case embedText
    case searchWeb
    case readPublicContent
}

public enum ProviderRequestBodyFormat: String, Codable, Equatable, Sendable {
    case openAIResponses
    case openAIChatCompletions
    case anthropicMessages
    case geminiGenerateContent
    case cohereChat
    case replicatePrediction
    case awsBedrockConverse
    case vertexGenerateContent
    case cloudflareAIRun
    case embeddingInput
    case ollamaChat
    case queryOnly
    case customJSON
}

public enum ProviderAuthenticationMethod: String, Codable, Equatable, Sendable {
    case none
    case bearerToken
    case apiKeyHeader
    case apiKeyQuery
    case bearerTokenAndClientID
    case awsSignatureV4
}

public enum ProviderCredentialField: String, Codable, Equatable, Sendable, CaseIterable {
    case apiKey
    case bearerToken
    case clientSecret
    case accessKeyID
    case secretAccessKey
    case sessionToken
}

public enum ProviderConfigurationField: String, Codable, Equatable, Sendable, CaseIterable {
    case accountID
    case apiVersion
    case clientID
    case location
    case projectID
    case region
    case userAgent
    case searchEngineID
    case protocolFamily
}

public struct ProviderConfigurationRequirement: Codable, Equatable, Sendable {
    public var field: ProviderConfigurationField
    public var defaultValue: String?
    public var isRequiredForDispatch: Bool

    public init(_ field: ProviderConfigurationField, defaultValue: String? = nil, isRequiredForDispatch: Bool = true) {
        self.field = field
        self.defaultValue = defaultValue
        self.isRequiredForDispatch = isRequiredForDispatch
    }
}

public struct ProviderRequestFormat: Codable, Equatable, Sendable {
    public var operation: ProviderOperation
    public var method: String
    /// A relative path. `{model}` and a declared configuration field can be
    /// substituted by a consuming module after validation.
    public var pathTemplate: String
    public var bodyFormat: ProviderRequestBodyFormat

    public init(operation: ProviderOperation, method: String, pathTemplate: String, bodyFormat: ProviderRequestBodyFormat) {
        self.operation = operation
        self.method = method
        self.pathTemplate = pathTemplate
        self.bodyFormat = bodyFormat
    }
}

public struct ProviderProtocolDescriptor: Codable, Equatable, Sendable {
    public static let currentRevision = 1

    public var identifier: String
    public var revision: Int
    public var family: ProviderProtocolFamily
    public var defaultBaseURL: String?
    public var allowsEndpointOverride: Bool
    public var allowsLoopbackHTTP: Bool
    public var authentication: ProviderAuthenticationMethod
    public var authenticationHeader: String?
    public var credentialFields: [ProviderCredentialField]
    public var configurationRequirements: [ProviderConfigurationRequirement]
    public var requestFormats: [ProviderRequestFormat]
    public var staticHeaders: [String: String]

    public init(
        identifier: String,
        family: ProviderProtocolFamily,
        defaultBaseURL: String?,
        allowsEndpointOverride: Bool = false,
        allowsLoopbackHTTP: Bool = false,
        authentication: ProviderAuthenticationMethod,
        authenticationHeader: String? = nil,
        credentialFields: [ProviderCredentialField],
        configurationRequirements: [ProviderConfigurationRequirement] = [],
        requestFormats: [ProviderRequestFormat],
        staticHeaders: [String: String] = [:]
    ) {
        self.identifier = identifier
        self.revision = Self.currentRevision
        self.family = family
        self.defaultBaseURL = defaultBaseURL
        self.allowsEndpointOverride = allowsEndpointOverride
        self.allowsLoopbackHTTP = allowsLoopbackHTTP
        self.authentication = authentication
        self.authenticationHeader = authenticationHeader
        self.credentialFields = credentialFields
        self.configurationRequirements = configurationRequirements
        self.requestFormats = requestFormats
        self.staticHeaders = staticHeaders
    }

    public var supportsLLMConfiguration: Bool {
        requestFormats.contains { $0.operation == .generateText || $0.operation == .embedText }
    }

    public func defaultConfiguration() -> [String: String] {
        Dictionary(uniqueKeysWithValues: configurationRequirements.compactMap { requirement in
            requirement.defaultValue.map { (requirement.field.rawValue, $0) }
        })
    }

    public func validateConfiguration(_ values: [String: String], endpointOverride: String?, requireDispatchReadiness: Bool) throws {
        let allowed = Set(configurationRequirements.map { $0.field.rawValue })
        guard Set(values.keys).isSubset(of: allowed), values.allSatisfy({ key, value in
            !key.isEmpty && key.count <= 64 && value.count <= 512
        }) else {
            throw ProviderProtocolError.invalidConfiguration
        }
        if requireDispatchReadiness {
            for requirement in configurationRequirements where requirement.isRequiredForDispatch {
                guard values[requirement.field.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                    throw ProviderProtocolError.missingConfiguration(requirement.field)
                }
            }
            if family == .customJSONV1,
               let value = values[ProviderConfigurationField.protocolFamily.rawValue],
               ProviderProtocolFamily(rawValue: value) == nil {
                throw ProviderProtocolError.invalidConfiguration
            }
        }

        if let endpointOverride = endpointOverride?.trimmingCharacters(in: .whitespacesAndNewlines), !endpointOverride.isEmpty {
            guard allowsEndpointOverride,
                  let components = URLComponents(string: endpointOverride),
                  let scheme = components.scheme?.lowercased(),
                  components.host != nil,
                  scheme == "https" || (allowsLoopbackHTTP && scheme == "http" && isLoopbackHost(components.host)) else {
                throw ProviderProtocolError.invalidEndpoint
            }
        } else if requireDispatchReadiness, defaultBaseURL == nil {
            throw ProviderProtocolError.missingEndpoint
        }
    }

    private func isLoopbackHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }
}

/// A credential-free request plan. Native modules may use this to decide
/// whether a profile supports an operation before they ask Keychain for any
/// secret. It deliberately carries field names, never credential values.
public struct ProviderRequestPlan: Equatable, Sendable {
    public var url: URL
    public var method: String
    public var bodyFormat: ProviderRequestBodyFormat
    public var headers: [String: String]
    public var authentication: ProviderAuthenticationMethod
    public var authenticationHeader: String?
    public var requiredCredentialFields: [ProviderCredentialField]

    public init(
        url: URL,
        method: String,
        bodyFormat: ProviderRequestBodyFormat,
        headers: [String: String],
        authentication: ProviderAuthenticationMethod,
        authenticationHeader: String?,
        requiredCredentialFields: [ProviderCredentialField]
    ) {
        self.url = url
        self.method = method
        self.bodyFormat = bodyFormat
        self.headers = headers
        self.authentication = authentication
        self.authenticationHeader = authenticationHeader
        self.requiredCredentialFields = requiredCredentialFields
    }
}

/// Native modules implement this protocol to consume a profile's declared
/// request grammar. It has no network method: dispatch remains a separate,
/// explicit action with a user-approved payload and Keychain credential.
public protocol ProviderRequestProtocol: Sendable {
    var descriptor: ProviderProtocolDescriptor { get }
    func requestPlan(
        for profile: APIKeyProviderProfile,
        operation: ProviderOperation
    ) throws -> ProviderRequestPlan
}

public struct DescriptorBackedProviderProtocol: ProviderRequestProtocol {
    public let descriptor: ProviderProtocolDescriptor

    public init(descriptor: ProviderProtocolDescriptor) {
        self.descriptor = descriptor
    }

    public func requestPlan(
        for profile: APIKeyProviderProfile,
        operation: ProviderOperation
    ) throws -> ProviderRequestPlan {
        guard profile.type.rawValue == descriptor.identifier,
              let format = descriptor.requestFormats.first(where: { $0.operation == operation }) else {
            throw ProviderProtocolError.unsupportedOperation
        }
        try profile.validateForDispatch()
        let baseURL = profile.customEndpoint?.trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty ?? descriptor.defaultBaseURL
        guard let baseURL else { throw ProviderProtocolError.missingEndpoint }
        let path = substitute(format.pathTemplate, profile: profile)
        let resolvedBaseURL = substitute(baseURL, profile: profile)
        guard let url = URL(string: resolvedBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) else {
            throw ProviderProtocolError.invalidEndpoint
        }
        var headers = descriptor.staticHeaders
        if format.bodyFormat != .queryOnly { headers["Content-Type"] = "application/json" }
        return .init(
            url: url,
            method: format.method,
            bodyFormat: format.bodyFormat,
            headers: headers,
            authentication: descriptor.authentication,
            authenticationHeader: descriptor.authenticationHeader,
            requiredCredentialFields: descriptor.credentialFields
        )
    }

    private func substitute(_ template: String, profile: APIKeyProviderProfile) -> String {
        var result = template.replacingOccurrences(of: "{model}", with: profile.modelIdentifier.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? profile.modelIdentifier)
        for (field, value) in profile.protocolConfiguration {
            let encoded = value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
            result = result.replacingOccurrences(of: "{\(field)}", with: encoded)
        }
        return result
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

public enum ProviderProtocolError: Error, Equatable, LocalizedError, Sendable {
    case invalidConfiguration
    case missingConfiguration(ProviderConfigurationField)
    case invalidEndpoint
    case missingEndpoint
    case unsupportedOperation

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "The provider protocol configuration is invalid."
        case .missingConfiguration(let field): return "The provider protocol requires \(field.rawValue)."
        case .invalidEndpoint: return "The provider endpoint must use HTTPS, except an explicit loopback endpoint."
        case .missingEndpoint: return "The provider protocol requires an endpoint."
        case .unsupportedOperation: return "The provider protocol does not support that operation."
        }
    }
}

/// The registry is intentionally data-only. It identifies the exact HTTP
/// grammar a future adapter must implement; it does not authorize a request.
public enum ProviderProtocolRegistry {
    public static func descriptor(for type: APIKeyProviderType) -> ProviderProtocolDescriptor {
        switch type {
        case .openAI:
            return model(type, .openAIResponsesV1, "https://api.openai.com/v1", "/responses", .openAIResponses)
        case .openAICompatible:
            return model(type, .openAIChatCompletionsV1, nil, "/chat/completions", .openAIChatCompletions, override: true)
        case .deepSeek:
            return model(type, .openAIChatCompletionsV1, "https://api.deepseek.com/v1", "/chat/completions", .openAIChatCompletions)
        case .gemini:
            return model(type, .geminiGenerateContentV1Beta, "https://generativelanguage.googleapis.com/v1beta", "/models/{model}:generateContent", .geminiGenerateContent, authentication: .apiKeyHeader, header: "x-goog-api-key")
        case .anthropic:
            return model(type, .anthropicMessagesV1, "https://api.anthropic.com/v1", "/messages", .anthropicMessages, authentication: .apiKeyHeader, header: "x-api-key", headers: ["anthropic-version": "2023-06-01"])
        case .mistral:
            return model(type, .openAIChatCompletionsV1, "https://api.mistral.ai/v1", "/chat/completions", .openAIChatCompletions)
        case .cohere:
            return model(type, .cohereChatV2, "https://api.cohere.com/v2", "/chat", .cohereChat)
        case .groq:
            return model(type, .openAIChatCompletionsV1, "https://api.groq.com/openai/v1", "/chat/completions", .openAIChatCompletions)
        case .openRouter:
            return model(type, .openAIChatCompletionsV1, "https://openrouter.ai/api/v1", "/chat/completions", .openAIChatCompletions)
        case .ollama:
            return model(type, .ollamaChatV1, "http://127.0.0.1:11434", "/api/chat", .ollamaChat, authentication: .none, credentials: [], override: true, loopback: true)
        case .youtubeData:
            return external(type, .youtubeDataV3, "https://www.googleapis.com/youtube/v3", "/videos", .readPublicContent, authentication: .apiKeyQuery, header: "key")
        case .twitch:
            return external(type, .twitchHelixV1, "https://api.twitch.tv/helix", "/videos", .readPublicContent, authentication: .bearerTokenAndClientID, configuration: [.init(.clientID)])
        case .reddit:
            return external(type, .redditOAuthV1, "https://oauth.reddit.com", "/r/{contentID}/new", .readPublicContent, configuration: [.init(.userAgent, defaultValue: "VaultClassifier/1.0")])
        case .xPlatform:
            return external(type, .xAPIV2, "https://api.x.com/2", "/tweets/{contentID}", .readPublicContent)
        case .tikTok:
            return external(type, .tikTokDisplayV2, "https://open.tiktokapis.com/v2", "/video/query/", .readPublicContent, method: "POST", body: .customJSON)
        case .instagramGraph, .facebookGraph:
            return external(type, .metaGraphV1, "https://graph.facebook.com", "/{apiVersion}/{contentID}", .readPublicContent, configuration: [.init(.apiVersion, defaultValue: "v24.0")])
        case .custom:
            return model(type, .openAIChatCompletionsV1, nil, "/chat/completions", .openAIChatCompletions, override: true)
        }
    }

    private static func model(
        _ type: APIKeyProviderType,
        _ family: ProviderProtocolFamily,
        _ baseURL: String?,
        _ path: String,
        _ body: ProviderRequestBodyFormat,
        operation: ProviderOperation = .generateText,
        authentication: ProviderAuthenticationMethod = .bearerToken,
        header: String? = nil,
        credentials: [ProviderCredentialField] = [.apiKey],
        override: Bool = false,
        loopback: Bool = false,
        configuration: [ProviderConfigurationRequirement] = [],
        headers: [String: String] = [:]
    ) -> ProviderProtocolDescriptor {
        .init(identifier: type.rawValue, family: family, defaultBaseURL: baseURL, allowsEndpointOverride: override, allowsLoopbackHTTP: loopback, authentication: authentication, authenticationHeader: header, credentialFields: credentials, configurationRequirements: configuration, requestFormats: [.init(operation: operation, method: "POST", pathTemplate: path, bodyFormat: body)], staticHeaders: headers)
    }

    private static func external(
        _ type: APIKeyProviderType,
        _ family: ProviderProtocolFamily,
        _ baseURL: String?,
        _ path: String,
        _ operation: ProviderOperation,
        authentication: ProviderAuthenticationMethod = .bearerToken,
        header: String? = nil,
        override: Bool = false,
        configuration: [ProviderConfigurationRequirement] = [],
        method: String = "GET",
        body: ProviderRequestBodyFormat = .queryOnly
    ) -> ProviderProtocolDescriptor {
        let credentials: [ProviderCredentialField]
        switch authentication {
        case .none:
            credentials = []
        case .bearerToken, .bearerTokenAndClientID:
            credentials = [.bearerToken]
        case .apiKeyHeader, .apiKeyQuery:
            credentials = [.apiKey]
        case .awsSignatureV4:
            credentials = [.accessKeyID, .secretAccessKey]
        }
        return .init(identifier: type.rawValue, family: family, defaultBaseURL: baseURL, allowsEndpointOverride: override, authentication: authentication, authenticationHeader: header, credentialFields: credentials, configurationRequirements: configuration, requestFormats: [.init(operation: operation, method: method, pathTemplate: path, bodyFormat: body)])
    }
}
