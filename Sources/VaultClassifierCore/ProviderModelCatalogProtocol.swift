import Foundation

/// Prepares the model Probe for one LLM connection. Fixed providers use the
/// Vault service's credential-free curated catalog; Custom and compatible
/// providers make the same explicit request against their own endpoint because
/// only their operator knows the account-specific model inventory.
public enum ProviderModelCatalogProtocol {
    public static let maximumModels = 256
    public static let maximumResponseBytes = 512 * 1_024

    public static func prepare(
        profile: APIKeyProviderProfile,
        vaultService: VaultServiceEndpoint? = nil
    ) throws -> ProviderRequestPlan {
        let descriptor = ProviderProtocolRegistry.descriptor(for: profile.type)
        guard descriptor.supportsLLMConfiguration else {
            throw ProviderModelCatalogProtocolError.unsupportedProvider
        }
        if usesVaultCatalog(profile.type) {
            try profile.validate()
            guard let vaultService else { throw ProviderModelCatalogProtocolError.missingVaultService }
            let path = "api/vault-classifier/llm-model-catalog/\(profile.type.rawValue)"
            return .init(
                url: try vaultService.url(path: path),
                method: "GET",
                bodyFormat: .queryOnly,
                headers: ["Accept": "application/json"],
                authentication: .none,
                authenticationHeader: nil,
                requiredCredentialFields: []
            )
        }

        try profile.validateForDispatch()
        let path: String
        switch profile.type {
        case .ollama:
            path = "/api/tags"
        default:
            path = "/models"
        }
        let url = try catalogURL(profile: profile, descriptor: descriptor, path: path)
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

    public static func usesVaultCatalog(_ providerType: APIKeyProviderType) -> Bool {
        switch providerType {
        case .openAI, .deepSeek, .gemini, .anthropic, .mistral, .cohere,
             .groq, .openRouter:
            return true
        default:
            return false
        }
    }

    public static func parse(_ data: Data, providerType: APIKeyProviderType) throws -> [String] {
        guard data.count <= maximumResponseBytes,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderModelCatalogProtocolError.invalidResponse
        }
        let candidates: [[String: Any]]
        switch providerType {
        case .gemini, .ollama, .cohere:
            candidates = root["models"] as? [[String: Any]] ?? []
        default:
            candidates = (root["data"] as? [[String: Any]]) ?? (root["models"] as? [[String: Any]]) ?? []
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

    private static func catalogURL(
        profile: APIKeyProviderProfile,
        descriptor: ProviderProtocolDescriptor,
        path: String
    ) throws -> URL {
        let override = profile.customEndpoint?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let base = override.isEmpty ? descriptor.defaultBaseURL : override
        guard let base, var components = URLComponents(string: base),
              components.scheme != nil, components.host != nil else {
            throw ProviderModelCatalogProtocolError.invalidConfiguration
        }
        components.query = nil
        components.fragment = nil
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let tail = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + [basePath, tail].filter { !$0.isEmpty }.joined(separator: "/")
        guard let url = components.url else { throw ProviderModelCatalogProtocolError.invalidConfiguration }
        return url
    }
}

public enum ProviderModelCatalogProtocolError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedProvider
    case missingVaultService
    case invalidConfiguration
    case invalidResponse
    case noModels

    public var errorDescription: String? {
        switch self {
        case .unsupportedProvider: return "This connection cannot list models."
        case .missingVaultService: return "The fixed provider model catalog needs a configured Vault service."
        case .invalidConfiguration: return "The provider connection cannot build a model-list request."
        case .invalidResponse: return "The provider returned an unreadable or oversized model list."
        case .noModels: return "The provider returned no usable text-generation models."
        }
    }
}
