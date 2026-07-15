import Foundation

public struct TagNode: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var parentID: String?
    public var predictable: Bool

    public init(id: String, name: String, parentID: String? = nil, predictable: Bool = true) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.predictable = predictable
    }

    private enum CodingKeys: String, CodingKey { case id, name, parentID, predictable }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        parentID = try container.decodeIfPresent(String.self, forKey: .parentID)
        predictable = try container.decodeIfPresent(Bool.self, forKey: .predictable) ?? true
    }
}

public enum TaxonomyError: Error, Equatable, LocalizedError, Sendable {
    case duplicateID(String)
    case missingParent(nodeID: String, parentID: String)
    case cycle(String)

    public var errorDescription: String? {
        switch self {
        case .duplicateID(let id): return "Taxonomy contains duplicate id \(id)."
        case .missingParent(let nodeID, let parentID): return "Node \(nodeID) refers to missing parent \(parentID)."
        case .cycle(let id): return "Taxonomy has a parent cycle at \(id)."
        }
    }
}

public struct Taxonomy: Sendable {
    public let nodes: [String: TagNode]
    private let childIDsByParentID: [String: Set<String>]

    public init(nodes: [TagNode]) throws {
        var mapping: [String: TagNode] = [:]
        for node in nodes {
            guard mapping[node.id] == nil else { throw TaxonomyError.duplicateID(node.id) }
            mapping[node.id] = node
        }
        for node in nodes {
            if let parentID = node.parentID, mapping[parentID] == nil {
                throw TaxonomyError.missingParent(nodeID: node.id, parentID: parentID)
            }
        }
        for node in nodes {
            var visited = Set<String>()
            var cursor: String? = node.id
            while let current = cursor {
                guard visited.insert(current).inserted else { throw TaxonomyError.cycle(current) }
                cursor = mapping[current]?.parentID
            }
        }
        self.nodes = mapping
        var children: [String: Set<String>] = [:]
        for node in nodes {
            if let parentID = node.parentID {
                children[parentID, default: []].insert(node.id)
            }
        }
        self.childIDsByParentID = children
    }

    public var predictableLeafIDs: Set<String> {
        Set(nodes.values.filter { $0.predictable && (childIDsByParentID[$0.id] ?? []).isEmpty }.map(\.id))
    }

    public func ancestorIDs(for tagID: String) -> [String] {
        var result: [String] = []
        var cursor = nodes[tagID]?.parentID
        while let current = cursor, let node = nodes[current] {
            result.append(current)
            cursor = node.parentID
        }
        return result
    }

    public func isDescendant(_ tagID: String, of ancestorID: String) -> Bool {
        tagID == ancestorID || ancestorIDs(for: tagID).contains(ancestorID)
    }

    public func ancestorClosure(for leafIDs: [String]) -> [String] {
        Array(Set(leafIDs.flatMap(ancestorIDs(for:)))).sorted()
    }
}
