import Foundation

// The tag tree: nodes, canvas positions and the tree asset (+ its lookup helpers).
// (Split out of the former WorkspaceAssets.swift; CLASSIFIER-INDEPENDENCE §7.)

public extension TagTreeAsset {
    /// Converts the editable tree into the taxonomy used by the per-video LLM
    /// pipeline. Retired tags remain structural ancestors but are not eligible.
    func inferenceTaxonomy() throws -> Taxonomy {
        try Taxonomy(nodes: nodes.map { node in
            .init(
                id: node.id,
                name: node.name,
                description: node.description,
                parentID: node.parentID,
                predictable: !node.isRetired,
                lightColorHex: node.lightColorHex,
                darkColorHex: node.darkColorHex
            )
        })
    }
}

public struct TagTreeNode: Codable, Equatable, Sendable, Identifiable {
    public static let maximumDescriptionLength = 1_024

    public var id: String
    public var name: String
    /// Optional local context shown only in the tag editor and supplied with
    /// this eligible tag to an explicit LLM classification request.
    public var description: String?
    public var parentID: String?
    public var isRetired: Bool
    /// Algorithmically paired display colors. Both are persisted after their
    /// first assignment so later tree edits never recolor an existing tag.
    public var lightColorHex: String?
    public var darkColorHex: String?
    /// A node's local canvas coordinates are presentation data, separate from
    /// its semantic parent relation and tree revision.
    public var positionX: Double?
    public var positionY: Double?

    public init(id: String = UUID().uuidString, name: String, description: String? = nil, parentID: String? = nil, isRetired: Bool = false, lightColorHex: String? = nil, darkColorHex: String? = nil, positionX: Double? = nil, positionY: Double? = nil) {
        self.id = id
        self.name = name
        let cleanedDescription = description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.description = cleanedDescription.isEmpty ? nil : String(cleanedDescription.prefix(Self.maximumDescriptionLength))
        self.parentID = parentID
        self.isRetired = isRetired
        self.lightColorHex = TagColorAssignment.normalizedHex(lightColorHex)
        self.darkColorHex = TagColorAssignment.normalizedHex(darkColorHex)
        self.positionX = positionX
        self.positionY = positionY
    }

    /// The web canvas must always receive a concrete position. Legacy nodes
    /// predate free placement, so only those use this stable display fallback;
    /// an explicit zero remains a real user-authored coordinate.
    public func resolvedCanvasPosition(index: Int) -> TagTreeCanvasPosition {
        if let positionX, let positionY,
           positionX.isFinite, positionY.isFinite,
           positionX >= 0, positionY >= 0 {
            return .init(x: positionX, y: positionY)
        }
        return .init(x: 24 + Double(index % 4) * 154, y: 24 + Double(index / 4) * 48)
    }
}

public struct TagTreeCanvasPosition: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct TagTreeAsset: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var revision: Int
    public var nodes: [TagTreeNode]
    /// Persisted separately from semantic tree revision so a presentation-only
    /// color migration runs exactly once without invalidating semantic revisions.
    public var colorAlgorithmVersion: Int
    public var updatedAtMilliseconds: Int64

    public init(id: String = UUID().uuidString, name: String, revision: Int = 1, nodes: [TagTreeNode], colorAlgorithmVersion: Int = TagColorAssignment.currentAlgorithmVersion, updatedAtMilliseconds: Int64 = WorkspaceCatalog.now()) {
        self.id = id
        self.name = name
        self.revision = revision
        self.nodes = nodes
        self.colorAlgorithmVersion = colorAlgorithmVersion
        self.updatedAtMilliseconds = updatedAtMilliseconds
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, revision, nodes, colorAlgorithmVersion, updatedAtMilliseconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        revision = try container.decode(Int.self, forKey: .revision)
        nodes = try container.decode([TagTreeNode].self, forKey: .nodes)
        colorAlgorithmVersion = try container.decodeIfPresent(Int.self, forKey: .colorAlgorithmVersion) ?? 0
        updatedAtMilliseconds = try container.decode(Int64.self, forKey: .updatedAtMilliseconds)
    }

    /// Returns the selected node and every reachable descendant. The visited
    /// set also makes an invalid cyclic legacy tree safe to traverse.
    public func subtreeNodeIDs(rootID: String) -> Set<String> {
        guard nodes.contains(where: { $0.id == rootID }) else { return [] }
        var nodeIDs: Set<String> = []
        var pendingIDs = [rootID]

        while let nodeID = pendingIDs.popLast(), nodeIDs.insert(nodeID).inserted {
            pendingIDs.append(contentsOf: nodes.compactMap { node in
                node.parentID == nodeID ? node.id : nil
            })
        }
        return nodeIDs
    }
}
