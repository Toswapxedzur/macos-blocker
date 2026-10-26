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
/// so the group settings, the pipeline, and the store can never
/// disagree about what "min/max" resolve to. Every site that used to
/// re-derive these clamps now builds a `TagBounds` instead.
public struct TagBounds: Codable, Equatable, Sendable {
    public let minimum: Int
    public let maximum: Int

    public init(minimum: Int, maximum: Int) {
        let cappedMaximum = min(16, max(1, maximum))
        let cappedMinimum = min(cappedMaximum, max(0, minimum))
        self.maximum = cappedMaximum
        self.minimum = cappedMinimum
    }
}

/// Per-group tagging strictness, house rules and optional tag bounds.
public struct TaggingSettings: Codable, Equatable, Sendable {
    public var strictness: StrictnessDial
    public var houseRules: String
    public var minimumTagsOverride: Int?
    public var maximumTagsOverride: Int?
    public static let maximumTagCountOverride = 3
    public static let maximumHouseRulesLength = 4_000

    public init(strictness: StrictnessDial = .default, houseRules: String = "", minimumTagsOverride: Int? = nil, maximumTagsOverride: Int? = nil) {
        self.strictness = strictness
        self.houseRules = String(houseRules.prefix(Self.maximumHouseRulesLength))
        self.minimumTagsOverride = minimumTagsOverride.flatMap { (0...Self.maximumTagCountOverride).contains($0) ? $0 : nil }
        self.maximumTagsOverride = maximumTagsOverride.flatMap { (1...Self.maximumTagCountOverride).contains($0) ? $0 : nil }
        if (self.minimumTagsOverride ?? strictness.minimumTags) > (self.maximumTagsOverride ?? strictness.maximumTags) {
            self.minimumTagsOverride = nil; self.maximumTagsOverride = nil
        }
    }
    public var tagBounds: TagBounds { .init(minimum: minimumTagsOverride ?? strictness.minimumTags, maximum: maximumTagsOverride ?? strictness.maximumTags) }
    public var maximumTags: Int { tagBounds.maximum }
    public var minimumTags: Int { tagBounds.minimum }
    public var extraTagMinimumOdds: Double { strictness.extraTagMinimumOdds }

    private enum CodingKeys: String, CodingKey { case strictness, houseRules, minimumTagsOverride, maximumTagsOverride }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(strictness: StrictnessDial.resolve(try c.decodeIfPresent(Int.self, forKey: .strictness)) ?? .default,
            houseRules: try c.decodeIfPresent(String.self, forKey: .houseRules) ?? "",
            minimumTagsOverride: try? c.decodeIfPresent(Int.self, forKey: .minimumTagsOverride),
            maximumTagsOverride: try? c.decodeIfPresent(Int.self, forKey: .maximumTagsOverride))
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
    public var chatGPTDailyRequestLimit: Int?
    public var research: ResearchSettings
    public var classificationEnabled: Bool
    public var dictionaries: DictionarySettings

    public init(
        research: ResearchSettings = ResearchSettings(),
        classificationEnabled: Bool = true,
        dictionaries: DictionarySettings = .init(),
        chatGPTDailyRequestLimit: Int? = nil
    ) {
        self.research = research
        self.classificationEnabled = classificationEnabled
        self.dictionaries = dictionaries
        self.chatGPTDailyRequestLimit = chatGPTDailyRequestLimit
    }

    private enum CodingKeys: String, CodingKey {
        case research, classificationEnabled, dictionaries, chatGPTDailyRequestLimit
    }


    /// Retired package-update keys are ignored, including malformed values.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            research: try container.decodeIfPresent(ResearchSettings.self, forKey: .research) ?? ResearchSettings(),
            classificationEnabled: (try? container.decodeIfPresent(Bool.self, forKey: .classificationEnabled)) ?? true,
            dictionaries: (try? container.decodeIfPresent(DictionarySettings.self, forKey: .dictionaries)) ?? .init(),
            chatGPTDailyRequestLimit: try container.decodeIfPresent(Int.self, forKey: .chatGPTDailyRequestLimit)
        )
    }
}
