import Foundation

/// Validation lives beside the local policy data rather than in a browser UI so
/// every future adapter receives the same bounded, taxonomy-safe policy set.
public enum PolicyValidationError: Error, Equatable, LocalizedError, Sendable {
    case emptyID
    case nonCanonicalID(String)
    case invalidID(String)
    case duplicateID(String)
    case emptyName
    case missingPositiveCriterion(String)
    case unknownTag(policyID: String, tagID: String)

    public var errorDescription: String? {
        switch self {
        case .emptyID: return "A policy needs an identifier."
        case .nonCanonicalID(let id): return "Policy identifier \(id) has surrounding whitespace."
        case .invalidID(let id): return "Policy identifier \(id) is not valid."
        case .duplicateID(let id): return "Policy identifier \(id) is duplicated."
        case .emptyName: return "A policy needs a name."
        case .missingPositiveCriterion(let id): return "Policy \(id) must include at least one tag criterion (include or exclude)."
        case .unknownTag(let policyID, let tagID): return "Policy \(policyID) refers to unknown tag \(tagID)."
        }
    }
}

public struct PolicyCatalog: Sendable {
    public static let identifierLimit = 128
    public static let nameLimit = 160
    public static let criteriaLimit = 128
    public let taxonomy: Taxonomy
    /// Every tag id a policy may reference. The seed taxonomy alone is not
    /// enough: content-block policies act on the tags the *classifier* emits,
    /// which come from the user's own tree(s) (UUID ids), so those must be
    /// accepted too — otherwise a working disallow policy can never be saved.
    private let validTagIDs: Set<String>

    public init(taxonomy: Taxonomy, additionalValidTagIDs: Set<String> = []) {
        self.taxonomy = taxonomy
        self.validTagIDs = Set(taxonomy.nodes.keys).union(additionalValidTagIDs)
    }

    public func validate(_ policies: [NamedPolicy]) throws {
        var identifiers = Set<String>()
        for policy in policies {
            try validate(policy)
            guard identifiers.insert(policy.id).inserted else {
                throw PolicyValidationError.duplicateID(policy.id)
            }
        }
    }

    public func validate(_ policy: NamedPolicy) throws {
        let identifier = policy.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty else { throw PolicyValidationError.emptyID }
        // Policy IDs are persisted and used by browser/native callers as stable
        // keys. Do not silently accept an ID that validates only after trimming:
        // this layer cannot normalize and write the replacement back atomically.
        guard identifier == policy.id else {
            throw PolicyValidationError.nonCanonicalID(policy.id)
        }
        guard identifier.count <= Self.identifierLimit,
              identifier.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil else {
            throw PolicyValidationError.invalidID(policy.id)
        }
        guard !policy.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              policy.name.count <= Self.nameLimit else {
            throw PolicyValidationError.emptyName
        }
        let criteria = policy.includeAnyTagIDs + policy.includeAllTagIDs + policy.excludeTagIDs
        guard criteria.count <= Self.criteriaLimit else {
            throw PolicyValidationError.invalidID(policy.id)
        }
        // At least one criterion — include (allow-only) OR exclude (disallow).
        // A pure disallow ("dim anything tagged Comedy & Memes") is valid.
        guard !policy.includeAnyTagIDs.isEmpty || !policy.includeAllTagIDs.isEmpty || !policy.excludeTagIDs.isEmpty else {
            throw PolicyValidationError.missingPositiveCriterion(policy.id)
        }
        for tagID in criteria where !validTagIDs.contains(tagID) {
            throw PolicyValidationError.unknownTag(policyID: policy.id, tagID: tagID)
        }
    }
}
