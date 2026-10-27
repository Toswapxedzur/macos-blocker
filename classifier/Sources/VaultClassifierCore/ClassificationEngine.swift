import Foundation

// Provider-neutral inference contracts used by the classification pipeline.

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
    /// Primary confidence (1–5). As of RESEARCH-REDESIGN Phase 2 this is
    /// MODEL-emitted (Experiment 1 showed it is better calibrated than softmax).
    public let confidence: Int
    /// The former production signal — the renormalized first-token softmax mapped
    /// to 1–5 — kept as a cheap cross-check (nil for engines/stubs that don't
    /// compute it). Not persisted; for logging/diagnostics only.
    public let softmaxConfidence: Int?
    public init(name: String, confidence: Int, softmaxConfidence: Int? = nil) {
        self.name = name
        self.confidence = ScoredTag.clamp(confidence)
        self.softmaxConfidence = softmaxConfidence.map(ScoredTag.clamp)
    }
}

/// The model's structured classification output.
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
    /// Fewest tags the grammar must emit (0 = decline allowed). ≥1 forbids "none".
    public let minimumTags: Int
    /// How sure the model must be before a second or third tag is kept (the
    /// Strict↔Broad position of the type being classified). Nil falls back to
    /// the app-wide engine configuration.
    public let extraTagMinimumOdds: Double?
    public let creatorIdentity: String?

    public init(
        staticPrefix: String,
        dynamicSuffix: String,
        allowedTagNames: [String],
        maximumTags: Int,
        minimumTags: Int = 0,
        extraTagMinimumOdds: Double? = nil,
        creatorIdentity: String? = nil
    ) {
        self.staticPrefix = staticPrefix
        self.dynamicSuffix = dynamicSuffix
        self.allowedTagNames = allowedTagNames
        self.maximumTags = maximumTags
        self.minimumTags = min(maximumTags, max(0, minimumTags))
        self.extraTagMinimumOdds = extraTagMinimumOdds
        self.creatorIdentity = creatorIdentity
    }
}

public enum ClassificationEngineError: Error, Sendable, Equatable {
    case notReady(String)
    case inference(String)
}

/// The inference boundary. Implementations must be safe to call concurrently or
/// serialize internally; the pipeline awaits results.
public protocol ClassificationEngine: Sendable {
    /// Model id + build/prompt-schema version, recorded on each classification so
    /// stale results can be recomputed after a model or prompt change.
    var modelVersion: String { get }
    func classify(_ request: LLMClassificationRequest) async throws -> LLMClassificationResult
}

/// Batched inference. Results preserve request positions.
public protocol BatchClassificationEngine: ClassificationEngine {
    func classifyBatch(_ requests: [LLMClassificationRequest]) async throws -> [LLMClassificationResult]
}

public extension ClassificationEngine {
    /// Batched when the engine supports it, otherwise the same requests serially —
    /// so callers have one code path regardless of engine.
    func classifyAll(_ requests: [LLMClassificationRequest]) async throws -> [LLMClassificationResult] {
        if requests.count > 1, let batching = self as? any BatchClassificationEngine {
            return try await batching.classifyBatch(requests)
        }
        var results: [LLMClassificationResult] = []
        results.reserveCapacity(requests.count)
        for request in requests { results.append(try await classify(request)) }
        return results
    }
}

/// Production never fabricates decisions while a cloud account/model is unconfigured.
public struct UnconfiguredClassificationEngine: ClassificationEngine {
    public let modelVersion = "unconfigured"
    public init() {}
    public func classify(_ request: LLMClassificationRequest) async throws -> LLMClassificationResult {
        throw CloudClassificationError.notConfigured
    }
}
