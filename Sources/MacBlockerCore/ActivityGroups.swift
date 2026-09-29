import Foundation

/// A user-made group of apps and websites in Activity (owner 2026-09-29): a
/// convenient way to see stats together. Every group can be viewed (picked in
/// Details); a merge group also stands in for its members everywhere — the
/// Usage list, the strip, the pie, the day bars — in one colour. So an item can
/// be in many groups but in at most one merge group.
public struct ActivityGroup: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var merge: Bool
    /// Member ids: "app|<bundle id>" or "web|<domain>".
    public var members: [String]

    public init(id: String, name: String, merge: Bool, members: [String]) {
        self.id = id
        self.name = name
        self.merge = merge
        self.members = members
    }
}

/// A group as the page draws it: with its permanent colour.
public struct ActivityGroupView: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var merge: Bool
    public var members: [String]
    public var colorIndex: Int
}

/// An app or website a group can hold (the editor's list).
public struct ActivityKnownItem: Codable, Equatable, Sendable {
    /// "app|<bundle id>" or "web|<domain>".
    public var id: String
    public var label: String
    public var seconds: Double
}

/// Why a group was not saved.
public enum ActivityGroupRefusal: Error, Equatable, Sendable {
    /// The name is empty.
    case noName
    /// A member id is not "app|…" / "web|…".
    case badMember(String)
    /// Merge group members already in another merge group: member → that group's name.
    case inAnotherMergeGroup([String: String])
    /// No group has this id.
    case unknownGroup

    public var message: String {
        switch self {
        case .noName: return "a group needs a name"
        case .badMember(let id): return "\"\(id)\" is not an app or a website"
        case .inAnotherMergeGroup(let owners):
            return owners.keys.sorted().map { "\($0) is already in the merge group \"\(owners[$0] ?? "")\"" }.joined(separator: "; ")
        case .unknownGroup: return "no such group"
        }
    }
}

public enum ActivityGroups {
    static let maxNameLength = 60
    static let maxMemberLength = 256

    public static func isMemberID(_ id: String) -> Bool {
        (id.hasPrefix("app|") || id.hasPrefix("web|")) && id.count > 4 && id.count <= maxMemberLength
    }

    /// `group` saved into `groups` (new when its id is unknown or empty). A
    /// merge group may not take a member another merge group has — unless
    /// `move`, which takes it out of that group. Returns the new list, or why not.
    public static func saving(
        _ group: ActivityGroup,
        into groups: [ActivityGroup],
        move: Bool,
        newID: () -> String
    ) -> Result<(groups: [ActivityGroup], id: String), ActivityGroupRefusal> {
        var group = group
        group.name = String(group.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxNameLength))
        guard !group.name.isEmpty else { return .failure(.noName) }
        var seen = Set<String>()
        group.members = group.members.filter { seen.insert($0).inserted }
        if let bad = group.members.first(where: { !isMemberID($0) }) { return .failure(.badMember(bad)) }
        if group.id.isEmpty || !groups.contains(where: { $0.id == group.id }) {
            group.id = group.id.isEmpty ? newID() : group.id
        }
        var result = groups
        if group.merge {
            let taken = Set(group.members)
            var owners: [String: String] = [:]
            for other in result where other.merge && other.id != group.id {
                for member in other.members where taken.contains(member) { owners[member] = other.name }
            }
            if !owners.isEmpty {
                guard move else { return .failure(.inAnotherMergeGroup(owners)) }
                for index in result.indices where result[index].merge && result[index].id != group.id {
                    result[index].members.removeAll { taken.contains($0) }
                }
            }
        }
        if let index = result.firstIndex(where: { $0.id == group.id }) {
            result[index] = group
        } else {
            result.append(group)
        }
        return .success((result, group.id))
    }

    /// Which merge group each member belongs to (member id → group id).
    public static func mergeOwners(_ groups: [ActivityGroup]) -> [String: String] {
        var owners: [String: String] = [:]
        for group in groups where group.merge {
            for member in group.members where owners[member] == nil { owners[member] = group.id }
        }
        return owners
    }
}
