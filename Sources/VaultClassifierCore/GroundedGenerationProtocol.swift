import Foundation

/// Builds one bounded generation request that lets the language-model provider
/// perform the web search itself via its native grounding tool (Gemini
/// google_search, OpenAI web_search, Anthropic web_search), and extracts the
/// grounded text plus best-effort source URLs. This is the `providerGrounding`
/// research search mode: a single grounding-capable provider both searches and
/// distills, so no separate raw-search provider is needed.
public enum GroundedGenerationProtocol {
    /// A provider can ground when it both supports generation and has an
    /// explicit native-search request grammar in this app.
    public static func supportsProviderGrounding(profile: APIKeyProviderProfile) -> Bool {
        profile.type.supportsProviderNativeWebSearch
            && ProviderGenerationProtocol.supportsGeneration(profile: profile)
    }

    /// The grounding instruction. It never sends anything but the sanitized
    /// subject and forbids the model from assigning classification tags.
    static func systemPrompt() -> String {
        "Search the public web for the named subject and return a short, factual description of what or who it is. "
            + "Never assign, suggest, or mention classification tags. Do not state anything you cannot ground in public sources. Return plain text only."
    }

    public static func prepareGroundedGenerate(
        profile: APIKeyProviderProfile,
        modelIdentifier: String,
        subject: String,
        maximumOutputTokens: Int
    ) throws -> ProviderTestPreparedRequest {
        let model = modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedSubject = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        guard supportsProviderGrounding(profile: profile),
              !model.isEmpty,
              model.count <= ProviderGenerationProtocol.maximumModelIdentifierCharacters,
              !cleanedSubject.isEmpty,
              cleanedSubject.count <= ProviderGenerationProtocol.maximumPromptCharacters,
              (1...ProviderGenerationProtocol.maximumOutputTokens).contains(maximumOutputTokens)
        else {
            throw ProviderTestProtocolError.unsupportedProvider
        }

        let descriptor = ProviderProtocolRegistry.descriptor(for: profile.type)
        let plan = try DescriptorBackedProviderProtocol(descriptor: descriptor).requestPlan(
            for: profile,
            operation: .generateText,
            modelIdentifier: model
        )
        let userPrompt = "Subject: \(cleanedSubject)"
        let body = try groundedBody(
            format: plan.bodyFormat,
            modelIdentifier: model,
            systemPrompt: systemPrompt(),
            userPrompt: userPrompt,
            maximumOutputTokens: maximumOutputTokens
        )
        return .init(plan: plan, operation: .generateText, prompt: userPrompt, body: body)
    }

    /// Grounded text + best-effort source URLs. Text reuses the shared,
    /// format-aware parser; sources are extracted per family and may be empty
    /// (the distilled meaning is still stored either way).
    public static func parseGroundedGeneration(
        _ data: Data,
        format: ProviderRequestBodyFormat
    ) throws -> (text: String, sourceURLs: [String], usage: ProviderTestUsage) {
        let parsed = try ProviderTestProtocol.parseResponse(data, format: format, operation: .generateText)
        return (parsed.content, extractSourceURLs(data, format: format), parsed.usage)
    }

    // MARK: - Request bodies (generation + native search tool)

    private static func groundedBody(
        format: ProviderRequestBodyFormat,
        modelIdentifier: String,
        systemPrompt: String,
        userPrompt: String,
        maximumOutputTokens: Int
    ) throws -> Data {
        let object: [String: Any]
        switch format {
        case .geminiGenerateContent, .vertexGenerateContent:
            object = [
                "contents": [["role": "user", "parts": [["text": userPrompt]]]],
                "generationConfig": ["maxOutputTokens": maximumOutputTokens],
                "systemInstruction": ["parts": [["text": systemPrompt]]],
                "tools": [["google_search": [String: Any]()]],
            ]
        case .openAIResponses:
            object = [
                "model": modelIdentifier,
                "input": userPrompt,
                "instructions": systemPrompt,
                "max_output_tokens": maximumOutputTokens,
                "tools": [["type": "web_search"]],
            ]
        case .anthropicMessages:
            object = [
                "model": modelIdentifier,
                "max_tokens": maximumOutputTokens,
                "system": systemPrompt,
                "messages": [["role": "user", "content": userPrompt]],
                "tools": [["type": "web_search_20250305", "name": "web_search"]],
            ]
        case .openAIChatCompletions, .cohereChat, .ollamaChat, .embeddingInput,
             .serperSearch, .youSearch, .queryOnly, .replicatePrediction,
             .awsBedrockConverse, .cloudflareAIRun, .customJSON:
            // No app-defined native-search grammar for these formats.
            throw ProviderTestProtocolError.unsupportedProvider
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    // MARK: - Best-effort source extraction

    static func extractSourceURLs(_ data: Data, format: ProviderRequestBodyFormat) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var urls: [String] = []
        var seen = Set<String>()
        func add(_ value: Any?) {
            guard let string = value as? String,
                  let url = URL(string: string),
                  let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  seen.insert(string).inserted else { return }
            urls.append(string)
        }
        // A tolerant recursive scan for the citation URL keys each family uses
        // (Gemini groundingChunks[].web.uri, OpenAI url_citation.url, Anthropic
        // web_search results .url). Scanning avoids brittle path assumptions
        // across provider response revisions.
        func walk(_ node: Any) {
            if let dict = node as? [String: Any] {
                for key in ["uri", "url"] { add(dict[key]) }
                for value in dict.values { walk(value) }
            } else if let array = node as? [Any] {
                for value in array { walk(value) }
            }
        }
        walk(root)
        return Array(urls.prefix(16))
    }
}
