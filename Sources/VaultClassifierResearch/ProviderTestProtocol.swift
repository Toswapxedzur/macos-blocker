import Foundation
import VaultClassifierCore

/// A bounded, explicit test request for a configured provider profile. Model
/// profiles use a constant harmless prompt; platform-data profiles use a
/// provider-specific health route. Retired search-only profiles cannot be
/// tested. Regular generation remains a separate, user-approved feature.
public enum ProviderTestProtocol {
    public static let prompt = "Return exactly OK."
    public static let maximumOutputTokens = 32
    public static let maximumResponseCharacters = 12_000
    public static var maximumResponseShapeCharacters: Int { ProviderRequestRecord.maximumResponseShapeCharacters }

    public static func prepare(profile: APIKeyProviderProfile) throws -> ProviderTestPreparedRequest {
        let descriptor = ProviderProtocolRegistry.descriptor(for: profile.type)
        if descriptor.requestFormats.contains(where: { $0.operation == .readPublicContent }) {
            let request = try OfficialPlatformConnectionTestProtocol.prepare(profile: profile)
            return .init(
                plan: request.plan,
                operation: .readPublicContent,
                prompt: "",
                body: request.body ?? Data()
            )
        }
        if descriptor.isRetiredSearchProvider {
            throw ProviderTestProtocolError.unsupportedProvider
        }
        let operation: ProviderOperation
        if descriptor.requestFormats.contains(where: { $0.operation == .generateText }) {
            operation = .generateText
        } else if descriptor.requestFormats.contains(where: { $0.operation == .embedText }) {
            operation = .embedText
        } else {
            throw ProviderTestProtocolError.unsupportedProvider
        }
        let modelIdentifier = modelIdentifier(for: profile)
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

    public static func modelIdentifier(for profile: APIKeyProviderProfile) -> String {
        if let selected = profile.testModelIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            return selected
        }
        // Compatible and Custom connections deliberately have no trustworthy
        // default: their owner chooses both the endpoint and its model.
        switch profile.type {
        case .openAICompatible, .custom:
            return ""
        default:
            return profile.type.defaultModelIdentifier
        }
    }

    public static func parseResponse(_ data: Data, format: ProviderRequestBodyFormat, operation: ProviderOperation) throws -> ProviderTestParsedResponse {
        let json = try JSONSerialization.jsonObject(with: data)
        if operation == .readPublicContent {
            return .init(content: "Platform API test completed.", usage: .init(tokenCount: nil))
        }
        let root = json as? [String: Any] ?? [:]
        let usage = usage(from: root, format: format)

        let content: String
        if operation == .embedText {
            content = "Embedding test completed."
        } else {
            // A 2xx JSON envelope alone does not demonstrate that the model
            // connection works. Some gateways return a JSON error or an empty
            // success envelope with that status. A provider test is successful
            // only when its declared response grammar contains generated text.
            guard let generated = extractText(root, format: format),
                  !generated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ProviderTestProtocolError.invalidResponse
            }
            content = generated
        }
        return .init(content: String(content.prefix(maximumResponseCharacters)), usage: usage)
    }

    public static func usage(
        from data: Data,
        format: ProviderRequestBodyFormat
    ) throws -> ProviderTestUsage {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderTestProtocolError.invalidResponse
        }
        return usage(from: root, format: format)
    }

    private static func usage(
        from root: [String: Any],
        format: ProviderRequestBodyFormat
    ) -> ProviderTestUsage {
        switch format {
        case .geminiGenerateContent, .vertexGenerateContent:
            if let total = int(root, path: ["usageMetadata", "totalTokenCount"]) {
                return .init(tokenCount: total)
            }
            guard let prompt = int(root, path: ["usageMetadata", "promptTokenCount"]),
                  let candidates = int(root, path: ["usageMetadata", "candidatesTokenCount"]) else {
                return .init(tokenCount: nil)
            }
            return .init(tokenCount: sum([
                prompt,
                candidates,
                int(root, path: ["usageMetadata", "thoughtsTokenCount"]) ?? 0,
                int(root, path: ["usageMetadata", "toolUsePromptTokenCount"]) ?? 0,
            ]))
        case .anthropicMessages:
            guard let input = int(root, path: ["usage", "input_tokens"]),
                  let output = int(root, path: ["usage", "output_tokens"]) else {
                return .init(tokenCount: nil)
            }
            return .init(tokenCount: sum([
                input,
                int(root, path: ["usage", "cache_creation_input_tokens"]) ?? 0,
                int(root, path: ["usage", "cache_read_input_tokens"]) ?? 0,
                output,
            ]))
        case .cohereChat:
            guard let input = int(root, path: ["usage", "tokens", "input_tokens"]),
                  let output = int(root, path: ["usage", "tokens", "output_tokens"]) else {
                return .init(tokenCount: nil)
            }
            return .init(tokenCount: sum([
                input,
                output,
            ]))
        case .ollamaChat:
            guard let input = int(root, path: ["prompt_eval_count"]),
                  let output = int(root, path: ["eval_count"]) else {
                return .init(tokenCount: nil)
            }
            return .init(tokenCount: sum([
                input,
                output,
            ]))
        default:
            if let total = int(root, path: ["usage", "total_tokens"]) {
                return .init(tokenCount: total)
            }
            guard let input = int(root, path: ["usage", "prompt_tokens"])
                ?? int(root, path: ["usage", "input_tokens"]) else {
                return .init(tokenCount: nil)
            }
            if let completion = int(root, path: ["usage", "completion_tokens"]) {
                // OpenAI-compatible completion totals already include their
                // reasoning-token detail, so do not double-count the subset.
                return .init(tokenCount: sum([input, completion]))
            }
            guard let output = int(root, path: ["usage", "output_tokens"]) else {
                return .init(tokenCount: nil)
            }
            return .init(tokenCount: sum([
                input,
                output,
                int(root, path: ["usage", "reasoning_tokens"]) ?? 0,
            ]))
        }
    }

    /// Describes a response's JSON envelope without retaining any response
    /// values. This is used only when a 2xx response cannot be parsed, so a
    /// later diagnosis can distinguish an unexpected envelope from an empty
    /// generated-text field without exposing provider output.
    public static func responseShape(for data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            return "non-JSON response"
        }
        guard let root = json as? [String: Any] else {
            return "JSON \(jsonKind(json))"
        }

        var parts = ["JSON object"]
        appendFields(of: root, named: "top-level", to: &parts)
        if let choices = root["choices"] as? [Any] {
            parts.append("choices: \(choices.count)")
            if let firstChoice = choices.first as? [String: Any] {
                appendFields(of: firstChoice, named: "first choice", to: &parts)
                if let message = firstChoice["message"] as? [String: Any] {
                    appendFields(of: message, named: "message", to: &parts)
                    let content = (message["content"] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    parts.append(content?.isEmpty == false ? "content: non-empty string" : "content: missing-or-empty")
                }
            }
        }
        if let error = root["error"] as? [String: Any] {
            appendFields(of: error, named: "error", to: &parts)
        }
        return String(parts.joined(separator: "; ").prefix(maximumResponseShapeCharacters))
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
            // The parser accepts one complete JSON reply, never an SSE stream.
            object = ["model": modelIdentifier, "messages": [["role": "user", "content": prompt]], "max_tokens": output, "stream": false]
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
        if let integer = value as? Int { return integer >= 0 ? integer : nil }
        if let number = value as? NSNumber {
            let integer = number.int64Value
            return integer >= 0 && UInt64(integer) <= UInt64(Int.max) ? Int(integer) : nil
        }
        return nil
    }

    private static func sum(_ values: [Int]) -> Int? {
        var total = 0
        for value in values {
            let addition = total.addingReportingOverflow(value)
            guard !addition.overflow else { return nil }
            total = addition.partialValue
        }
        return total
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

    private static func appendFields(of object: [String: Any], named name: String, to parts: inout [String]) {
        let fields = object.keys
            .filter(isSafeDiagnosticFieldName)
            .sorted()
            .prefix(12)
        guard !fields.isEmpty else { return }
        parts.append("\(name) fields: \(fields.joined(separator: ", "))")
    }

    private static func isSafeDiagnosticFieldName(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 64 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 45, 46, 48...57, 65...90, 95, 97...122:
                return true
            default:
                return false
            }
        }
    }

    private static func jsonKind(_ value: Any) -> String {
        if value is [Any] { return "array" }
        if value is String { return "string" }
        if value is NSNumber { return "number" }
        if value is NSNull { return "null" }
        return "value"
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
    public var tokenCount: Int?

    public init(tokenCount: Int?) {
        self.tokenCount = tokenCount.map { max(0, $0) }
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
        case .modelRequired: return "Enter a test model for this provider connection."
        case .missingCredential: return "Store a provider credential before testing this profile."
        case .invalidResponse: return "The provider test returned an invalid response."
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
