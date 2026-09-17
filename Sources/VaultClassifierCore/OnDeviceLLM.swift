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

/// An engine that can decode MANY classification requests in one multi-sequence
/// pass (LATENCY-REFINEMENT Phase 1). Generation is memory-bandwidth-bound — each
/// step re-reads all the weights — so advancing N videos per step costs about the
/// same as one. Results are positional: `result[i]` answers `requests[i]`.
public protocol OnDeviceBatchLLM: OnDeviceLLM {
    func classifyBatch(_ requests: [LLMClassificationRequest]) async throws -> [LLMClassificationResult]
}

public extension OnDeviceLLM {
    /// Batched when the engine supports it, otherwise the same requests serially —
    /// so callers have one code path regardless of engine.
    func classifyAll(_ requests: [LLMClassificationRequest]) async throws -> [LLMClassificationResult] {
        if requests.count > 1, let batching = self as? any OnDeviceBatchLLM {
            return try await batching.classifyBatch(requests)
        }
        var results: [LLMClassificationResult] = []
        results.reserveCapacity(requests.count)
        for request in requests { results.append(try await classify(request)) }
        return results
    }
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

// MARK: - Decode 2: research-term extraction (RESEARCH-REDESIGN §4/§5, revised)

// Live smoke (2026-09-17) showed model-EMITTED urgency/author-urgency are
// unreliable (the model anchors the required digit to the prompt default). Per
// the owner's reframe, ALL research urgency is now DERIVED from the calibrated
// Decode-1 confidences (see `ResearchUrgency`), and Decode 2 does only what the
// model does well: copy the salient named span(s) to look up.

/// A single thing to research, with an urgency (1–5; 5 = "the video couldn't be
/// placed"). `term` is copied verbatim from the video's evidence by Decode 2;
/// `urgency` is DERIVED from the video's Decode-1 confidences, not model-emitted.
public struct ResearchNeed: Sendable, Equatable {
    public let term: String
    public let urgency: Int
    public init(term: String, urgency: Int) {
        self.term = term
        self.urgency = min(5, max(1, urgency))
    }
}

/// Derives research urgency from the reliable signal — the video's Decode-1 tag
/// confidences — replacing the model's (degenerate) urgency/author-urgency asks.
public enum ResearchUrgency {
    /// A video's research urgency (1–5) as the inverse of its mean kept-tag
    /// confidence; a decline (no tags) is maximally uncertain (5). This same
    /// per-video value feeds the per-creator author accumulator (§8): a creator
    /// whose videos are consistently low-confidence crosses the research threshold.
    public static func fromTagConfidences(_ confidences: [Int]) -> Int {
        guard !confidences.isEmpty else { return 5 }   // decline = maximally uncertain
        let mean = Double(confidences.reduce(0, +)) / Double(confidences.count)
        return min(5, max(1, 6 - Int(mean.rounded())))
    }
}

/// Decode 2 request. Carries the SAME prompt parts as the classification decode
/// (`staticPrefix` + `dynamicSuffix`) so the engine appends the extraction ask and
/// reuses the KV-cached evidence prefix — in steady state it prefills only the
/// short appendix and, for a recognized video, generates an empty list.
public struct LLMResearchNeedsRequest: Sendable, Equatable {
    public let staticPrefix: String
    public let dynamicSuffix: String
    public let maximumTerms: Int
    public init(staticPrefix: String, dynamicSuffix: String, maximumTerms: Int = 3) {
        self.staticPrefix = staticPrefix
        self.dynamicSuffix = dynamicSuffix
        self.maximumTerms = max(1, maximumTerms)
    }
}

public protocol OnDeviceResearchNeedsExtracting: Sendable {
    /// Copies up to `maximumTerms` named subjects the model does not recognize and
    /// would look up. Terms only — urgency is derived (`ResearchUrgency`), not asked.
    func researchNeeds(_ request: LLMResearchNeedsRequest) async throws -> [String]
}

/// A deterministic stand-in used before a real MLX model is wired, and in tests.
/// It "classifies" by selecting allowed tag names that appear (case-insensitive)
/// in the dynamic suffix — enough to exercise the whole pipeline end-to-end and
/// keep the build green, with no intelligence claimed.
public struct StubOnDeviceLLM: OnDeviceLLM, OnDeviceResearchSubjectExtracting, OnDeviceResearchNeedsExtracting {
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

    public func researchNeeds(_ request: LLMResearchNeedsRequest) async throws -> [String] {
        []
    }
}
