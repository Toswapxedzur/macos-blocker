import Foundation

// The on-device LLM inference boundary for the local-model rework. The rest of
// the pipeline (prompt assembly, mapping, storage) is written against this
// protocol so it stays runtime-agnostic and fully testable; the real MLX-backed
// implementation plugs in behind it, and a deterministic stub stands in until
// then (and in tests).

/// A tag the model may choose, presented by readable **name** (a small model
/// reasons over meaning, not opaque ids). The pipeline maps names back to ids.
public struct LLMTagOption: Sendable, Equatable {
    public let id: String
    public let name: String
    public let description: String?
    public let parentName: String?

    public init(id: String, name: String, description: String? = nil, parentName: String? = nil) {
        self.id = id
        self.name = name
        self.description = description
        self.parentName = parentName
    }
}

/// One tag the model chose, with a discrete 1–5 confidence (logprob-derived where
/// the runtime exposes it, otherwise self-reported).
public struct LLMTagScore: Sendable, Equatable {
    public let name: String
    public let confidence: Int
    public init(name: String, confidence: Int) {
        self.name = name
        self.confidence = ScoredTag.clamp(confidence)
    }
}

/// The model's structured classification output. (The former `unknownTerms`
/// field was dead — always `[]` from every engine — and is removed; research
/// needs will come from the dedicated Decode 2 in RESEARCH-REDESIGN Phase 2.)
public struct LLMClassificationResult: Sendable, Equatable {
    public let tags: [LLMTagScore]
    public init(tags: [LLMTagScore]) {
        self.tags = tags
    }
}

/// A fully-assembled classification request. `staticPrefix` is identical across
/// videos (cache its KV once); `dynamicSuffix` is the per-video part.
/// `allowedTagNames` bounds constrained decoding / the name→id mapping.
public struct LLMClassificationRequest: Sendable, Equatable {
    public let staticPrefix: String
    public let dynamicSuffix: String
    public let allowedTagNames: [String]
    public let maximumTags: Int
    /// Nil falls back to the app-wide engine configuration.
    public let allowDecline: Bool?
    /// Nil falls back to the app-wide engine configuration.
    public let confidenceThresholds: [Double]?

    public init(
        staticPrefix: String,
        dynamicSuffix: String,
        allowedTagNames: [String],
        maximumTags: Int,
        allowDecline: Bool? = nil,
        confidenceThresholds: [Double]? = nil
    ) {
        self.staticPrefix = staticPrefix
        self.dynamicSuffix = dynamicSuffix
        self.allowedTagNames = allowedTagNames
        self.maximumTags = maximumTags
        self.allowDecline = allowDecline
        self.confidenceThresholds = confidenceThresholds
    }
}

public enum OnDeviceLLMError: Error, Sendable, Equatable {
    case notReady(String)
    case inference(String)
}

/// The inference boundary. Implementations must be safe to call concurrently or
/// serialize internally; the pipeline awaits results.
public protocol OnDeviceLLM: Sendable {
    /// Model id + build/prompt-schema version, recorded on each classification so
    /// stale results can be recomputed after a model or prompt change.
    var modelVersion: String { get }
    func classify(_ request: LLMClassificationRequest) async throws -> LLMClassificationResult
}

/// Runtime-neutral bridge to the native resident-engine registry. Core keeps
/// the default engine as its zero-overhead path and consults this resolver only
/// for classifier types with an explicit model selection.
public protocol OnDeviceLLMEngineResolving: Sendable {
    func resolveEngine(
        forModel fileName: String,
        configuration: LocalLLMSettings
    ) async throws -> any OnDeviceLLM
}

/// Rare-path, local-only second decode used after an explicit classification
/// decline. It is deliberately separate from the single-name hot-path request.
public struct LLMResearchSubjectRequest: Sendable, Equatable {
    public let title: String
    public let summary: String?

    public init(title: String, summary: String? = nil) {
        self.title = title
        self.summary = summary
    }
}

public protocol OnDeviceResearchSubjectExtracting: Sendable {
    func extractResearchSubject(_ request: LLMResearchSubjectRequest) async throws -> ResearchSubject?
}

/// A deterministic stand-in used before a real MLX model is wired, and in tests.
/// It "classifies" by selecting allowed tag names that appear (case-insensitive)
/// in the dynamic suffix — enough to exercise the whole pipeline end-to-end and
/// keep the build green, with no intelligence claimed.
public struct StubOnDeviceLLM: OnDeviceLLM, OnDeviceResearchSubjectExtracting {
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

    public func extractResearchSubject(_ request: LLMResearchSubjectRequest) async throws -> ResearchSubject? {
        nil
    }
}
