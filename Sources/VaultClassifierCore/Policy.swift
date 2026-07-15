import Foundation

public struct NamedPolicy: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var includeAnyTagIDs: [String]
    public var includeAllTagIDs: [String]
    public var excludeTagIDs: [String]
    public var feedAction: PresentationAction
    public var pageAction: PresentationAction

    public init(id: String, name: String, includeAnyTagIDs: [String] = [], includeAllTagIDs: [String] = [], excludeTagIDs: [String] = [], feedAction: PresentationAction = .dim, pageAction: PresentationAction = .block) {
        self.id = id
        self.name = name
        self.includeAnyTagIDs = includeAnyTagIDs
        self.includeAllTagIDs = includeAllTagIDs
        self.excludeTagIDs = excludeTagIDs
        self.feedAction = feedAction
        self.pageAction = pageAction == .dim ? .block : pageAction
    }
}

public struct PolicyEvaluator: Sendable {
    public let taxonomy: Taxonomy

    public init(taxonomy: Taxonomy) { self.taxonomy = taxonomy }

    public func evaluate(result: ClassificationResult, policies: [NamedPolicy], requestedPolicyIDs: [String]) -> [PolicyDecision] {
        guard result.evidenceState != .invalid, !result.selectedLeafTagIDs.isEmpty else { return [] }
        let requested = requestedPolicyIDs.isEmpty ? policies : policies.filter { requestedPolicyIDs.contains($0.id) }
        let selected = Set(result.selectedLeafTagIDs)
        return requested.compactMap { policy in
            let includesAny = policy.includeAnyTagIDs.isEmpty || policy.includeAnyTagIDs.contains { criterion in selected.contains { taxonomy.isDescendant($0, of: criterion) } }
            let includesAll = policy.includeAllTagIDs.allSatisfy { criterion in selected.contains { taxonomy.isDescendant($0, of: criterion) } }
            let excluded = policy.excludeTagIDs.contains { criterion in selected.contains { taxonomy.isDescendant($0, of: criterion) } }
            guard includesAny, includesAll, !excluded else { return nil }

            let matches = selected.filter { leaf in
                (policy.includeAnyTagIDs + policy.includeAllTagIDs).contains { taxonomy.isDescendant(leaf, of: $0) }
            }.sorted()
            let action = result.surface == .feed ? policy.feedAction : policy.pageAction
            let explanation = result.surface == .feed && action == .dim
                ? "Matched \(policy.name); dim this feed card."
                : "Matched \(policy.name)."
            return PolicyDecision(policyID: policy.id, action: action, matchedTagIDs: matches, explanation: explanation)
        }
    }
}
