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
    public func shutdown() async { stopped = true; let jobs = Array(active.values); jobs.forEach { $0.cancel() }; for job in jobs { _ = try? await job.value } }
    public func resolveCloudEngine(for type: ClassifierTypeAsset) async throws -> any ClassificationEngine {
        try type.apiKey.validate()
        guard !stopped else { throw CancellationError() }
        guard let profile = profiles(type.apiKey.profileID), Self.supports(profile.type), profile.credential?.isEmpty == false else {
            throw CloudClassificationError.notConfigured
        }
        guard !failed.contains(profile.id) else { throw CloudClassificationError.invalidOutput }
        return APIKeyClassificationEngine(client: self, profileID: profile.id, configuration: type.apiKey, modelVersion: type.cloudModelVersion)
    }
    private func resetDay() {
        let day = String(Int(Date().timeIntervalSince1970 / 86400))
        if day != today { today = day; requests = 0 }
    }
    func classify(profileID: String, configuration: APIKeyClassificationSettings, requests batch: [LLMClassificationRequest]) async throws -> [LLMClassificationResult] {
        while active.count >= 2 { try Task.checkCancellation(); try await Task.sleep(nanoseconds: 20_000_000) }
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        guard !failed.contains(profileID), let profile = profiles(profileID), Self.supports(profile.type) else { throw CloudClassificationError.notConfigured }
        let request = try APIKeyClassificationEngine.prepare(batch, configuration: configuration, profile: profile)
        let descriptor = ProviderProtocolRegistry.descriptor(for: profile.type)
        guard let field = descriptor.credentialFields.first, let key = profile.credential, !key.isEmpty else { throw ProviderTestProtocolError.missingCredential }
        let credential = ProviderCredentialRecord(values: [field: key]); try credential.validate(for: descriptor)
        let id = UUID(), http = self.http
        let task = Task<String, Error> {
            let result = try await http.send(plan: request.plan, body: request.body, credential: credential, timeout: 60)
            try Task.checkCancellation()
            guard result.data.count <= 2_097_152 else { throw CloudClassificationError.invalidOutput }
            let parsed = try ProviderGenerationProtocol.parseGeneratedText(result.data, format: request.plan.bodyFormat)
            let text = parsed.content
            guard !text.isEmpty else { throw CloudClassificationError.invalidOutput }
            return text
        }
        resetDay(); requests += 1; active[id] = task
        defer { active.removeValue(forKey: id) }
        do {
            let text = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
            try Task.checkCancellation()
            return try ChatGPTClassificationEngine.parse(text, requests: batch)
        } catch {
            if !(error is CancellationError) && !Task.isCancelled && !stopped { failed.insert(profileID) }
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
    static func prepare(_ batch: [LLMClassificationRequest], configuration: APIKeyClassificationSettings, profile: APIKeyProviderProfile) throws -> ProviderTestPreparedRequest {
        guard APIKeyClassificationClient.supports(profile.type) else { throw ProviderTestProtocolError.unsupportedProvider }
        let template = try ChatGPTClassificationEngine.prepare(batch, configuration: .init(model: configuration.model, searchEnabled: configuration.searchEnabled))
        var body = try JSONSerialization.jsonObject(with: template.body!) as! [String: Any]
        let instructions = body["instructions"] as! String
        let schema = ((body["text"] as! [String: Any])["format"] as! [String: Any])["schema"]!
        if profile.type == .gemini {
            if configuration.searchEnabled && !supportsGeminiSearch(configuration.model) { throw ProviderTestProtocolError.unsupportedProvider }
            let input = body["input"] as! [[String: Any]]
            let text = ((input.first?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? (input.first?["content"] as? String) ?? ""
            guard !text.isEmpty else { throw CloudClassificationError.invalidOutput }
            body = ["systemInstruction": ["parts": [["text": instructions]]],
                "contents": [["role": "user", "parts": [["text": text]]]],
                "generationConfig": ["maxOutputTokens": 4096, "responseFormat": ["text": ["mimeType": "APPLICATION_JSON", "schema": schema]]]]
            if configuration.searchEnabled { body["tools"] = [["googleSearch": [:]]] }
        } else {
            body["stream"] = false; body["max_output_tokens"] = 4096
            if profile.type == .xAI || !(configuration.model.hasPrefix("gpt-5") || configuration.model.hasPrefix("gpt-6") || configuration.model.hasPrefix("o3") || configuration.model.hasPrefix("o4")) { body.removeValue(forKey: "reasoning") }
        }
        let descriptor = ProviderProtocolRegistry.descriptor(for: profile.type)
        let plan = try DescriptorBackedProviderProtocol(descriptor: descriptor).requestPlan(for: profile, operation: .generateText, modelIdentifier: configuration.model)
        return .init(plan: plan, operation: .generateText, prompt: "", body: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]))
    }
    static func supportsGeminiSearch(_ model: String) -> Bool { model.hasPrefix("gemini-3") || model.hasPrefix("gemini-4") }
}
