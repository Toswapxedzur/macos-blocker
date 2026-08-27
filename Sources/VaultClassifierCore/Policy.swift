import Foundation

public struct NamedPolicy: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var includeAnyTagIDs: [String]
    public var includeAllTagIDs: [String]
    public var excludeTagIDs: [String]
    public var feedAction: PresentationAction
    public var pageAction: PresentationAction
    /// Minimum `ScoredTag.confidence` (1...5) a predicted tag must reach before it
    /// counts toward this policy's include/exclude matching. A block dims real
    /// content, so low-confidence tags are ignored by default — the user tunes
    /// this per policy. Below the floor a tag is treated as if absent.
    public var confidenceFloor: Int
    /// What to do with content that has no tag at or above the floor — i.e. the
    /// model declined, or only produced low-confidence guesses. `.allow` (the
    /// default) never hides content we could not confidently classify.
    public var untaggedAction: PresentationAction

    public static let defaultConfidenceFloor = 4

    public init(
        id: String,
        name: String,
        includeAnyTagIDs: [String] = [],
        includeAllTagIDs: [String] = [],
        excludeTagIDs: [String] = [],
        feedAction: PresentationAction = .dim,
        pageAction: PresentationAction = .block,
        confidenceFloor: Int = NamedPolicy.defaultConfidenceFloor,
        untaggedAction: PresentationAction = .allow
    ) {
        self.id = id
        self.name = name
        self.includeAnyTagIDs = includeAnyTagIDs
        self.includeAllTagIDs = includeAllTagIDs
        self.excludeTagIDs = excludeTagIDs
        self.feedAction = feedAction
        self.pageAction = pageAction == .dim ? .block : pageAction
        self.confidenceFloor = min(5, max(1, confidenceFloor))
        self.untaggedAction = untaggedAction
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, includeAnyTagIDs, includeAllTagIDs, excludeTagIDs
        case feedAction, pageAction, confidenceFloor, untaggedAction
    }

    // Back-compat decode: policies persisted before the content-block rewire lack
    // confidenceFloor / untaggedAction, so both default rather than fail to load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let floor = try c.decodeIfPresent(Int.self, forKey: .confidenceFloor) ?? NamedPolicy.defaultConfidenceFloor
        self.init(
            id: try c.decode(String.self, forKey: .id),
            name: try c.decode(String.self, forKey: .name),
            includeAnyTagIDs: try c.decodeIfPresent([String].self, forKey: .includeAnyTagIDs) ?? [],
            includeAllTagIDs: try c.decodeIfPresent([String].self, forKey: .includeAllTagIDs) ?? [],
            excludeTagIDs: try c.decodeIfPresent([String].self, forKey: .excludeTagIDs) ?? [],
            feedAction: try c.decodeIfPresent(PresentationAction.self, forKey: .feedAction) ?? .dim,
            pageAction: try c.decodeIfPresent(PresentationAction.self, forKey: .pageAction) ?? .block,
            confidenceFloor: floor,
            untaggedAction: try c.decodeIfPresent(PresentationAction.self, forKey: .untaggedAction) ?? .allow
        )
    }
}

public extension NamedPolicy {
    /// One predicted tag with the confidence the model assigned it.
    struct TagObservation: Sendable, Equatable {
        public var tagID: String
        public var confidence: Int
        public init(tagID: String, confidence: Int) {
            self.tagID = tagID
            self.confidence = confidence
        }
    }

    /// Resolve this policy against a video's predicted tags into the surface
    /// actions the blocker should apply. Content-based, not creator-based: the
    /// decision is a function of *what the content is*.
    ///
    /// Semantics:
    /// - Tags below `confidenceFloor` are ignored (never hide on a weak guess).
    /// - No qualifying tag → `untaggedAction` (declined/low-confidence content).
    /// - A qualifying tag in `excludeTagIDs` → disallowed (the user said "not this").
    /// - An include set that isn't satisfied → disallowed (allow-only / "only this").
    /// - Otherwise → `.allow`.
    /// Disallowed content takes `feedAction` on feeds and `pageAction` on pages.
    func resolveActions(for tags: [TagObservation]) -> (feed: PresentationAction, page: PresentationAction) {
        let qualifying = Set(tags.filter { $0.confidence >= confidenceFloor }.map(\.tagID))
        if qualifying.isEmpty { return (untaggedAction, untaggedAction) }

        let excludeHit = !qualifying.isDisjoint(with: Set(excludeTagIDs))
        let includeDefined = !includeAnyTagIDs.isEmpty || !includeAllTagIDs.isEmpty
        let includeAnyOK = includeAnyTagIDs.isEmpty || !qualifying.isDisjoint(with: Set(includeAnyTagIDs))
        let includeAllOK = Set(includeAllTagIDs).isSubset(of: qualifying)
        let includeSatisfied = includeAnyOK && includeAllOK

        let disallowed = excludeHit || (includeDefined && !includeSatisfied)
        return disallowed ? (feedAction, pageAction) : (.allow, .allow)
    }
}

public enum StarterPolicies {
    public static let clashRoyale = NamedPolicy(
        id: "clash-royale-focus",
        name: "Clash Royale focus",
        includeAnyTagIDs: ["content.entities.clash-royale"],
        feedAction: .dim,
        pageAction: .block
    )
}
