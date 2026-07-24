import Foundation

/// Prepares one explicit model-list request against the selected LLM provider.
/// The request plan carries no credential value; the app applies the saved
/// local credential immediately before sending it to that provider.
public enum ProviderModelCatalogProtocol {
    public static let maximumModels = 256
    public static let maximumResponseBytes = 2 * 1_024 * 1_024

    public static func prepare(profile: APIKeyProviderProfile) throws -> ProviderRequestPlan {
        let descriptor = ProviderProtocolRegistry.descriptor(for: profile.type)
        guard descriptor.supportsLLMConfiguration else {
            throw ProviderModelCatalogProtocolError.unsupportedProvider
        }
        try profile.validateForDispatch()
        let endpoint = catalogEndpoint(for: profile.type)
        let url = try catalogURL(
            profile: profile,
            descriptor: descriptor,
            path: endpoint.path,
            replacesBasePath: endpoint.replacesBasePath,
            queryItems: endpoint.queryItems
        )
        var headers = descriptor.staticHeaders
        headers["Accept"] = "application/json"
        return .init(
            url: url,
            method: "GET",
            bodyFormat: .queryOnly,
            headers: headers,
            authentication: descriptor.authentication,
            authenticationHeader: descriptor.authenticationHeader,
            requiredCredentialFields: descriptor.credentialFields
        )
    }

    public static func parse(_ data: Data, providerType: APIKeyProviderType) throws -> [String] {
        guard data.count <= maximumResponseBytes else {
            throw ProviderModelCatalogProtocolError.invalidResponse
        }
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ProviderModelCatalogProtocolError.invalidResponse
        }
        let candidates: [[String: Any]]
        if providerType == .mistral, let models = root as? [[String: Any]] {
            // Mistral's documented list response is a top-level array.
            candidates = models
        } else if let object = root as? [String: Any] {
            switch providerType {
            case .gemini, .ollama, .cohere:
                candidates = object["models"] as? [[String: Any]] ?? []
            default:
                candidates = (object["data"] as? [[String: Any]]) ?? (object["models"] as? [[String: Any]]) ?? []
            }
        } else {
            throw ProviderModelCatalogProtocolError.invalidResponse
        }
        var seen = Set<String>()
        let models = candidates.compactMap { candidate -> String? in
            if providerType == .gemini,
               let methods = candidate["supportedGenerationMethods"] as? [String],
               !methods.contains("generateContent") {
                return nil
            }
            let raw = (candidate["id"] as? String)
                ?? (candidate["name"] as? String)
                ?? (candidate["model"] as? String)
            var identifier = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if providerType == .gemini, identifier.hasPrefix("models/") {
                identifier.removeFirst("models/".count)
            }
            guard !identifier.isEmpty,
                  identifier.count <= LLMAssistConfiguration.maximumModelIdentifierLength,
                  seen.insert(identifier).inserted else {
                return nil
            }
            return identifier
        }
        guard !models.isEmpty else { throw ProviderModelCatalogProtocolError.noModels }
        return Array(models.prefix(maximumModels)).sorted()
    }

    private static func catalogEndpoint(for providerType: APIKeyProviderType) -> CatalogEndpoint {
        switch providerType {
        case .ollama:
            return .init(path: "/api/tags")
        case .cohere:
            // Cohere's Chat API is rooted at /v2, while its Models API is /v1.
            return .init(
                path: "/v1/models",
                replacesBasePath: true,
                queryItems: [.init(name: "page_size", value: String(maximumModels))]
            )
        case .gemini:
            return .init(
                path: "/models",
                queryItems: [.init(name: "pageSize", value: String(maximumModels))]
            )
        case .anthropic:
            return .init(
                path: "/models",
                queryItems: [.init(name: "limit", value: String(maximumModels))]
            )
        default:
            return .init(path: "/models")
        }
    }

    private static func catalogURL(
        profile: APIKeyProviderProfile,
        descriptor: ProviderProtocolDescriptor,
        path: String,
        replacesBasePath: Bool,
        queryItems: [URLQueryItem]
    ) throws -> URL {
        let override = profile.customEndpoint?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let base = override.isEmpty ? descriptor.defaultBaseURL : override
        guard let base, var components = URLComponents(string: base),
              components.scheme != nil, components.host != nil else {
            throw ProviderModelCatalogProtocolError.invalidConfiguration
        }
        components.query = nil
        components.fragment = nil
        let basePath = replacesBasePath ? "" : components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let tail = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + [basePath, tail].filter { !$0.isEmpty }.joined(separator: "/")
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else { throw ProviderModelCatalogProtocolError.invalidConfiguration }
        return url
    }

    private struct CatalogEndpoint {
        var path: String
        var replacesBasePath = false
        var queryItems: [URLQueryItem] = []
    }
}

public enum ProviderModelCatalogProtocolError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedProvider
    case invalidConfiguration
    case invalidResponse
    case noModels

    public var errorDescription: String? {
        switch self {
        case .unsupportedProvider: return "This connection cannot list models."
        case .invalidConfiguration: return "The provider connection cannot build a model-list request."
        case .invalidResponse: return "The provider returned an unreadable or oversized model list."
        case .noModels: return "The provider returned no usable text-generation models."
        }
    }
}
