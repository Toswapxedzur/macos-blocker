import Foundation

// A classifier type: its tree/dataset/platform binding and its per-type dial
// positions, house rules and research switch (nil = follow the global setting).
// (Split out of the former WorkspaceAssets.swift; CLASSIFIER-INDEPENDENCE §7.)

public struct ClassifierTypeAsset: Codable, Equatable, Sendable, Identifiable {
    public static let maximumNameLength = 128

    public var id: String
    public var name: String
    public var treeID: String
    public var treeRevision: Int
    public var datasetID: String
    public var datasetRevision: Int
    /// One platform binding supplies this type's tree and collected local
    /// classification data. A type cannot combine platform sources.
    public var applicablePlatformID: String?
    /// This type's own dial positions and house rules (nil / empty = follow the
    /// global settings). Runtime constants apply to every resident engine.
    public var localModelOverrides: LocalModelOverrides?
    /// Grounded research for this type: nil follows the global switch, false
    /// turns it off here, true keeps it on — but the app-wide research consent
    /// remains the master gate either way.
    public var researchEnabled: Bool?
    /// Position in the reorderable classifier-type list. Types targeting the
    /// same platform apply in ascending order; a card unions their tags in this
    /// order.
    public var order: Int
    public var updatedAtMilliseconds: Int64

    public init(
        id: String = UUID().uuidString,
        name: String,
        treeID: String,
        treeRevision: Int,
        datasetID: String,
        datasetRevision: Int,
        applicablePlatformID: String? = nil,
        localModelOverrides: LocalModelOverrides? = nil,
        researchEnabled: Bool? = nil,
        order: Int = 0,
        updatedAtMilliseconds: Int64 = WorkspaceCatalog.now()
    ) {
        self.id = id
        self.name = name
        self.treeID = treeID
        self.treeRevision = treeRevision
        self.datasetID = datasetID
        self.datasetRevision = datasetRevision
        let cleanedPlatformID = applicablePlatformID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.applicablePlatformID = cleanedPlatformID.isEmpty ? nil : cleanedPlatformID
        self.localModelOverrides = localModelOverrides?.isEmpty == false ? localModelOverrides : nil
        self.researchEnabled = researchEnabled
        self.order = order
        self.updatedAtMilliseconds = updatedAtMilliseconds
    }

    /// The GGUF this type loads when it holds its own Speed↔Quality position
    /// (nil = the global tier's file).
    public var modelFileName: String? { localModelOverrides?.speedQuality?.ggufFileName }

    private enum CodingKeys: String, CodingKey {
        case id, name, treeID, treeRevision, datasetID, datasetRevision, applicablePlatformID,
             localModelOverrides, researchEnabled, order, updatedAtMilliseconds
        // Pre-dial keys (before 2026-09-23), read only to find the nearest position.
        case modelFileName, researchOverrides
    }


    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        treeID = try container.decode(String.self, forKey: .treeID)
        treeRevision = try container.decode(Int.self, forKey: .treeRevision)
        datasetID = try container.decode(String.self, forKey: .datasetID)
        datasetRevision = try container.decode(Int.self, forKey: .datasetRevision)
        let decodedPlatformID = (try container.decodeIfPresent(String.self, forKey: .applicablePlatformID)?.trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
        applicablePlatformID = decodedPlatformID.isEmpty ? nil : decodedPlatformID
        var decodedOverrides = try container.decodeIfPresent(LocalModelOverrides.self, forKey: .localModelOverrides)
            ?? LocalModelOverrides()
        // A pre-dial per-type model file becomes that tier's position.
        if decodedOverrides.speedQuality == nil,
           let legacyTier = SpeedQualityDial.nearest(
               modelFileName: try container.decodeIfPresent(String.self, forKey: .modelFileName)) {
            decodedOverrides.speedQuality = legacyTier
        }
        localModelOverrides = decodedOverrides.isEmpty ? nil : decodedOverrides
        if let explicit = try container.decodeIfPresent(Bool.self, forKey: .researchEnabled) {
            researchEnabled = explicit
        } else if let legacy = try? container.decodeIfPresent(ResearchSettings.self, forKey: .researchOverrides) {
            // Pre-dial per-type research profiles keep only their on/off switch.
            researchEnabled = legacy.enabled
        } else {
            researchEnabled = nil
        }
        order = try container.decodeIfPresent(Int.self, forKey: .order) ?? 0
        updatedAtMilliseconds = try container.decodeIfPresent(Int64.self, forKey: .updatedAtMilliseconds)
            ?? WorkspaceCatalog.now()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(treeID, forKey: .treeID)
        try container.encode(treeRevision, forKey: .treeRevision)
        try container.encode(datasetID, forKey: .datasetID)
        try container.encode(datasetRevision, forKey: .datasetRevision)
        try container.encodeIfPresent(applicablePlatformID, forKey: .applicablePlatformID)
        try container.encodeIfPresent(localModelOverrides, forKey: .localModelOverrides)
        try container.encodeIfPresent(researchEnabled, forKey: .researchEnabled)
        try container.encode(order, forKey: .order)
        try container.encode(updatedAtMilliseconds, forKey: .updatedAtMilliseconds)
    }
}
