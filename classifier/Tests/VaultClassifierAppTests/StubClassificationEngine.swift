import Foundation
import VaultClassifierCore

/// A deterministic stand-in used before a real MLX model is wired, and in tests.
/// It "classifies" by selecting allowed tag names that appear (case-insensitive)
/// in the dynamic suffix — enough to exercise the whole pipeline end-to-end and
/// keep the build green, with no intelligence claimed.
public struct StubClassificationEngine: ClassificationEngine {
    public let modelVersion: String
    public let defaultConfidence: Int

    public init(modelVersion: String = "stub/v1", defaultConfidence: Int = 4) {
        self.modelVersion = modelVersion
        self.defaultConfidence = defaultConfidence
    }

    public func classify(_ request: LLMClassificationRequest) async throws -> LLMClassificationResult {
        let haystack = request.dynamicSuffix.lowercased()
        let chosen = request.allowedTagNames
            .filter { !$0.isEmpty && haystack.contains($0.lowercased()) }
            .prefix(request.maximumTags)
            .map { LLMTagScore(name: $0, confidence: defaultConfidence) }
        return LLMClassificationResult(tags: Array(chosen))
    }
}

/// Hermetic provider adapter with real cloud cache currency and no network.
struct FixtureCloudResolver: CloudClassificationEngineResolving {
    let engine: any ClassificationEngine
    func resolveCloudEngine(for type: ClassifierTypeAsset) async throws -> any ClassificationEngine {
        FixtureCloudEngine(engine: engine, modelVersion: type.cloudModelVersion)
    }
}
private struct FixtureCloudEngine: BatchClassificationEngine {
    let engine: any ClassificationEngine
    let modelVersion: String
    func classify(_ request: LLMClassificationRequest) async throws -> LLMClassificationResult { try await engine.classify(request) }
    func classifyBatch(_ requests: [LLMClassificationRequest]) async throws -> [LLMClassificationResult] { try await engine.classifyAll(requests) }
}
extension LocalClassifierCoordinator {
    func setFixtureEngine(_ engine: any ClassificationEngine) { setCloudEngineResolver(FixtureCloudResolver(engine: engine)) }
}
