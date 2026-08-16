import Foundation

/// Builds one bounded non-streaming generation request and delegates response
/// parsing to ProviderTestProtocol's public, format-aware parser. It rejects
/// embedding and search-only profiles before any request can be dispatched.
public enum ProviderGenerationProtocol {
    public static let maximumPromptCharacters = 20_000
    public static let maximumModelIdentifierCharacters = 256
    public static let maximumOutputTokens = 4_096

    public static func supportsGeneration(profile: APIKeyProviderProfile) -> Bool {
        let supportedFormats: [ProviderRequestBodyFormat] = [
            .openAIResponses, .openAIChatCompletions, .anthropicMessages,
            .geminiGenerateContent, .vertexGenerateContent, .cohereChat,
            .ollamaChat,
        ]
        return ProviderProtocolRegistry.descriptor(for: profile.type).requestFormats.contains {
            $0.operation == .generateText && supportedFormats.contains($0.bodyFormat)
        }
    }

    public static func prepareGenerateText(
        profile: APIKeyProviderProfile,
        modelIdentifier: String,
        systemPrompt: String? = nil,
        userPrompt: String,
        maximumOutputTokens: Int
    ) throws -> ProviderTestPreparedRequest {
        let model = modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let system = systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard supportsGeneration(profile: profile),
              !model.isEmpty,
              model.count <= maximumModelIdentifierCharacters,
              !user.isEmpty,
              user.count <= maximumPromptCharacters,
              (system?.count ?? 0) <= maximumPromptCharacters,
              (1...Self.maximumOutputTokens).contains(maximumOutputTokens)
        else {
            throw ProviderTestProtocolError.unsupportedProvider
        }

        let descriptor = ProviderProtocolRegistry.descriptor(for: profile.type)
        let plan = try DescriptorBackedProviderProtocol(descriptor: descriptor).requestPlan(
            for: profile,
            operation: .generateText,
            modelIdentifier: model
        )
        let body = try requestBody(
            format: plan.bodyFormat,
            modelIdentifier: model,
            systemPrompt: system.flatMap { $0.isEmpty ? nil : $0 },
            userPrompt: user,
            maximumOutputTokens: maximumOutputTokens
        )
        return .init(plan: plan, operation: .generateText, prompt: user, body: body)
    }

    public static func parseGeneratedText(
        _ data: Data,
        format: ProviderRequestBodyFormat
    ) throws -> ProviderTestParsedResponse {
        try ProviderTestProtocol.parseResponse(data, format: format, operation: .generateText)
    }

    private static func requestBody(
        format: ProviderRequestBodyFormat,
        modelIdentifier: String,
        systemPrompt: String?,
        userPrompt: String,
        maximumOutputTokens: Int
    ) throws -> Data {
        let messages = (systemPrompt.map { [["role": "system", "content": $0]] } ?? [])
            + [["role": "user", "content": userPrompt]]
        let object: [String: Any]
        switch format {
        case .openAIResponses:
            var value: [String: Any] = [
                "model": modelIdentifier,
                "input": userPrompt,
                "max_output_tokens": maximumOutputTokens,
            ]
            if let systemPrompt { value["instructions"] = systemPrompt }
            object = value
        case .openAIChatCompletions:
            object = [
                "model": modelIdentifier,
                "messages": messages,
                "max_tokens": maximumOutputTokens,
            ]
        case .anthropicMessages:
            var value: [String: Any] = [
                "model": modelIdentifier,
                "max_tokens": maximumOutputTokens,
                "messages": [["role": "user", "content": userPrompt]],
            ]
            if let systemPrompt { value["system"] = systemPrompt }
            object = value
        case .geminiGenerateContent, .vertexGenerateContent:
            var value: [String: Any] = [
                "contents": [["role": "user", "parts": [["text": userPrompt]]]],
                "generationConfig": ["maxOutputTokens": maximumOutputTokens],
            ]
            if let systemPrompt {
                value["systemInstruction"] = ["parts": [["text": systemPrompt]]]
            }
            object = value
        case .cohereChat:
            object = [
                "model": modelIdentifier,
                "messages": messages,
                "max_tokens": maximumOutputTokens,
                "stream": false,
            ]
        case .ollamaChat:
            object = [
                "model": modelIdentifier,
                "messages": messages,
                "stream": false,
                "options": ["num_predict": maximumOutputTokens],
            ]
        case .embeddingInput, .serperSearch, .youSearch, .queryOnly,
             .replicatePrediction, .awsBedrockConverse, .cloudflareAIRun,
             .customJSON:
            throw ProviderTestProtocolError.unsupportedProvider
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
