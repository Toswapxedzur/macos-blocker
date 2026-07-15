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
    public var surface: EntrySurface
    public var evidence: EvidencePayload
    public var policyIDs: [String]

    public var id: String { requestID }

    public init(requestID: String = UUID().uuidString, platform: String, entryID: String? = nil, sourceID: String? = nil, surface: EntrySurface, evidence: EvidencePayload, policyIDs: [String] = []) {
        self.requestID = requestID
        self.platform = platform
        self.entryID = entryID
        self.sourceID = sourceID
        self.surface = surface
        self.evidence = evidence
        self.policyIDs = policyIDs
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
    public static let titleLimit = 500
    public static let textLimit = 16_000
    public static let summaryLimit = 16_000
    public static let tagLimit = 64
    public static let tagLengthLimit = 256
    public static let metadataLimit = 64

    public init() {}

    public func validate(_ entry: EntryEvidence) throws {
        try required(entry.requestID, field: "requestID", limit: Self.requestIDLimit)
        try required(entry.platform, field: "platform", limit: Self.platformLimit)
        try optional(entry.entryID, field: "entryID", limit: Self.entryIDLimit)
        try optional(entry.sourceID, field: "sourceID", limit: Self.sourceIDLimit)
        try optional(entry.evidence.title, field: "title", limit: Self.titleLimit)
        try optional(entry.evidence.text, field: "text", limit: Self.textLimit)
        try optional(entry.evidence.summary, field: "summary", limit: Self.summaryLimit)
        guard entry.evidence.suppliedTags.count <= Self.tagLimit else { throw EntryEvidenceValidationError.exceedsLimit("suppliedTags", Self.tagLimit) }
        guard entry.evidence.metadata.count <= Self.metadataLimit else { throw EntryEvidenceValidationError.exceedsLimit("metadata", Self.metadataLimit) }
        for tag in entry.evidence.suppliedTags {
            try required(tag, field: "suppliedTags[]", limit: Self.tagLengthLimit)
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

/// A policy-level audit outcome. It is intentionally separate from model confidence:
/// an apparently confident result can still be a false allow or false restriction.
public enum PolicyAuditGrade: String, Codable, Equatable, Sendable, CaseIterable {
    case correctAllow
    case correctDimOrBlock
    case falseAllow
    case falseDimOrBlock
    case insufficientEvidence
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

    public func auditGrade(correction: UserCorrection? = nil) -> PolicyAuditGrade {
        if evidenceState != .sufficient { return .insufficientEvidence }
        switch correction {
        case .falseAllow: return .falseAllow
        case .falseDim, .falseBlock: return .falseDimOrBlock
        case nil: return strongestAction == .allow ? .correctAllow : .correctDimOrBlock
        }
    }
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
    public var allowLocalLLMAudit: Bool
    /// This is only a persisted local preference. A separately configured
    /// transport must still make every manifest request and activation.
    public var packageUpdateMode: PackageUpdateMode

    public init(
        resourceProfile: ResourceProfile = .balanced,
        cacheCapacity: Int? = nil,
        allowIdleWork: Bool = true,
        allowBackgroundSync: Bool = true,
        allowLocalLLMAudit: Bool = false,
        packageUpdateMode: PackageUpdateMode = .automatic
    ) {
        self.resourceProfile = resourceProfile
        self.cacheCapacity = max(1, cacheCapacity ?? resourceProfile.defaultCacheCapacity)
        self.allowIdleWork = allowIdleWork
        self.allowBackgroundSync = allowBackgroundSync
        self.allowLocalLLMAudit = allowLocalLLMAudit
        self.packageUpdateMode = packageUpdateMode
    }

    private enum CodingKeys: String, CodingKey {
        case resourceProfile, cacheCapacity, allowIdleWork, allowBackgroundSync, allowLocalLLMAudit, packageUpdateMode
    }

    /// Local state predating package preferences must remain usable offline.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let resourceProfile = try container.decodeIfPresent(ResourceProfile.self, forKey: .resourceProfile) ?? .balanced
        self.init(
            resourceProfile: resourceProfile,
            cacheCapacity: try container.decodeIfPresent(Int.self, forKey: .cacheCapacity),
            allowIdleWork: try container.decodeIfPresent(Bool.self, forKey: .allowIdleWork) ?? true,
            allowBackgroundSync: try container.decodeIfPresent(Bool.self, forKey: .allowBackgroundSync) ?? true,
            allowLocalLLMAudit: try container.decodeIfPresent(Bool.self, forKey: .allowLocalLLMAudit) ?? false,
            packageUpdateMode: try container.decodeIfPresent(PackageUpdateMode.self, forKey: .packageUpdateMode) ?? .automatic
        )
    }
}
