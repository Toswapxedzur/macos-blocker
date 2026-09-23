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

    public var id: String { requestID }

    public init(requestID: String = UUID().uuidString, platform: String, entryID: String? = nil, sourceID: String? = nil, sourceAliases: [String] = [], surface: EntrySurface, evidence: EvidencePayload) {
        self.requestID = requestID
        self.platform = platform
        self.entryID = entryID
        self.sourceID = sourceID
        self.sourceAliases = sourceAliases
        self.surface = surface
        self.evidence = evidence
    }

    private enum CodingKeys: String, CodingKey {
        case requestID, platform, entryID, sourceID, sourceAliases, surface, evidence
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


/// The normalized tag-count bounds for one classification: how many tags the
/// grammar may emit. This is the SINGLE place the invariants live —
/// `0 ≤ minimum ≤ maximum ≤ 16` —
/// so the settings, per-type overrides, the pipeline, and the store can never
/// disagree about what "min/max" resolve to. Every site that used to
/// re-derive these clamps now builds a `TagBounds` instead.
public struct TagBounds: Equatable, Sendable {
    public let minimum: Int
    public let maximum: Int

    public init(minimum: Int, maximum: Int) {
        let cappedMaximum = min(16, max(1, maximum))
        let cappedMinimum = min(cappedMaximum, max(0, minimum))
        self.maximum = cappedMaximum
        self.minimum = cappedMinimum
    }
}

/// The local model's settings: the two dials plus house rules. Everything else
/// the engine needs is a constant here (owner decision 2026-09-23: replace all
/// parameters with Speed↔Quality and Strict↔Broad). State written before that
/// day decodes to the nearest dial positions.
public struct LocalLLMSettings: Codable, Equatable, Sendable {
    /// Which model tier runs (the GGUF comes from the catalog).
    public var speedQuality: SpeedQualityDial
    /// How many tags a video may carry and how sure the model must be to keep an extra one.
    public var strictness: StrictnessDial
    /// Free-text tagging preferences appended to the cached static prefix.
    public var houseRules: String

    // MARK: Runtime constants (were settings until 2026-09-23)

    /// llama context window; bounds the static prefix + suffix + output.
    public static let contextTokens = 4_096
    /// Logical batch size for prompt prefill.
    public static let batchTokens = 512
    /// All layers on the GPU.
    public static let gpuOffload = true
    /// Hard cap on generated tokens per decision (a three-tag reply needs ~12).
    public static let maximumOutputTokens = 16
    /// Greedy decoding (the measured contract).
    public static let temperature: Double = 0
    /// The grammar includes the reserved "none" decline literal (position 5 of
    /// the strictness dial removes it through `minimumTags`).
    public static let allowDecline = true
    /// Ascending probability thresholds mapping the chosen token's renormalized
    /// softmax onto confidence 2, 3, 4, 5 (below the first threshold = 1).
    public static let confidenceThresholds: [Double] = [0.20, 0.40, 0.60, 0.85]
    /// Distinct GGUF engines kept warm by the per-type registry (a type on
    /// another tier than the global one loads a second engine).
    public static let maxResidentModels = 2
    public static let maximumResidentModels = 4
    public static let maximumHouseRulesLength = 4_000

    public init(
        speedQuality: SpeedQualityDial = .default,
        strictness: StrictnessDial = .default,
        houseRules: String = ""
    ) {
        self.speedQuality = speedQuality
        self.strictness = strictness
        self.houseRules = String(houseRules.prefix(Self.maximumHouseRulesLength))
    }

    // MARK: Derived values the engine and pipeline read

    /// The GGUF file the global tier loads.
    public var modelFileName: String { speedQuality.ggufFileName }
    public var maximumTags: Int { strictness.maximumTags }
    public var minimumTags: Int { strictness.minimumTags }
    public var extraTagMinimumOdds: Double { strictness.extraTagMinimumOdds }
    public var contextTokens: Int { Self.contextTokens }
    public var batchTokens: Int { Self.batchTokens }
    public var gpuOffload: Bool { Self.gpuOffload }
    public var maximumOutputTokens: Int { Self.maximumOutputTokens }
    public var temperature: Double { Self.temperature }
    public var allowDecline: Bool { Self.allowDecline }
    public var confidenceThresholds: [Double] { Self.confidenceThresholds }
    public var maxResidentModels: Int { Self.maxResidentModels }

    private enum CodingKeys: String, CodingKey {
        case speedQuality, strictness, houseRules
        // Pre-dial keys, read only to find the nearest position.
        case modelFileName, maximumTags, minimumTags, extraTagMinimumOdds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let storedSpeed = try container.decodeIfPresent(String.self, forKey: .speedQuality)
        let legacyModelFileName = try container.decodeIfPresent(String.self, forKey: .modelFileName)
        let speedQuality = SpeedQualityDial.resolve(storedSpeed)
            ?? SpeedQualityDial.nearest(modelFileName: legacyModelFileName)
            ?? .default
        let storedStrictness = try container.decodeIfPresent(Int.self, forKey: .strictness)
        let legacyMaximumTags = try container.decodeIfPresent(Int.self, forKey: .maximumTags)
        let legacyMinimumTags = try container.decodeIfPresent(Int.self, forKey: .minimumTags)
        let legacyOdds = try container.decodeIfPresent(Double.self, forKey: .extraTagMinimumOdds)
        let strictness = StrictnessDial.resolve(storedStrictness)
            ?? StrictnessDial.nearest(maximumTags: legacyMaximumTags, minimumTags: legacyMinimumTags, extraTagMinimumOdds: legacyOdds)
            ?? .default
        self.init(
            speedQuality: speedQuality,
            strictness: strictness,
            houseRules: try container.decodeIfPresent(String.self, forKey: .houseRules) ?? ""
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(speedQuality, forKey: .speedQuality)
        try container.encode(strictness, forKey: .strictness)
        try container.encode(houseRules, forKey: .houseRules)
    }
}

/// What a classifier type may set for itself: its own dial positions (nil =
/// follow the global dial) and its own house rules (which replace the global
/// rules). Runtime constants are app-wide for every resident engine.
public struct LocalModelOverrides: Codable, Equatable, Sendable {
    public var houseRules: String?
    public var speedQuality: SpeedQualityDial?
    public var strictness: StrictnessDial?

    public init(
        houseRules: String? = nil,
        speedQuality: SpeedQualityDial? = nil,
        strictness: StrictnessDial? = nil
    ) {
        self.houseRules = houseRules.map { String($0.prefix(LocalLLMSettings.maximumHouseRulesLength)) }
        self.speedQuality = speedQuality
        self.strictness = strictness
    }

    /// The effective strictness: the per-type position when set, else the global.
    public func effectiveStrictness(global: LocalLLMSettings) -> StrictnessDial {
        strictness ?? global.strictness
    }

    /// Effective tag-count bounds (0 ≤ min ≤ max) for the effective strictness.
    public func effectiveTagBounds(global: LocalLLMSettings) -> TagBounds {
        effectiveStrictness(global: global).tagBounds
    }

    public var isEmpty: Bool {
        houseRules == nil && speedQuality == nil && strictness == nil
    }

    private enum CodingKeys: String, CodingKey {
        case houseRules, speedQuality, strictness
        // Pre-dial keys, read only to find the nearest position.
        case maximumTags, minimumTags
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let storedStrictness = try container.decodeIfPresent(Int.self, forKey: .strictness)
        let legacyMaximumTags = try container.decodeIfPresent(Int.self, forKey: .maximumTags)
        let legacyMinimumTags = try container.decodeIfPresent(Int.self, forKey: .minimumTags)
        let strictness = StrictnessDial.resolve(storedStrictness)
            ?? StrictnessDial.nearest(maximumTags: legacyMaximumTags, minimumTags: legacyMinimumTags, extraTagMinimumOdds: nil)
        let storedSpeed = try container.decodeIfPresent(String.self, forKey: .speedQuality)
        self.init(
            houseRules: try container.decodeIfPresent(String.self, forKey: .houseRules),
            speedQuality: SpeedQualityDial.resolve(storedSpeed),
            strictness: strictness
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(houseRules, forKey: .houseRules)
        try container.encodeIfPresent(speedQuality, forKey: .speedQuality)
        try container.encodeIfPresent(strictness, forKey: .strictness)
    }
}

/// When to research a CREATOR — the ONLY automatic research trigger. Every
/// creator carries a score (`CreatorResearchAccumulator`): a video that could not
/// be tagged adds 1, a shaky tag a fraction, a sure tag nothing; the score halves
/// every `halfLifeDays`; reaching `score` researches the creator once.
///
/// Fixed at 3 / 14 days since 2026-09-23 (the values the owner chose on
/// 2026-09-21; simulated on 4,999 real videos / 1,464 creators, 41% untagged:
/// 2 → 219 creators, 3 → 70, 4 → 43, 5 → 37). Tests and harnesses may still
/// pass another threshold to the accumulator directly.
public struct AuthorResearchThreshold: Equatable, Sendable {
    public static let defaultScore = 3.0
    public static let defaultHalfLifeDays = 14.0
    public static let maximumScore = 50.0
    public static let maximumHalfLifeDays = 365.0

    public var score: Double
    public var halfLifeDays: Double

    public init(score: Double = defaultScore, halfLifeDays: Double = defaultHalfLifeDays) {
        self.score = score.isFinite ? min(Self.maximumScore, max(0.5, score)) : Self.defaultScore
        self.halfLifeDays = halfLifeDays.isFinite ? min(Self.maximumHalfLifeDays, max(1, halfLifeDays)) : Self.defaultHalfLifeDays
    }
}

/// Grounded research: on/off plus the provider and model that answer. The
/// budgets, cooldown, creator trigger and knowledge limits are constants since
/// 2026-09-23; keys written before that day are ignored on decode.
public struct ResearchSettings: Codable, Equatable, Sendable {
    /// Explicit opt-in. When false, classification performs no queue work,
    /// credential lookup, or network request.
    public var enabled: Bool
    public var llmProviderProfileID: String?
    public var llmModelIdentifier: String?

    // MARK: Constants (were settings until 2026-09-23)

    /// Serialized background request limit.
    public static let requestsPerMinute = 6
    /// Persisted daily usage gate.
    public static let dailyTokenLimit = 10_000
    /// Hours before a failed subject is retried.
    public static let cooldownHours = 24
    public static let maximumCooldownHours = 720
    /// When to research a creator — the only automatic trigger.
    public static let authorThreshold = AuthorResearchThreshold()
    /// 0 = grounded knowledge never expires.
    public static let knowledgeTTLDays = 0
    public static let maximumKnowledgeTTLDays = 3_650
    /// Most matched knowledge entries injected into one prompt.
    public static let maxKnowledgePerVideo = 8
    public static let maximumKnowledgePerVideo = 32
    // Spellings the pipeline's defaults use.
    public static let defaultCooldownHours = cooldownHours
    public static let defaultKnowledgeTTLDays = knowledgeTTLDays
    public static let defaultMaxKnowledgePerVideo = maxKnowledgePerVideo

    public init(
        enabled: Bool = false,
        llmProviderProfileID: String? = nil,
        llmModelIdentifier: String? = nil
    ) {
        self.enabled = enabled
        self.llmProviderProfileID = Self.optionalIdentifier(llmProviderProfileID)
        self.llmModelIdentifier = Self.optionalIdentifier(llmModelIdentifier)
    }

    public var requestsPerMinute: Int { Self.requestsPerMinute }
    public var dailyTokenLimit: Int { Self.dailyTokenLimit }
    public var cooldownHours: Int { Self.cooldownHours }
    public var authorThreshold: AuthorResearchThreshold { Self.authorThreshold }
    public var knowledgeTTLDays: Int { Self.knowledgeTTLDays }
    public var maxKnowledgePerVideo: Int { Self.maxKnowledgePerVideo }

    private enum CodingKeys: String, CodingKey {
        case enabled, llmProviderProfileID, llmModelIdentifier
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false,
            llmProviderProfileID: try container.decodeIfPresent(String.self, forKey: .llmProviderProfileID),
            llmModelIdentifier: try container.decodeIfPresent(String.self, forKey: .llmModelIdentifier)
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


    /// Local state predating package preferences must remain usable offline.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            packageUpdateMode: try container.decodeIfPresent(PackageUpdateMode.self, forKey: .packageUpdateMode) ?? .automatic,
            localLLM: try container.decodeIfPresent(LocalLLMSettings.self, forKey: .localLLM) ?? LocalLLMSettings(),
            research: try container.decodeIfPresent(ResearchSettings.self, forKey: .research) ?? ResearchSettings()
        )
    }
}
