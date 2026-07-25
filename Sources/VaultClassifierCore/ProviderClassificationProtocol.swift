import Foundation

/// The only generic-provider classification path. It is intentionally an
/// explicit, caller-owned request: browser bridge traffic never reaches this
/// type. The response grammar is deliberately tiny so provider prose cannot
/// become a tag, policy, or command.
public enum ProviderClassificationProtocol {
    public static let maximumOutputTokens = LLMAssistConfiguration.maximumOutputTokensPerRequest

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
            nativeWebSearchEnabled: configuration.webSearchEnabled &&
                profile.type.supportsProviderNativeWebSearch
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
        guard let data = content.data(using: .utf8),
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
        nativeWebSearchEnabled: Bool
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
        let searchClause = nativeWebSearchEnabled
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
            var request: [String: Any] = ["model": configuration.modelIdentifier, "input": prompt, "max_output_tokens": output]
            if configuration.webSearchEnabled && profileSupportsNativeWebSearch(format: format) {
                request["tools"] = [["type": "web_search"]]
            }
            object = request
        case .openAIChatCompletions:
            object = ["model": configuration.modelIdentifier, "messages": [["role": "user", "content": prompt]], "max_tokens": output]
        case .anthropicMessages:
            var request: [String: Any] = ["model": configuration.modelIdentifier, "max_tokens": output, "messages": [["role": "user", "content": prompt]]]
            if configuration.webSearchEnabled && profileSupportsNativeWebSearch(format: format) {
                request["tools"] = [["type": "web_search_20250305", "name": "web_search", "max_uses": 3]]
            }
            object = request
        case .geminiGenerateContent, .vertexGenerateContent:
            var request: [String: Any] = ["contents": [["parts": [["text": prompt]]]], "generationConfig": ["maxOutputTokens": output]]
            if configuration.webSearchEnabled && profileSupportsNativeWebSearch(format: format) {
                request["tools"] = [["google_search": [:]]]
            }
            object = request
        case .cohereChat:
            object = ["model": configuration.modelIdentifier, "messages": [["role": "user", "content": prompt]], "max_tokens": output, "stream": false]
        case .ollamaChat:
            object = ["model": configuration.modelIdentifier, "messages": [["role": "user", "content": prompt]], "stream": false, "options": ["num_predict": output]]
        default:
            throw ProviderClassificationProtocolError.unsupportedProvider
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
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
