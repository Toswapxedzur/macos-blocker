import Foundation

/// A bounded, explicit test request for a configured provider profile. It is
/// intentionally limited to a constant harmless prompt; regular generation is
/// a separate, user-approved feature.
public enum ProviderTestProtocol {
    public static let prompt = "Return exactly OK."
    public static let maximumOutputTokens = 32
    public static let maximumResponseCharacters = 12_000

    public static func prepare(profile: APIKeyProviderProfile) throws -> ProviderTestPreparedRequest {
        let descriptor = ProviderProtocolRegistry.descriptor(for: profile.type)
        let operation: ProviderOperation
        if descriptor.requestFormats.contains(where: { $0.operation == .generateText }) {
            operation = .generateText
        } else if descriptor.requestFormats.contains(where: { $0.operation == .embedText }) {
            operation = .embedText
        } else {
            throw ProviderTestProtocolError.unsupportedProvider
        }
        let modelIdentifier = profile.type.defaultModelIdentifier
        guard !modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderTestProtocolError.modelRequired
        }
        let plan = try DescriptorBackedProviderProtocol(descriptor: descriptor).requestPlan(
            for: profile,
            operation: operation,
            modelIdentifier: modelIdentifier
        )
        let body = try requestBody(
            format: plan.bodyFormat,
            modelIdentifier: modelIdentifier,
            operation: operation
        )
        return .init(plan: plan, operation: operation, prompt: prompt, body: body)
    }

    public static func parseResponse(_ data: Data, format: ProviderRequestBodyFormat, operation: ProviderOperation) throws -> ProviderTestParsedResponse {
        let json = try JSONSerialization.jsonObject(with: data)
        let root = json as? [String: Any] ?? [:]
        let usage: ProviderTestUsage
        switch format {
        case .geminiGenerateContent, .vertexGenerateContent:
            usage = .init(inputTokens: int(root, path: ["usageMetadata", "promptTokenCount"]), outputTokens: int(root, path: ["usageMetadata", "candidatesTokenCount"]))
        case .anthropicMessages:
            usage = .init(inputTokens: int(root, path: ["usage", "input_tokens"]), outputTokens: int(root, path: ["usage", "output_tokens"]))
        case .cohereChat:
            usage = .init(inputTokens: int(root, path: ["usage", "tokens", "input_tokens"]), outputTokens: int(root, path: ["usage", "tokens", "output_tokens"]))
        default:
            usage = .init(inputTokens: int(root, path: ["usage", "prompt_tokens"]) ?? int(root, path: ["usage", "input_tokens"]), outputTokens: int(root, path: ["usage", "completion_tokens"]) ?? int(root, path: ["usage", "output_tokens"]))
        }

        let content: String
        if operation == .embedText {
            content = "Embedding test completed."
        } else {
            content = extractText(root, format: format) ?? "Provider test completed."
        }
        return .init(content: String(content.prefix(maximumResponseCharacters)), usage: usage)
    }

    public static func safeEndpoint(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        components.query = nil
        components.fragment = nil
        return components.url?.absoluteString ?? url.deletingPathExtension().absoluteString
    }

    private static func requestBody(
        format: ProviderRequestBodyFormat,
        modelIdentifier: String,
        operation: ProviderOperation
    ) throws -> Data {
        let output = maximumOutputTokens
        let object: [String: Any]
        switch format {
        case .openAIResponses:
            object = ["model": modelIdentifier, "input": prompt, "max_output_tokens": output]
        case .openAIChatCompletions:
            object = ["model": modelIdentifier, "messages": [["role": "user", "content": prompt]], "max_tokens": output]
        case .anthropicMessages:
            object = ["model": modelIdentifier, "max_tokens": output, "messages": [["role": "user", "content": prompt]]]
        case .geminiGenerateContent, .vertexGenerateContent:
            object = ["contents": [["parts": [["text": prompt]]]], "generationConfig": ["maxOutputTokens": output]]
        case .cohereChat:
            object = ["model": modelIdentifier, "messages": [["role": "user", "content": prompt]], "max_tokens": output]
        case .ollamaChat:
            object = ["model": modelIdentifier, "messages": [["role": "user", "content": prompt]], "stream": false, "options": ["num_predict": output]]
        case .embeddingInput:
            object = ["model": modelIdentifier, "input": [prompt]]
        default:
            throw ProviderTestProtocolError.unsupportedProvider
        }
        guard operation == .generateText || operation == .embedText else { throw ProviderTestProtocolError.unsupportedProvider }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func int(_ root: [String: Any], path: [String]) -> Int? {
        var value: Any = root
        for component in path {
            guard let object = value as? [String: Any], let next = object[component] else { return nil }
            value = next
        }
        if let integer = value as? Int { return integer }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }

    private static func extractText(_ root: [String: Any], format: ProviderRequestBodyFormat) -> String? {
        switch format {
        case .openAIResponses:
            let output = root["output"] as? [[String: Any]] ?? []
            return joinedText(output.flatMap { $0["content"] as? [[String: Any]] ?? [] })
        case .openAIChatCompletions:
            return (((root["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String)?.nonEmpty
        case .anthropicMessages:
            return joinedText(root["content"] as? [[String: Any]] ?? [])
        case .geminiGenerateContent, .vertexGenerateContent:
            let parts = (((root["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? []
            return joinedText(parts)
        case .cohereChat:
            return joinedText((root["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? [])
        case .ollamaChat:
            return ((root["message"] as? [String: Any])?["content"] as? String)?.nonEmpty
        default:
            return nil
        }
    }

    private static func joinedText(_ values: [[String: Any]]) -> String? {
        values.compactMap { $0["text"] as? String }.joined(separator: "\n").nonEmpty
    }
}

public struct ProviderTestPreparedRequest: Equatable, Sendable {
    public var plan: ProviderRequestPlan
    public var operation: ProviderOperation
    public var prompt: String
    public var body: Data

    public init(plan: ProviderRequestPlan, operation: ProviderOperation, prompt: String, body: Data) {
        self.plan = plan
        self.operation = operation
        self.prompt = prompt
        self.body = body
    }
}

public struct ProviderTestUsage: Equatable, Sendable {
    public var inputTokens: Int?
    public var outputTokens: Int?

    public init(inputTokens: Int?, outputTokens: Int?) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

public struct ProviderTestParsedResponse: Equatable, Sendable {
    public var content: String
    public var usage: ProviderTestUsage

    public init(content: String, usage: ProviderTestUsage) {
        self.content = content
        self.usage = usage
    }
}

public enum ProviderTestProtocolError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedProvider
    case modelRequired
    case missingCredential
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .unsupportedProvider: return "This provider protocol does not support a safe test request yet."
        case .modelRequired: return "Select a model in a classifier type before testing this compatible provider connection."
        case .missingCredential: return "Store a provider credential before testing this profile."
        case .invalidResponse: return "The provider test returned an invalid response."
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
