import Foundation
import VaultClassifierCore

/// Routes exactly one explicitly selected connection. Never falls back or reads
/// subscription credentials when an API-key connection is selected.
public struct ClassificationConnectionResolver: CloudClassificationEngineResolving {
    private let subscription: any CloudClassificationEngineResolving
    private let apiKeys: APIKeyClassificationClient
    public init(subscription: any CloudClassificationEngineResolving, apiKeys: APIKeyClassificationClient) {
        self.subscription = subscription; self.apiKeys = apiKeys
    }
    public func resolveCloudEngine(for type: ClassifierTypeAsset) async throws -> any ClassificationEngine {
        switch type.classificationProvider {
        case .chatGPT: return try await subscription.resolveCloudEngine(for: type)
        case .apiKey: return try await apiKeys.resolveCloudEngine(for: type)
        }
    }
}

public struct APIKeyClassificationStatus: Equatable, Sendable {
    public let failedProfileIDs: Set<String>
    public let requestsToday: Int
}

public actor APIKeyClassificationClient: CloudClassificationEngineResolving {
    public typealias ProfileLookup = @Sendable (String) -> APIKeyProviderProfile?
    private let profiles: ProfileLookup
    private let http: any ProviderHTTPClient
    private var active: [UUID: Task<String, Error>] = [:]
    private var generationActive: [UUID: Task<RuleAIReply, Error>] = [:]
    private var failed = Set<String>()
    private var stopped = false
    private var today = ""
    private var requests = 0
    public init(profiles: @escaping ProfileLookup, http: any ProviderHTTPClient = URLSessionProviderHTTPClient()) {
        self.profiles = profiles; self.http = http
    }
    public static func supports(_ type: APIKeyProviderType) -> Bool { [.openAI, .gemini, .xAI].contains(type) }
    public func status() -> APIKeyClassificationStatus { resetDay(); return .init(failedProfileIDs: failed, requestsToday: requests) }
    public func retryFailedRequests() { failed.removeAll() }
    public func shutdown() async { stopped = true; let generations = Array(generationActive.values); generations.forEach { $0.cancel() }; for job in generations { _ = try? await job.value }; let jobs = Array(active.values); jobs.forEach { $0.cancel() }; for job in jobs { _ = try? await job.value } }
    public func resolveCloudEngine(for type: ClassifierTypeAsset) async throws -> any ClassificationEngine {
        guard type.classificationProvider == .apiKey else { throw CloudClassificationError.notConfigured }
        try type.apiKey.validate()
        guard !stopped else { throw CancellationError() }
        guard let profile = profiles(type.apiKey.profileID), Self.supports(profile.type), profile.credential?.isEmpty == false else {
            throw CloudClassificationError.notConfigured
        }
        guard !failed.contains(profile.id) else { throw CloudClassificationError.invalidOutput }
        return APIKeyClassificationEngine(client: self, profileID: profile.id, configuration: type.apiKey, modelVersion: type.cloudModelVersion)
    }
    public func generateForRule(profileID: String, model: String, effort: ClassificationReasoningEffort, input: RuleAIInput) async throws -> RuleAIReply {
        while active.count + generationActive.count >= 2 { try Task.checkCancellation(); try await Task.sleep(nanoseconds: 20_000_000) }
        try Task.checkCancellation()
        guard !stopped, let profile = profiles(profileID), Self.supports(profile.type) else { throw RuleAIError.unavailable }
        let request = try RuleAIGeneration.apiKey(profile: profile, model: model, effort: effort, input: input)
        let descriptor = ProviderProtocolRegistry.descriptor(for: profile.type)
        guard let field = descriptor.credentialFields.first, let key = profile.credential, !key.isEmpty else { throw RuleAIError.invalidConfiguration }
        let credential = ProviderCredentialRecord(values: [field: key]); try credential.validate(for: descriptor)
        let id = UUID(), http = self.http
        let task = Task<RuleAIReply, Error> {
            let result = try await http.send(plan: request.plan, body: request.body, credential: credential, timeout: .infinity)
            try Task.checkCancellation()
            return try RuleAIGeneration.parse(result.data, format: request.plan.bodyFormat)
        }
        resetDay(); requests += 1; generationActive[id] = task
        defer { generationActive.removeValue(forKey: id) }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
    private func resetDay() {
        let day = String(Int(Date().timeIntervalSince1970 / 86400))
        if day != today { today = day; requests = 0 }
    }
    private func recordAttempt() { resetDay(); requests += 1 }
    func classify(profileID: String, configuration: APIKeyClassificationSettings, requests batch: [LLMClassificationRequest]) async throws -> [LLMClassificationResult] {
        while active.count + generationActive.count >= 2 { try Task.checkCancellation(); try await Task.sleep(nanoseconds: 20_000_000) }
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        guard !failed.contains(profileID), let profile = profiles(profileID), Self.supports(profile.type) else { throw CloudClassificationError.notConfigured }
        let request = try APIKeyClassificationEngine.prepare(batch, configuration: configuration, profile: profile)
        let descriptor = ProviderProtocolRegistry.descriptor(for: profile.type)
        guard let field = descriptor.credentialFields.first, let key = profile.credential, !key.isEmpty else { throw ProviderTestProtocolError.missingCredential }
        let credential = ProviderCredentialRecord(values: [field: key]); try credential.validate(for: descriptor)
        let id = UUID(), http = self.http, policy = profile.taggingRetryPolicy
        let task = Task<String, Error> {
            var attempt = 1
            while true {
                do {
                    let result = try await http.send(plan: request.plan, body: request.body, credential: credential, timeout: .infinity)
                    try Task.checkCancellation()
                    guard result.data.count <= 2_097_152 else { throw CloudClassificationError.invalidOutput }
                    let root = try JSONSerialization.jsonObject(with: result.data) as? [String: Any]
                    if request.plan.bodyFormat == .geminiGenerateContent {
                        guard let candidates = root?["candidates"] as? [[String: Any]], candidates.count == 1,
                              candidates[0]["finishReason"] as? String == "STOP" else { throw CloudClassificationError.invalidOutput }
                    } else { guard root?["status"] as? String == "completed" else { throw CloudClassificationError.invalidOutput } }
                    let parsed = try ProviderGenerationProtocol.parseGeneratedText(result.data, format: request.plan.bodyFormat)
                    let text = parsed.content
                    guard !text.isEmpty else { throw CloudClassificationError.invalidOutput }
                    return text
                } catch {
                    guard attempt < policy.maximumAttempts, TaggingRetry.isTransient(error) else { throw error }
                    try await TaggingRetry.wait(policy)
                    try Task.checkCancellation()
                    self.recordAttempt()
                    attempt += 1
                }
            }
        }
        recordAttempt(); active[id] = task
        defer { active.removeValue(forKey: id) }
        do {
            let text = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
            try Task.checkCancellation()
            return try ChatGPTClassificationEngine.parse(text, requests: batch)
        } catch {
            // A provider can reject one item's evidence with HTTP 400. Leave
            // that item unresolved for Retry without holding the connection or
            // preventing independent items from running.
            let rejectedItem = (error as? ProviderTestHTTPError) == .status(400)
            if !(error is CancellationError) && !Task.isCancelled && !stopped && !rejectedItem { failed.insert(profileID) }
            throw error
        }
    }
}

struct APIKeyClassificationEngine: BatchClassificationEngine {
    let client: APIKeyClassificationClient
    let profileID: String
    let configuration: APIKeyClassificationSettings
    let modelVersion: String
    func classify(_ request: LLMClassificationRequest) async throws -> LLMClassificationResult { try await classifyBatch([request])[0] }
    func classifyBatch(_ requests: [LLMClassificationRequest]) async throws -> [LLMClassificationResult] {
        guard !requests.isEmpty else { return [] }
        let chunks = stride(from: 0, to: requests.count, by: 16).map { Array(requests[$0..<min(requests.count, $0 + 16)]) }
        return try await withThrowingTaskGroup(of: (Int, [LLMClassificationResult]).self) { group in
            func enqueue(_ index: Int) { group.addTask { (index, try await client.classify(profileID: profileID, configuration: configuration, requests: chunks[index])) } }
            var next = min(2, chunks.count)
            for index in 0..<next { enqueue(index) }
            var ordered = Array(repeating: [LLMClassificationResult](), count: chunks.count)
            while let (index, result) = try await group.next() {
                ordered[index] = result
                if next < chunks.count { enqueue(next); next += 1 }
            }
            return ordered.flatMap { $0 }
        }
    }
    /// Gemini rejects the expanded bounded-array grammar for larger batches.
    /// Keep its schema small; the shared strict parser enforces exact indices,
    /// item/tag counts, allowed names and confidence after generation.
    static func geminiSchema(_ value: Any) -> Any {
        if let object = value as? [String: Any] { return object.filter { !["minItems", "maxItems"].contains($0.key) }.mapValues(geminiSchema) }
        if let array = value as? [Any] { return array.map(geminiSchema) }
        return value
    }
    static func prepare(_ batch: [LLMClassificationRequest], configuration: APIKeyClassificationSettings, profile: APIKeyProviderProfile) throws -> ProviderTestPreparedRequest {
        guard APIKeyClassificationClient.supports(profile.type) else { throw ProviderTestProtocolError.unsupportedProvider }
        try ClassificationModelPolicy.validate(provider: profile.type, model: configuration.model, effort: configuration.reasoningEffort)
        let template = try ChatGPTClassificationEngine.prepare(batch, configuration: .init(model: configuration.model, reasoningEffort: configuration.reasoningEffort))
        var body = try JSONSerialization.jsonObject(with: template.body!) as! [String: Any]
        let instructions = body["instructions"] as! String
        let schema = ((body["text"] as! [String: Any])["format"] as! [String: Any])["schema"]!
        if profile.type == .gemini {
            let input = body["input"] as! [[String: Any]]
            let text = ((input.first?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? (input.first?["content"] as? String) ?? ""
            guard !text.isEmpty else { throw CloudClassificationError.invalidOutput }
            // Medium/High thinking spends part of the response budget before
            // emitting JSON. A 16-item batch with correction examples can
            // otherwise end at MAX_TOKENS without a complete tag set.
            let outputTokens = [ClassificationReasoningEffort.medium, .high].contains(configuration.reasoningEffort) ? 8192 : 4096
            body = ["systemInstruction": ["parts": [["text": instructions]]],
                "contents": [["role": "user", "parts": [["text": text]]]],
                "generationConfig": ["maxOutputTokens": outputTokens, "responseFormat": ["text": ["mimeType": "APPLICATION_JSON", "schema": Self.geminiSchema(schema)]]]]
            body["tools"] = [["googleSearch": [:]]]
            if configuration.reasoningEffort != .providerDefault {
                var generation = body["generationConfig"] as! [String: Any]
                generation["thinkingConfig"] = ["thinkingLevel": configuration.reasoningEffort.rawValue]
                body["generationConfig"] = generation
            }
        } else {
            body["stream"] = false; body["max_output_tokens"] = 4096

        }
        let descriptor = ProviderProtocolRegistry.descriptor(for: profile.type)
        let plan = try DescriptorBackedProviderProtocol(descriptor: descriptor).requestPlan(for: profile, operation: .generateText, modelIdentifier: configuration.model)
        return .init(plan: plan, operation: .generateText, prompt: "", body: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]))
    }
}
