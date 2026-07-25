import Foundation

/// The only generic-provider classification path. It is intentionally an
/// explicit, caller-owned request: browser bridge traffic never reaches this
/// type. The response grammar is deliberately tiny so provider prose cannot
/// become a tag, policy, or command.
public enum ProviderClassificationProtocol {
    public static let maximumOutputTokens = LLMAssistConfiguration.maximumOutputTokensPerRequest
    public static let attachedWebSearchToolName = "web_search"

    public static func prepare(
        profile: APIKeyProviderProfile,
        configuration: LLMAssistConfiguration,
        entry: EntryEvidence,
        allowedTagIDs: Set<String>,
        tagDescriptions: [String: String] = [:],
        maximumOutputTokens: Int? = nil
    ) throws -> ProviderTestPreparedRequest {
        try EntryEvidenceValidator().validate(entry)
        try configuration.validate()
        guard configuration.providerProfileID == profile.id else {
            throw ProviderClassificationProtocolError.invalidConfiguration
        }
        if configuration.webSearchMode == .providerNative,
           !profile.type.supportsProviderNativeWebSearch {
            throw ProviderClassificationProtocolError.unsupportedProvider
        }
        if configuration.webSearchMode == .attached,
           !profile.type.supportsAttachedWebSearchTool {
            throw ProviderClassificationProtocolError.unsupportedProvider
        }
        let requestedOutputTokens = maximumOutputTokens ?? min(
            configuration.maximumOutputTokensPerRequest,
            configuration.dailyOutputTokenLimit
        )
        guard !allowedTagIDs.isEmpty,
              requestedOutputTokens > 0, requestedOutputTokens <= Self.maximumOutputTokens else {
            throw ProviderClassificationProtocolError.noAvailableTags
        }
        let descriptor = ProviderProtocolRegistry.descriptor(for: profile.type)
        guard descriptor.requestFormats.contains(where: { $0.operation == .generateText }) else {
            throw ProviderClassificationProtocolError.unsupportedProvider
        }
        let plan = try DescriptorBackedProviderProtocol(descriptor: descriptor)
            .requestPlan(for: profile, operation: .generateText, modelIdentifier: configuration.modelIdentifier)
        let prompt = prompt(
            entry: entry,
            allowedTagIDs: allowedTagIDs,
            tagDescriptions: tagDescriptions,
            maximumTagCount: configuration.maximumTagCount,
            extraDirection: configuration.extraDirection,
            webSearchAvailable: configuration.webSearchMode != .off
        )
        return .init(
            plan: plan,
            operation: .generateText,
            prompt: prompt,
            body: try requestBody(
                format: plan.bodyFormat,
                configuration: configuration,
                prompt: prompt,
                maximumOutputTokens: requestedOutputTokens
            )
        )
    }

    public static func parseLabelIDs(
        _ content: String,
        allowedTagIDs: Set<String>,
        maximumTagCount: Int = EntryEvidenceValidator.tagLimit
    ) throws -> [String] {
        guard let data = responseJSONData(content),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set(["labelIDs"]),
              let rawLabels = object["labelIDs"] as? [Any],
              maximumTagCount > 0, maximumTagCount <= EntryEvidenceValidator.tagLimit,
              rawLabels.count <= maximumTagCount else {
            throw ProviderClassificationProtocolError.invalidResponse
        }
        var seen = Set<String>()
        let labelIDs = try rawLabels.map { value -> String in
            guard let labelID = value as? String,
                  labelID.count <= EntryEvidenceValidator.tagLengthLimit,
                  allowedTagIDs.contains(labelID),
                  seen.insert(labelID).inserted else {
                throw ProviderClassificationProtocolError.invalidResponse
            }
            return labelID
        }
        return labelIDs.sorted()
    }

    /// Models commonly place an otherwise valid JSON answer in one Markdown
    /// `json` fence. Accept only that complete wrapper; never search prose for
    /// a JSON-looking substring that could turn an explanation into a label.
    private static func responseJSONData(_ content: String) -> Data? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized: String
        if trimmed.hasPrefix("```") {
            let lines = trimmed.components(separatedBy: .newlines)
            guard lines.count >= 3,
                  ["```", "```json"].contains(lines[0].trimmingCharacters(in: .whitespaces).lowercased()),
                  lines.last?.trimmingCharacters(in: .whitespaces) == "```" else {
                return nil
            }
            normalized = lines.dropFirst().dropLast().joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            normalized = trimmed
        }
        return normalized.data(using: .utf8)
    }

    public static func result(
        entry: EntryEvidence,
        classifierType: ClassifierTypeAsset,
        profile: APIKeyProviderProfile,
        configuration: LLMAssistConfiguration,
        taxonomy: Taxonomy,
        policies: [NamedPolicy],
        labelIDs: [String]
    ) -> ClassificationResult {
        let selected = labelIDs.sorted()
        var result = ClassificationResult(
            entryID: entry.entryID,
            sourceID: entry.sourceID,
            surface: entry.surface,
            evidenceState: .sufficient,
            threshold: 1,
            selectedLeafTagIDs: selected,
            ancestorTagIDs: taxonomy.ancestorClosure(for: selected),
            scores: selected.map { .init(tagID: $0, directScore: 1, sourceScore: nil, finalScore: 1) },
            decisions: [],
            packageID: "workspace-classifier-type-\(classifierType.id)",
            modelVersion: "llm-assist-\(profile.id)-\(configuration.modelIdentifier)"
        )
        result.decisions = PolicyEvaluator(taxonomy: taxonomy).evaluate(
            result: result,
            policies: policies,
            requestedPolicyIDs: entry.policyIDs
        )
        return result
    }

    private static func prompt(
        entry: EntryEvidence,
        allowedTagIDs: Set<String>,
        tagDescriptions: [String: String],
        maximumTagCount: Int,
        extraDirection: String,
        webSearchAvailable: Bool
    ) -> String {
        let evidence = [entry.evidence.title, entry.evidence.summary, entry.evidence.text]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let labels = allowedTagIDs.sorted().prefix(EntryEvidenceValidator.tagLimit)
        let tagDefinitions = labels.map { identifier -> [String: String] in
            var definition = ["id": identifier]
            let description = tagDescriptions[identifier]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !description.isEmpty {
                definition["description"] = description
            }
            return definition
        }
        let encodedTagDefinitions = (try? JSONSerialization.data(withJSONObject: tagDefinitions, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let cleanedExtraDirection = extraDirection.trimmingCharacters(in: .whitespacesAndNewlines)
        let extraDirectionClause = cleanedExtraDirection.isEmpty
            ? ""
            : "\nAdditional owner direction:\n\(cleanedExtraDirection)\n"
        let searchClause = webSearchAvailable
            ? "\nUse web search only when the provided evidence is insufficient to identify the creator or classify their recurring content confidently.\n"
            : ""
        return "Classify the quoted local entry using only the listed tag IDs. Eligible tag definitions (return only each id): \(encodedTagDefinitions).\(extraDirectionClause)\(searchClause)Return exactly one JSON object with one key, labelIDs, whose value is an array of at most \(maximumTagCount) listed IDs. Do not include markdown or explanation.\nEntry: \(evidence)"
    }

    private static func requestBody(
        format: ProviderRequestBodyFormat,
        configuration: LLMAssistConfiguration,
        prompt: String,
        maximumOutputTokens: Int
    ) throws -> Data {
        let output = min(Self.maximumOutputTokens, maximumOutputTokens)
        let object: [String: Any]
        switch format {
        case .openAIResponses:
            var request: [String: Any] = [
                "model": configuration.modelIdentifier,
                "input": [["role": "user", "content": prompt]],
                "max_output_tokens": output,
            ]
            if configuration.webSearchMode == .providerNative && profileSupportsNativeWebSearch(format: format) {
                request["tools"] = [["type": "web_search"]]
            } else if configuration.webSearchMode == .attached {
                request["tools"] = [responsesWebSearchTool()]
                request["parallel_tool_calls"] = false
            }
            object = request
        case .openAIChatCompletions:
            var request: [String: Any] = ["model": configuration.modelIdentifier, "messages": [["role": "user", "content": prompt]], "max_tokens": output]
            if configuration.webSearchMode == .attached {
                request["tools"] = [functionWebSearchTool()]
                request["parallel_tool_calls"] = false
            }
            object = request
        case .anthropicMessages:
            var request: [String: Any] = ["model": configuration.modelIdentifier, "max_tokens": output, "messages": [["role": "user", "content": prompt]]]
            if configuration.webSearchMode == .providerNative && profileSupportsNativeWebSearch(format: format) {
                request["tools"] = [["type": "web_search_20250305", "name": "web_search", "max_uses": 3]]
            } else if configuration.webSearchMode == .attached {
                request["tools"] = [anthropicWebSearchTool()]
            }
            object = request
        case .geminiGenerateContent, .vertexGenerateContent:
            var request: [String: Any] = ["contents": [["parts": [["text": prompt]]]], "generationConfig": ["maxOutputTokens": output]]
            if configuration.webSearchMode == .providerNative && profileSupportsNativeWebSearch(format: format) {
                request["tools"] = [["google_search": [:]]]
            } else if configuration.webSearchMode == .attached {
                request["tools"] = [["functionDeclarations": [geminiWebSearchDeclaration()]]]
            }
            object = request
        case .cohereChat:
            var request: [String: Any] = ["model": configuration.modelIdentifier, "messages": [["role": "user", "content": prompt]], "max_tokens": output, "stream": false]
            if configuration.webSearchMode == .attached {
                request["tools"] = [functionWebSearchTool()]
            }
            object = request
        case .ollamaChat:
            var request: [String: Any] = ["model": configuration.modelIdentifier, "messages": [["role": "user", "content": prompt]], "stream": false, "options": ["num_predict": output]]
            if configuration.webSearchMode == .attached {
                request["tools"] = [functionWebSearchTool()]
            }
            object = request
        default:
            throw ProviderClassificationProtocolError.unsupportedProvider
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// Extracts the one bounded client-side search request emitted by a model.
    /// A direct final answer returns nil. Multiple, unknown, or malformed calls
    /// are rejected rather than silently executing extra network work.
    public static func attachedWebSearchCall(
        from data: Data,
        format: ProviderRequestBodyFormat
    ) throws -> ProviderAttachedWebSearchCall? {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderClassificationProtocolError.invalidResponse
        }
        let calls: [[String: Any]]
        switch format {
        case .openAIResponses:
            calls = (root["output"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "function_call" }
        case .openAIChatCompletions:
            let message = ((root["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])
            calls = message?["tool_calls"] as? [[String: Any]] ?? []
        case .anthropicMessages:
            calls = (root["content"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "tool_use" }
        case .geminiGenerateContent, .vertexGenerateContent:
            let parts = (((root["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? []
            calls = parts.compactMap { $0["functionCall"] as? [String: Any] }
        case .cohereChat:
            calls = ((root["message"] as? [String: Any])?["tool_calls"] as? [[String: Any]]) ?? []
        case .ollamaChat:
            calls = ((root["message"] as? [String: Any])?["tool_calls"] as? [[String: Any]]) ?? []
        default:
            throw ProviderClassificationProtocolError.unsupportedProvider
        }
        guard !calls.isEmpty else { return nil }
        guard calls.count == 1 else { throw ProviderClassificationProtocolError.invalidResponse }

        let call = calls[0]
        let identifier: String
        let name: String
        let arguments: Any?
        switch format {
        case .openAIResponses:
            identifier = call["call_id"] as? String ?? ""
            name = call["name"] as? String ?? ""
            arguments = call["arguments"]
        case .anthropicMessages:
            identifier = call["id"] as? String ?? ""
            name = call["name"] as? String ?? ""
            arguments = call["input"]
        case .geminiGenerateContent, .vertexGenerateContent:
            identifier = attachedWebSearchToolName
            name = call["name"] as? String ?? ""
            arguments = call["args"]
        case .ollamaChat:
            let function = call["function"] as? [String: Any]
            identifier = attachedWebSearchToolName
            name = function?["name"] as? String ?? ""
            arguments = function?["arguments"]
        default:
            let function = call["function"] as? [String: Any]
            identifier = call["id"] as? String ?? ""
            name = function?["name"] as? String ?? ""
            arguments = function?["arguments"]
        }
        let decodedArguments: [String: Any]
        if let object = arguments as? [String: Any] {
            decodedArguments = object
        } else if let text = arguments as? String,
                  let argumentData = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: argumentData) as? [String: Any] {
            decodedArguments = object
        } else {
            throw ProviderClassificationProtocolError.invalidResponse
        }
        let query = (decodedArguments["query"] as? String)?
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ") ?? ""
        guard name == attachedWebSearchToolName,
              !identifier.isEmpty,
              !query.isEmpty,
              query.count <= RawWebSearchProtocol.maximumQueryCharacters else {
            throw ProviderClassificationProtocolError.invalidResponse
        }
        return .init(identifier: identifier, query: query)
    }

    /// Replays the first assistant tool call and appends the app-owned search
    /// result using the selected provider's documented continuation grammar.
    /// The caller rejects any second tool call after this continuation.
    public static func attachedWebSearchContinuation(
        initialRequest: ProviderTestPreparedRequest,
        firstResponse: Data,
        call: ProviderAttachedWebSearchCall,
        toolOutput: String,
        maximumOutputTokens: Int
    ) throws -> ProviderTestPreparedRequest {
        guard maximumOutputTokens > 0, maximumOutputTokens <= Self.maximumOutputTokens,
              let initial = try JSONSerialization.jsonObject(with: initialRequest.body) as? [String: Any],
              let response = try JSONSerialization.jsonObject(with: firstResponse) as? [String: Any] else {
            throw ProviderClassificationProtocolError.invalidResponse
        }
        var body = initial
        switch initialRequest.plan.bodyFormat {
        case .openAIResponses:
            var input = initial["input"] as? [[String: Any]] ?? []
            input.append(contentsOf: response["output"] as? [[String: Any]] ?? [])
            input.append([
                "type": "function_call_output",
                "call_id": call.identifier,
                "output": toolOutput,
            ])
            body["input"] = input
            body["max_output_tokens"] = maximumOutputTokens
        case .openAIChatCompletions:
            var messages = initial["messages"] as? [[String: Any]] ?? []
            guard let assistant = ((response["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]) else {
                throw ProviderClassificationProtocolError.invalidResponse
            }
            messages.append(assistant)
            messages.append(["role": "tool", "tool_call_id": call.identifier, "content": toolOutput])
            body["messages"] = messages
            body["max_tokens"] = maximumOutputTokens
        case .anthropicMessages:
            var messages = initial["messages"] as? [[String: Any]] ?? []
            guard let content = response["content"] as? [[String: Any]] else {
                throw ProviderClassificationProtocolError.invalidResponse
            }
            messages.append(["role": "assistant", "content": content])
            messages.append([
                "role": "user",
                "content": [["type": "tool_result", "tool_use_id": call.identifier, "content": toolOutput]],
            ])
            body["messages"] = messages
            body["max_tokens"] = maximumOutputTokens
        case .geminiGenerateContent, .vertexGenerateContent:
            var contents = initial["contents"] as? [[String: Any]] ?? []
            guard var assistant = ((response["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any]) else {
                throw ProviderClassificationProtocolError.invalidResponse
            }
            assistant["role"] = "model"
            contents.append(assistant)
            contents.append([
                "role": "user",
                "parts": [[
                    "functionResponse": [
                        "name": attachedWebSearchToolName,
                        "response": ["result": toolOutput],
                    ],
                ]],
            ])
            body["contents"] = contents
            var generationConfig = body["generationConfig"] as? [String: Any] ?? [:]
            generationConfig["maxOutputTokens"] = maximumOutputTokens
            body["generationConfig"] = generationConfig
        case .cohereChat:
            var messages = initial["messages"] as? [[String: Any]] ?? []
            guard var assistant = response["message"] as? [String: Any] else {
                throw ProviderClassificationProtocolError.invalidResponse
            }
            assistant["role"] = "assistant"
            messages.append(assistant)
            messages.append([
                "role": "tool",
                "tool_call_id": call.identifier,
                "content": [["type": "document", "document": ["data": toolOutput]]],
            ])
            body["messages"] = messages
            body["max_tokens"] = maximumOutputTokens
        case .ollamaChat:
            var messages = initial["messages"] as? [[String: Any]] ?? []
            guard var assistant = response["message"] as? [String: Any] else {
                throw ProviderClassificationProtocolError.invalidResponse
            }
            assistant["role"] = "assistant"
            messages.append(assistant)
            messages.append(["role": "tool", "tool_name": attachedWebSearchToolName, "content": toolOutput])
            body["messages"] = messages
            var options = body["options"] as? [String: Any] ?? [:]
            options["num_predict"] = maximumOutputTokens
            body["options"] = options
        default:
            throw ProviderClassificationProtocolError.unsupportedProvider
        }
        return .init(
            plan: initialRequest.plan,
            operation: initialRequest.operation,
            prompt: initialRequest.prompt,
            body: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        )
    }

    private static func webSearchParameters() -> [String: Any] {
        [
            "type": "object",
            "properties": [
                "query": [
                    "type": "string",
                    "description": "A concise public-web query for identifying this creator or their recurring content.",
                ],
            ],
            "required": ["query"],
            "additionalProperties": false,
        ]
    }

    private static func functionWebSearchTool() -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": attachedWebSearchToolName,
                "description": "Search the public web only when the supplied creator evidence is insufficient for a confident classification. Call at most once.",
                "parameters": webSearchParameters(),
            ],
        ]
    }

    private static func responsesWebSearchTool() -> [String: Any] {
        [
            "type": "function",
            "name": attachedWebSearchToolName,
            "description": "Search the public web only when the supplied creator evidence is insufficient for a confident classification. Call at most once.",
            "parameters": webSearchParameters(),
            "strict": true,
        ]
    }

    private static func anthropicWebSearchTool() -> [String: Any] {
        [
            "name": attachedWebSearchToolName,
            "description": "Search the public web only when the supplied creator evidence is insufficient for a confident classification. Call at most once.",
            "input_schema": webSearchParameters(),
        ]
    }

    private static func geminiWebSearchDeclaration() -> [String: Any] {
        [
            "name": attachedWebSearchToolName,
            "description": "Search the public web only when the supplied creator evidence is insufficient for a confident classification. Call at most once.",
            "parameters": webSearchParameters(),
        ]
    }

    private static func profileSupportsNativeWebSearch(
        format: ProviderRequestBodyFormat
    ) -> Bool {
        switch format {
        case .openAIResponses, .anthropicMessages, .geminiGenerateContent:
            return true
        default:
            return false
        }
    }
}

public struct ProviderAttachedWebSearchCall: Equatable, Sendable {
    public var identifier: String
    public var query: String

    public init(identifier: String, query: String) {
        self.identifier = identifier
        self.query = query
    }
}

public enum ProviderClassificationProtocolError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedProvider
    case invalidConfiguration
    case noAvailableTags
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .unsupportedProvider: return "This provider does not support explicit text classification."
        case .invalidConfiguration: return "The selected LLM model does not belong to this provider connection."
        case .noAvailableTags: return "The selected tag tree has no active leaf tags to classify."
        case .invalidResponse: return "The provider response did not contain valid local tag IDs."
        }
    }
}
