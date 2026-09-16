import Foundation

public enum EntrySurface: String, Codable, Sendable, CaseIterable {
    case feed
    case page
}

public enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else { throw DecodingError.typeMismatch(JSONValue.self, .init(codingPath: decoder.codingPath, debugDescription: "Expected string, number, or boolean")) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        }
    }
}

public struct EvidencePayload: Codable, Equatable, Sendable {
    public var title: String?
    public var text: String?
    public var summary: String?
    public var suppliedTags: [String]
    public var metadata: [String: JSONValue]

    public init(title: String? = nil, text: String? = nil, summary: String? = nil, suppliedTags: [String] = [], metadata: [String: JSONValue] = [:]) {
        self.title = title
        self.text = text
        self.summary = summary
        self.suppliedTags = suppliedTags
        self.metadata = metadata
    }

    public var hasReadableContent: Bool {
        [title, text, summary].contains { !($0?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) } || !suppliedTags.isEmpty
    }
}

public struct EntryEvidence: Codable, Equatable, Sendable, Identifiable {
    public var requestID: String
    public var platform: String
    public var entryID: String?
    public var sourceID: String?
    /// Other identity forms observed for the same source alongside `sourceID`
    /// (e.g. a YouTube channel `UC…` seen next to the creator's `@handle`).
    /// These let a source classified under one form be found and de-duplicated
    /// when later observed under another.
    public var sourceAliases: [String]
    public var surface: EntrySurface
    public var evidence: EvidencePayload
    public var policyIDs: [String]

    public var id: String { requestID }

    public init(requestID: String = UUID().uuidString, platform: String, entryID: String? = nil, sourceID: String? = nil, sourceAliases: [String] = [], surface: EntrySurface, evidence: EvidencePayload, policyIDs: [String] = []) {
        self.requestID = requestID
        self.platform = platform
        self.entryID = entryID
        self.sourceID = sourceID
        self.sourceAliases = sourceAliases
        self.surface = surface
        self.evidence = evidence
        self.policyIDs = policyIDs
    }

    private enum CodingKeys: String, CodingKey {
        case requestID, platform, entryID, sourceID, sourceAliases, surface, evidence, policyIDs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requestID = try container.decode(String.self, forKey: .requestID)
        platform = try container.decode(String.self, forKey: .platform)
        entryID = try container.decodeIfPresent(String.self, forKey: .entryID)
        sourceID = try container.decodeIfPresent(String.self, forKey: .sourceID)
        // Crash guard for pre-alias payloads: a missing list is an empty one.
        sourceAliases = try container.decodeIfPresent([String].self, forKey: .sourceAliases) ?? []
        surface = try container.decode(EntrySurface.self, forKey: .surface)
        evidence = try container.decode(EvidencePayload.self, forKey: .evidence)
        policyIDs = try container.decodeIfPresent([String].self, forKey: .policyIDs) ?? []
    }
}

public enum EntryEvidenceValidationError: Error, Equatable, LocalizedError, Sendable {
    case missing(String)
    case exceedsLimit(String, Int)
    case invalidValue(String)

    public var errorDescription: String? {
        switch self {
        case .missing(let field): return "Missing required field: \(field)."
        case .exceedsLimit(let field, let maximum): return "\(field) exceeds its limit of \(maximum)."
        case .invalidValue(let field): return "Invalid value for \(field)."
        }
    }
}

public struct EntryEvidenceValidator: Sendable {
    public static let requestIDLimit = 128
    public static let platformLimit = 64
    public static let entryIDLimit = 256
    public static let sourceIDLimit = 256
    public static let sourceAliasLimit = 8
    public static let titleLimit = 500
    public static let textLimit = 16_000
    public static let summaryLimit = 16_000
    public static let tagLimit = 64
    public static let tagLengthLimit = 256
    public static let metadataLimit = 64
    public static let metadataKeyLengthLimit = 64
    public static let metadataValueLengthLimit = 512

    public init() {}

    public func validate(_ entry: EntryEvidence) throws {
        try required(entry.requestID, field: "requestID", limit: Self.requestIDLimit)
        try required(entry.platform, field: "platform", limit: Self.platformLimit)
        try optional(entry.entryID, field: "entryID", limit: Self.entryIDLimit)
        try optional(entry.sourceID, field: "sourceID", limit: Self.sourceIDLimit)
        guard entry.sourceAliases.count <= Self.sourceAliasLimit else {
            throw EntryEvidenceValidationError.exceedsLimit("sourceAliases", Self.sourceAliasLimit)
        }
        for alias in entry.sourceAliases {
            try required(alias, field: "sourceAliases[]", limit: Self.sourceIDLimit)
            // An alias is only meaningful as another identity of the same source:
            // it must be scoped to the same platform and differ from the primary.
            guard alias.hasPrefix("\(entry.platform):"), alias != entry.sourceID else {
                throw EntryEvidenceValidationError.invalidValue("sourceAliases[]")
            }
        }
        try optional(entry.evidence.title, field: "title", limit: Self.titleLimit)
        try optional(entry.evidence.text, field: "text", limit: Self.textLimit)
        try optional(entry.evidence.summary, field: "summary", limit: Self.summaryLimit)
        guard entry.evidence.suppliedTags.count <= Self.tagLimit else { throw EntryEvidenceValidationError.exceedsLimit("suppliedTags", Self.tagLimit) }
        guard entry.evidence.metadata.count <= Self.metadataLimit else { throw EntryEvidenceValidationError.exceedsLimit("metadata", Self.metadataLimit) }
        for tag in entry.evidence.suppliedTags {
            try required(tag, field: "suppliedTags[]", limit: Self.tagLengthLimit)
        }
        for (key, value) in entry.evidence.metadata {
            try required(key, field: "metadata key", limit: Self.metadataKeyLengthLimit)
            guard key.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f }) else {
                throw EntryEvidenceValidationError.invalidValue("metadata key")
            }
            switch value {
            case .string(let text):
                try required(text, field: "metadata value", limit: Self.metadataValueLengthLimit)
                guard text.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f }) else {
                    throw EntryEvidenceValidationError.invalidValue("metadata value")
                }
            case .number, .bool: break
            }
        }
        guard entry.evidence.hasReadableContent else { throw EntryEvidenceValidationError.missing("evidence") }
    }

    private func required(_ value: String, field: String, limit: Int) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw EntryEvidenceValidationError.missing(field) }
        guard value.count <= limit else { throw EntryEvidenceValidationError.exceedsLimit(field, limit) }
    }

    private func optional(_ value: String?, field: String, limit: Int) throws {
        guard let value else { return }
        guard value.count <= limit else { throw EntryEvidenceValidationError.exceedsLimit(field, limit) }
    }
}

public enum PresentationAction: String, Codable, Sendable, CaseIterable, Comparable {
    case allow
    case dim
    case block

    private var rank: Int {
        switch self { case .allow: return 0; case .dim: return 1; case .block: return 2 }
    }

    public static func < (lhs: PresentationAction, rhs: PresentationAction) -> Bool { lhs.rank < rhs.rank }
}

/// User-tunable configuration for the in-process on-device LLM (the final
/// Phase-0 contract engine). Every knob is clamped into a safe range at init,
/// so hand-edited or stale persisted values can never produce an unusable
/// engine. Basic fields sit in the settings panel; the rest live behind the
/// advanced disclosure.
public struct LocalLLMSettings: Codable, Equatable, Sendable {
    public static let defaultMaxResidentModels = 2
    public static let maximumResidentModels = 4

    /// Selected model file inside `<support>/models/` (nil = automatic: the
    /// first *.gguf alphabetically, or `ADAMANCIA_VAULT_LLM_MODEL`).
    public var modelFileName: String?
    /// Off = classification falls back to the deterministic stub (debugging).
    public var engineEnabled: Bool
    /// llama context window; bounds the static prefix + suffix + output.
    public var contextTokens: Int
    /// Logical batch size for prompt prefill.
    public var batchTokens: Int
    /// Whether to offload all layers to the GPU (off = CPU-only inference).
    public var gpuOffload: Bool
    /// Hard cap on generated tokens per decision (the contract needs ~2).
    public var maximumOutputTokens: Int
    /// 0 = greedy (the measured contract); >0 samples with this temperature.
    public var temperature: Double
    /// Whether the grammar includes the reserved "none" decline literal.
    public var allowDecline: Bool
    /// Most tags a single video may keep after mapping (pipeline cap). Defaults
    /// to 1 (single most-confident tag — highest precision); the user raises it
    /// to opt into multi-tag recall. Secondaries above 1 are confidence-gated in
    /// the pipeline. Clamped 1–16.
    public var maximumTags: Int
    /// Ascending probability thresholds mapping the chosen token's renormalized
    /// softmax onto confidence 2, 3, 4, 5 (below the first threshold = 1).
    public var confidenceThresholds: [Double]
    /// Free-text tagging preferences appended to the cached static prefix.
    public var houseRules: String
    /// Bound for distinct GGUF engines kept warm by the per-type registry.
    public var maxResidentModels: Int

    public init(
        modelFileName: String? = nil,
        engineEnabled: Bool = true,
        contextTokens: Int = 4_096,
        batchTokens: Int = 512,
        gpuOffload: Bool = true,
        maximumOutputTokens: Int = 16,
        temperature: Double = 0,
        allowDecline: Bool = true,
        maximumTags: Int = 1,
        confidenceThresholds: [Double] = [0.20, 0.40, 0.60, 0.85],
        houseRules: String = "",
        maxResidentModels: Int = Self.defaultMaxResidentModels
    ) {
        self.modelFileName = modelFileName.flatMap { $0.isEmpty ? nil : String($0.prefix(255)) }
        self.engineEnabled = engineEnabled
        self.contextTokens = min(32_768, max(1_024, contextTokens))
        self.batchTokens = min(2_048, max(64, batchTokens))
        self.gpuOffload = gpuOffload
        self.maximumOutputTokens = min(128, max(4, maximumOutputTokens))
        self.temperature = min(2.0, max(0, temperature))
        self.allowDecline = allowDecline
        self.maximumTags = min(16, max(1, maximumTags))
        let cleaned = confidenceThresholds
            .map { min(0.999, max(0.001, $0)) }
            .sorted()
        self.confidenceThresholds = cleaned.count == 4 ? cleaned : [0.20, 0.40, 0.60, 0.85]
        self.houseRules = String(houseRules.prefix(4_000))
        self.maxResidentModels = min(Self.maximumResidentModels, max(1, maxResidentModels))
    }

    private enum CodingKeys: String, CodingKey {
        case modelFileName, engineEnabled, contextTokens, batchTokens, gpuOffload
        case maximumOutputTokens, temperature, allowDecline, maximumTags
        case confidenceThresholds, houseRules, maxResidentModels
    }

    /// Existing installations gain the residency cap without invalidating
    /// their hand-authored local-model settings.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            modelFileName: try container.decodeIfPresent(String.self, forKey: .modelFileName),
            engineEnabled: try container.decodeIfPresent(Bool.self, forKey: .engineEnabled) ?? true,
            contextTokens: try container.decodeIfPresent(Int.self, forKey: .contextTokens) ?? 4_096,
            batchTokens: try container.decodeIfPresent(Int.self, forKey: .batchTokens) ?? 512,
            gpuOffload: try container.decodeIfPresent(Bool.self, forKey: .gpuOffload) ?? true,
            maximumOutputTokens: try container.decodeIfPresent(Int.self, forKey: .maximumOutputTokens) ?? 16,
            temperature: try container.decodeIfPresent(Double.self, forKey: .temperature) ?? 0,
            allowDecline: try container.decodeIfPresent(Bool.self, forKey: .allowDecline) ?? true,
            maximumTags: try container.decodeIfPresent(Int.self, forKey: .maximumTags) ?? 1,
            confidenceThresholds: try container.decodeIfPresent([Double].self, forKey: .confidenceThresholds) ?? [0.20, 0.40, 0.60, 0.85],
            houseRules: try container.decodeIfPresent(String.self, forKey: .houseRules) ?? "",
            maxResidentModels: try container.decodeIfPresent(Int.self, forKey: .maxResidentModels) ?? Self.defaultMaxResidentModels
        )
    }
}

/// The effective per-request local-model controls a classifier type may
/// override. The GGUF choice lives separately on `ClassifierTypeAsset`, while
/// context/runtime knobs remain app-wide for every resident engine.
public struct LocalModelOverrides: Codable, Equatable, Sendable {
    /// Default when a type does not override it: thumbnail OCR evidence is ON.
    public static let defaultThumbnailOcrEvidence = true

    public var houseRules: String?
    public var allowDecline: Bool?
    public var confidenceThresholds: [Double]?
    /// Per-type: whether the browser extension OCRs the thumbnail and sends its
    /// text as classification evidence. nil = inherit the default (ON).
    public var thumbnailOcrEvidence: Bool?

    public init(
        houseRules: String? = nil,
        allowDecline: Bool? = nil,
        confidenceThresholds: [Double]? = nil,
        thumbnailOcrEvidence: Bool? = nil
    ) {
        self.houseRules = houseRules.map { String($0.prefix(4_000)) }
        self.allowDecline = allowDecline
        if let confidenceThresholds {
            let cleaned = confidenceThresholds
                .filter(\.isFinite)
                .map { min(0.999, max(0.001, $0)) }
                .sorted()
            self.confidenceThresholds = cleaned.count == 4 ? cleaned : nil
        } else {
            self.confidenceThresholds = nil
        }
        self.thumbnailOcrEvidence = thumbnailOcrEvidence
    }

    /// Effective value with the default applied.
    public var effectiveThumbnailOcrEvidence: Bool {
        thumbnailOcrEvidence ?? Self.defaultThumbnailOcrEvidence
    }

    public var isEmpty: Bool {
        houseRules == nil && allowDecline == nil && confidenceThresholds == nil && thumbnailOcrEvidence == nil
    }
}

public enum ResearchTrigger: String, Codable, Equatable, Sendable, CaseIterable {
    case declineOnly
    case declineAndLowConfidence
    case correctionsOnly
    case all

    public var includesLiveClassification: Bool {
        self == .declineOnly || self == .declineAndLowConfidence || self == .all
    }

    public var includesLowConfidence: Bool {
        self == .declineAndLowConfidence || self == .all
    }

    public var includesCorrections: Bool {
        self == .correctionsOnly || self == .all
    }
}

/// How the grounded-research step obtains public web evidence.
public enum ResearchSearchMode: String, Codable, Equatable, Sendable, CaseIterable {
    /// A separate raw-search provider (Serper/You.com) supplies snippets, which
    /// a language-model provider then distills. Needs two provider profiles.
    case rawSearchProvider
    /// The language-model provider searches natively (e.g. Gemini google_search)
    /// and distills in one call. Needs only the grounding-capable LLM provider.
    case providerGrounding
}

public struct ResearchSettings: Codable, Equatable, Sendable {
    public static let maximumRequestsPerMinute = 120
    public static let maximumDailyTokenLimit = 10_000_000
    public static let maximumSubjectsPerVideo = ResearchTask.maximumSubjects
    public static let defaultCooldownHours = 24
    public static let maximumCooldownHours = 720
    public static let defaultConfidenceTriggerLevel = 2
    public static let defaultSearchResultCount = 5
    public static let maximumSearchResultCount = 5
    public static let defaultSnippetContextChars = 16_000
    public static let minimumSnippetContextChars = 512
    public static let maximumSnippetContextChars = 19_000
    public static let defaultKnowledgeTTLDays = 0
    public static let maximumKnowledgeTTLDays = 3_650
    public static let defaultMaxKnowledgePerVideo = 8
    public static let maximumKnowledgePerVideo = 32

    /// Explicit opt-in. When false, classification performs no extra decode,
    /// queue work, credential lookup, or network request.
    public var enabled: Bool
    public var searchMode: ResearchSearchMode
    public var llmProviderProfileID: String?
    public var llmModelIdentifier: String?
    public var webSearchProviderProfileID: String?
    public var requestsPerMinute: Int
    public var dailyTokenLimit: Int
    public var maxSubjectsPerVideo: Int
    public var cooldownHours: Int
    public var trigger: ResearchTrigger
    public var confidenceTriggerLevel: Int
    public var searchResultCount: Int
    public var snippetContextChars: Int
    public var knowledgeTTLDays: Int
    public var maxKnowledgePerVideo: Int

    public init(
        enabled: Bool = false,
        searchMode: ResearchSearchMode = .rawSearchProvider,
        llmProviderProfileID: String? = nil,
        llmModelIdentifier: String? = nil,
        webSearchProviderProfileID: String? = nil,
        requestsPerMinute: Int = 6,
        dailyTokenLimit: Int = 10_000,
        maxSubjectsPerVideo: Int = 3,
        cooldownHours: Int = Self.defaultCooldownHours,
        trigger: ResearchTrigger = .declineOnly,
        confidenceTriggerLevel: Int = Self.defaultConfidenceTriggerLevel,
        searchResultCount: Int = Self.defaultSearchResultCount,
        snippetContextChars: Int = Self.defaultSnippetContextChars,
        knowledgeTTLDays: Int = Self.defaultKnowledgeTTLDays,
        maxKnowledgePerVideo: Int = Self.defaultMaxKnowledgePerVideo
    ) {
        self.enabled = enabled
        self.searchMode = searchMode
        self.llmProviderProfileID = Self.optionalIdentifier(llmProviderProfileID)
        self.llmModelIdentifier = Self.optionalIdentifier(llmModelIdentifier)
        self.webSearchProviderProfileID = Self.optionalIdentifier(webSearchProviderProfileID)
        self.requestsPerMinute = min(Self.maximumRequestsPerMinute, max(1, requestsPerMinute))
        self.dailyTokenLimit = min(Self.maximumDailyTokenLimit, max(1, dailyTokenLimit))
        self.maxSubjectsPerVideo = min(Self.maximumSubjectsPerVideo, max(1, maxSubjectsPerVideo))
        self.cooldownHours = min(Self.maximumCooldownHours, max(1, cooldownHours))
        self.trigger = trigger
        self.confidenceTriggerLevel = min(5, max(1, confidenceTriggerLevel))
        self.searchResultCount = min(Self.maximumSearchResultCount, max(1, searchResultCount))
        self.snippetContextChars = min(
            Self.maximumSnippetContextChars,
            max(Self.minimumSnippetContextChars, snippetContextChars)
        )
        self.knowledgeTTLDays = min(Self.maximumKnowledgeTTLDays, max(0, knowledgeTTLDays))
        self.maxKnowledgePerVideo = min(Self.maximumKnowledgePerVideo, max(1, maxKnowledgePerVideo))
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, searchMode, llmProviderProfileID, llmModelIdentifier, webSearchProviderProfileID
        case requestsPerMinute, dailyTokenLimit, maxSubjectsPerVideo, cooldownHours
        case trigger, confidenceTriggerLevel, searchResultCount, snippetContextChars
        case knowledgeTTLDays, maxKnowledgePerVideo
    }

    /// Settings persisted before granular research controls inherit the exact
    /// defaults that reproduce the former queue and prompt behavior.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false,
            searchMode: try container.decodeIfPresent(ResearchSearchMode.self, forKey: .searchMode) ?? .rawSearchProvider,
            llmProviderProfileID: try container.decodeIfPresent(String.self, forKey: .llmProviderProfileID),
            llmModelIdentifier: try container.decodeIfPresent(String.self, forKey: .llmModelIdentifier),
            webSearchProviderProfileID: try container.decodeIfPresent(String.self, forKey: .webSearchProviderProfileID),
            requestsPerMinute: try container.decodeIfPresent(Int.self, forKey: .requestsPerMinute) ?? 6,
            dailyTokenLimit: try container.decodeIfPresent(Int.self, forKey: .dailyTokenLimit) ?? 10_000,
            maxSubjectsPerVideo: try container.decodeIfPresent(Int.self, forKey: .maxSubjectsPerVideo) ?? 3,
            cooldownHours: try container.decodeIfPresent(Int.self, forKey: .cooldownHours) ?? Self.defaultCooldownHours,
            trigger: try container.decodeIfPresent(ResearchTrigger.self, forKey: .trigger) ?? .declineOnly,
            confidenceTriggerLevel: try container.decodeIfPresent(Int.self, forKey: .confidenceTriggerLevel) ?? Self.defaultConfidenceTriggerLevel,
            searchResultCount: try container.decodeIfPresent(Int.self, forKey: .searchResultCount) ?? Self.defaultSearchResultCount,
            snippetContextChars: try container.decodeIfPresent(Int.self, forKey: .snippetContextChars) ?? Self.defaultSnippetContextChars,
            knowledgeTTLDays: try container.decodeIfPresent(Int.self, forKey: .knowledgeTTLDays) ?? Self.defaultKnowledgeTTLDays,
            maxKnowledgePerVideo: try container.decodeIfPresent(Int.self, forKey: .maxKnowledgePerVideo) ?? Self.defaultMaxKnowledgePerVideo
        )
    }

    private static func optionalIdentifier(_ value: String?) -> String? {
        let cleaned = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return cleaned.isEmpty ? nil : String(cleaned.prefix(256))
    }
}

public struct ClassifierSettings: Codable, Equatable, Sendable {
    /// This is only a persisted local preference. A separately configured
    /// transport must still make every manifest request and activation.
    public var packageUpdateMode: PackageUpdateMode
    public var localLLM: LocalLLMSettings
    public var research: ResearchSettings

    public init(
        packageUpdateMode: PackageUpdateMode = .automatic,
        localLLM: LocalLLMSettings = LocalLLMSettings(),
        research: ResearchSettings = ResearchSettings()
    ) {
        self.packageUpdateMode = packageUpdateMode
        self.localLLM = localLLM
        self.research = research
    }

    private enum CodingKeys: String, CodingKey {
        case packageUpdateMode, localLLM, research
    }

    private enum RetiredCodingKeys: String, CodingKey {
        // allowIdleWork / allowBackgroundSync gated the retired pre-LLM local
        // training path; nothing consumes them since the per-video rework.
        case resourceProfile, cacheCapacity, allowLocalLLMAudit, allowIdleWork, allowBackgroundSync
    }

    /// Local state predating package preferences must remain usable offline.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Read the retired keys only to make old settings harmless. They are
        // never retained or written again.
        _ = try decoder.container(keyedBy: RetiredCodingKeys.self)
        self.init(
            packageUpdateMode: try container.decodeIfPresent(PackageUpdateMode.self, forKey: .packageUpdateMode) ?? .automatic,
            localLLM: try container.decodeIfPresent(LocalLLMSettings.self, forKey: .localLLM) ?? LocalLLMSettings(),
            research: try container.decodeIfPresent(ResearchSettings.self, forKey: .research) ?? ResearchSettings()
        )
    }
}
