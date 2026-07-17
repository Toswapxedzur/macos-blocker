import Foundation

/// Where an on-device label came from. Neither browsing activity nor an LLM
/// response is a label on its own: every row in this store represents a person
/// deliberately confirming a local classification decision.
public enum LocalTrainingLabelOrigin: String, Codable, Equatable, Sendable {
    case explicitUser
    case confirmedPersonalAudit
}

/// A durable, local-only supervised example. `cacheKey` makes a newer label for
/// the same entry replace the old one instead of silently overweighting it.
public struct LocalTrainingExample: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var cacheKey: String
    public var evidence: EntryEvidence
    public var positiveLeafTagIDs: [String]
    public var negativeLeafTagIDs: [String]
    public var origin: LocalTrainingLabelOrigin
    public var taxonomyVersion: String
    public var createdAtMilliseconds: Int64
    public var updatedAtMilliseconds: Int64

    public init(
        id: UUID = UUID(),
        cacheKey: String,
        evidence: EntryEvidence,
        positiveLeafTagIDs: [String],
        negativeLeafTagIDs: [String] = [],
        origin: LocalTrainingLabelOrigin,
        taxonomyVersion: String,
        createdAtMilliseconds: Int64,
        updatedAtMilliseconds: Int64
    ) {
        self.id = id
        self.cacheKey = cacheKey
        self.evidence = evidence
        self.positiveLeafTagIDs = positiveLeafTagIDs.sorted()
        self.negativeLeafTagIDs = negativeLeafTagIDs.sorted()
        self.origin = origin
        self.taxonomyVersion = taxonomyVersion
        self.createdAtMilliseconds = createdAtMilliseconds
        self.updatedAtMilliseconds = updatedAtMilliseconds
    }
}

/// Metadata for a reproducible local model rebuild. It deliberately contains
/// counts and model identity only; labels and evidence remain in the local
/// state store and are never included in diagnostics.
public struct LocalTrainingRun: Codable, Equatable, Sendable {
    public var exampleCount: Int
    public var labelUpdateCount: Int
    public var epochs: Int
    public var taxonomyVersion: String
    public var completedAtMilliseconds: Int64

    public init(
        exampleCount: Int,
        labelUpdateCount: Int,
        epochs: Int,
        taxonomyVersion: String,
        completedAtMilliseconds: Int64
    ) {
        self.exampleCount = exampleCount
        self.labelUpdateCount = labelUpdateCount
        self.epochs = epochs
        self.taxonomyVersion = taxonomyVersion
        self.completedAtMilliseconds = completedAtMilliseconds
    }
}

/// A FIFO local corpus. Capacity follows the user's local retention setting,
/// so keeping more cached entries also permits keeping more explicit labels.
public struct LocalTrainingCorpus: Codable, Equatable, Sendable {
    public var examples: [LocalTrainingExample]
    public var lastRun: LocalTrainingRun?

    public init(examples: [LocalTrainingExample] = [], lastRun: LocalTrainingRun? = nil) {
        self.examples = examples
        self.lastRun = lastRun
    }

    public mutating func upsert(_ example: LocalTrainingExample, limit: Int) {
        if let index = examples.firstIndex(where: { $0.cacheKey == example.cacheKey }) {
            var replacement = example
            replacement.id = examples[index].id
            replacement.createdAtMilliseconds = examples[index].createdAtMilliseconds
            examples[index] = replacement
        } else {
            examples.append(example)
        }
        trim(to: limit)
    }

    public mutating func trim(to limit: Int) {
        let boundedLimit = max(1, limit)
        if examples.count > boundedLimit {
            examples.removeFirst(examples.count - boundedLimit)
        }
    }
}

public enum LocalTrainingError: Error, Equatable, LocalizedError, Sendable {
    case noLabels
    case overlappingLabels
    case unknownLeafTag(String)
    case noCompatibleExamples
    case invalidEpochCount

    public var errorDescription: String? {
        switch self {
        case .noLabels:
            return "Store at least one positive or negative leaf label."
        case .overlappingLabels:
            return "A leaf tag cannot be both positive and negative."
        case .unknownLeafTag(let tagID):
            return "\(tagID) is not a predictable leaf in the active taxonomy."
        case .noCompatibleExamples:
            return "No retained local labels match the active taxonomy."
        case .invalidEpochCount:
            return "Training epochs must be between 1 and 12."
        }
    }
}
