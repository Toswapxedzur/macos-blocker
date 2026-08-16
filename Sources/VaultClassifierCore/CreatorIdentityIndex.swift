import Foundation

/// Groups identity forms observed during collection so aliases such as a
/// YouTube handle and channel identifier render as one source.
public struct CreatorIdentityIndex: Sendable {
    private let groupByForm: [String: Set<String>]
    private let canonicalByForm: [String: String]

    public init(entries: [CollectedPlatformEntry] = []) {
        var parent: [String: String] = [:]

        func find(_ value: String) -> String {
            var root = value
            while let next = parent[root], next != root { root = next }
            return root
        }

        func union(_ lhs: String, _ rhs: String) {
            parent[lhs] = parent[lhs] ?? lhs
            parent[rhs] = parent[rhs] ?? rhs
            let lhsRoot = find(lhs)
            let rhsRoot = find(rhs)
            if lhsRoot != rhsRoot { parent[lhsRoot] = rhsRoot }
        }

        for entry in entries {
            parent[entry.creatorID] = parent[entry.creatorID] ?? entry.creatorID
            for alias in entry.sourceAliases { union(entry.creatorID, alias) }
        }

        var membersByRoot: [String: Set<String>] = [:]
        for form in parent.keys { membersByRoot[find(form), default: []].insert(form) }

        var groups: [String: Set<String>] = [:]
        var canonicals: [String: String] = [:]
        for members in membersByRoot.values {
            let canonical = Self.canonicalForm(members)
            for form in members {
                groups[form] = members
                canonicals[form] = canonical
            }
        }
        groupByForm = groups
        canonicalByForm = canonicals
    }

    public func members(of identifier: String) -> Set<String> {
        groupByForm[identifier] ?? [identifier]
    }

    public func canonical(of identifier: String) -> String {
        canonicalByForm[identifier] ?? identifier
    }

    static func canonicalForm(_ members: Set<String>) -> String {
        if let handle = members.filter({ $0.contains(":handle:") }).min() { return handle }
        return members.min() ?? ""
    }
}
