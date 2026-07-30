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

public enum ClassificationEvidenceState: String, Codable, Equatable, Sendable {
    case sufficient
    case limited
    case invalid
}

public struct TagScore: Codable, Equatable, Sendable, Identifiable {
    public var tagID: String
    public var directScore: Double
    public var sourceScore: Double?
    public var finalScore: Double

    public var id: String { tagID }

    public init(tagID: String, directScore: Double, sourceScore: Double?, finalScore: Double) {
        self.tagID = tagID
        self.directScore = directScore
        self.sourceScore = sourceScore
        self.finalScore = finalScore
    }
}

public struct PolicyDecision: Codable, Equatable, Sendable, Identifiable {
    public var policyID: String
    public var action: PresentationAction
    public var matchedTagIDs: [String]
    public var explanation: String

    public var id: String { policyID }

    public init(policyID: String, action: PresentationAction, matchedTagIDs: [String], explanation: String) {
        self.policyID = policyID
        self.action = action
        self.matchedTagIDs = matchedTagIDs
        self.explanation = explanation
    }
}

public struct ClassificationResult: Codable, Equatable, Sendable {
    public var entryID: String?
    public var sourceID: String?
    public var surface: EntrySurface
    public var evidenceState: ClassificationEvidenceState
    public var threshold: Double
    public var selectedLeafTagIDs: [String]
    public var ancestorTagIDs: [String]
    public var scores: [TagScore]
    public var decisions: [PolicyDecision]
    public var packageID: String
    public var modelVersion: String

    public init(entryID: String?, sourceID: String?, surface: EntrySurface, evidenceState: ClassificationEvidenceState, threshold: Double, selectedLeafTagIDs: [String], ancestorTagIDs: [String], scores: [TagScore], decisions: [PolicyDecision], packageID: String, modelVersion: String) {
        self.entryID = entryID
        self.sourceID = sourceID
        self.surface = surface
        self.evidenceState = evidenceState
        self.threshold = threshold
        self.selectedLeafTagIDs = selectedLeafTagIDs
        self.ancestorTagIDs = ancestorTagIDs
        self.scores = scores
        self.decisions = decisions
        self.packageID = packageID
        self.modelVersion = modelVersion
    }

    public var strongestAction: PresentationAction { decisions.map(\.action).max() ?? .allow }

}

public enum ResourceProfile: String, Codable, Sendable, CaseIterable {
    case light
    case balanced
    case aggressive

    public var defaultCacheCapacity: Int {
        switch self { case .light: return 10_000; case .balanced: return 50_000; case .aggressive: return 150_000 }
    }

    public var sourceObservationLimit: Int {
        switch self { case .light: return 150; case .balanced: return 500; case .aggressive: return 1_000 }
    }
}

public struct ClassifierSettings: Codable, Equatable, Sendable {
    public var resourceProfile: ResourceProfile
    public var cacheCapacity: Int
    public var allowIdleWork: Bool
    public var allowBackgroundSync: Bool
    /// This is only a persisted local preference. A separately configured
    /// transport must still make every manifest request and activation.
    public var packageUpdateMode: PackageUpdateMode

    public init(
        resourceProfile: ResourceProfile = .balanced,
        cacheCapacity: Int? = nil,
        allowIdleWork: Bool = true,
        allowBackgroundSync: Bool = true,
        packageUpdateMode: PackageUpdateMode = .automatic
    ) {
        self.resourceProfile = resourceProfile
        self.cacheCapacity = max(1, cacheCapacity ?? resourceProfile.defaultCacheCapacity)
        self.allowIdleWork = allowIdleWork
        self.allowBackgroundSync = allowBackgroundSync
        self.packageUpdateMode = packageUpdateMode
    }

    private enum CodingKeys: String, CodingKey {
        case resourceProfile, cacheCapacity, allowIdleWork, allowBackgroundSync, packageUpdateMode
    }

    private enum RetiredCodingKeys: String, CodingKey {
        case allowLocalLLMAudit
    }

    /// Local state predating package preferences must remain usable offline.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Read the retired key only to make old settings harmless. It is never
        // retained or written again.
        _ = try decoder.container(keyedBy: RetiredCodingKeys.self)
        let resourceProfile = try container.decodeIfPresent(ResourceProfile.self, forKey: .resourceProfile) ?? .balanced
        self.init(
            resourceProfile: resourceProfile,
            cacheCapacity: try container.decodeIfPresent(Int.self, forKey: .cacheCapacity),
            allowIdleWork: try container.decodeIfPresent(Bool.self, forKey: .allowIdleWork) ?? true,
            allowBackgroundSync: try container.decodeIfPresent(Bool.self, forKey: .allowBackgroundSync) ?? true,
            packageUpdateMode: try container.decodeIfPresent(PackageUpdateMode.self, forKey: .packageUpdateMode) ?? .automatic
        )
    }
}
