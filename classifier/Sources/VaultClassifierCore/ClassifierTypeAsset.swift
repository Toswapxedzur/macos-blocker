import Foundation

// A classifier type: its tree/dataset/platform binding and its per-type dial
// positions, house rules and research switch. Dials are independent per group.
// (Split out of the former WorkspaceAssets.swift; CLASSIFIER-INDEPENDENCE §7.)

public struct ClassifierTypeAsset: Codable, Equatable, Sendable, Identifiable {
    public static let maximumNameLength = 128

    public var id: String
    public var name: String
    public var treeID: String
    public var treeRevision: Int
    public var datasetID: String
    public var datasetRevision: Int
    /// The platforms this type classifies (owner 2026-09-30: one type may take
    /// several; a platform belongs to at most one type — WorkspaceCatalog). Their
    /// bindings share the one collected dataset.
    public var applicablePlatformIDs: [String]
    /// This group owns concrete dial positions and house rules.
    public var tagging: TaggingSettings
    public var classificationProvider: ClassificationProvider
    public var chatGPT: ChatGPTClassificationSettings
    /// Pauses new automatic classification for this group without deleting it.
    public var isPaused: Bool
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
        applicablePlatformIDs: [String] = [],
        tagging: TaggingSettings = .init(),
        classificationProvider: ClassificationProvider = .chatGPT,
        chatGPT: ChatGPTClassificationSettings = .init(),
        isPaused: Bool = false,
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
        self.applicablePlatformIDs = Self.cleanedPlatformIDs(applicablePlatformIDs)
        self.tagging = tagging
        self.classificationProvider = classificationProvider
        self.chatGPT = chatGPT
        self.isPaused = isPaused
        self.researchEnabled = researchEnabled
        self.order = order
        self.updatedAtMilliseconds = updatedAtMilliseconds
    }

    /// Trimmed, non-empty and each once, in the given order.
    public static func cleanedPlatformIDs(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, treeID, treeRevision, datasetID, datasetRevision, applicablePlatformIDs,
             tagging, classificationProvider, chatGPT, isPaused, researchEnabled, order, updatedAtMilliseconds
        // Pre-dial keys (before 2026-09-23), read only to find the nearest position.
        case retiredLocalModel = "localModel"
        case researchOverrides
        // The single platform of before 2026-09-30, read once into the list.
        case applicablePlatformID
    }


    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        treeID = try container.decode(String.self, forKey: .treeID)
        treeRevision = try container.decode(Int.self, forKey: .treeRevision)
        datasetID = try container.decode(String.self, forKey: .datasetID)
        datasetRevision = try container.decode(Int.self, forKey: .datasetRevision)
        if let list = try container.decodeIfPresent([String].self, forKey: .applicablePlatformIDs) {
            applicablePlatformIDs = Self.cleanedPlatformIDs(list)
        } else {
            applicablePlatformIDs = Self.cleanedPlatformIDs([try container.decodeIfPresent(String.self, forKey: .applicablePlatformID) ?? ""])
        }
        tagging = try container.decodeIfPresent(TaggingSettings.self, forKey: .tagging)
            ?? container.decodeIfPresent(TaggingSettings.self, forKey: .retiredLocalModel) ?? .init()
        classificationProvider = try container.decodeIfPresent(ClassificationProvider.self, forKey: .classificationProvider) ?? .chatGPT
        chatGPT = try container.decodeIfPresent(ChatGPTClassificationSettings.self, forKey: .chatGPT) ?? .init()
        isPaused = (try? container.decodeIfPresent(Bool.self, forKey: .isPaused)) ?? false
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
        try container.encode(applicablePlatformIDs, forKey: .applicablePlatformIDs)
        try container.encode(tagging, forKey: .tagging)
        try container.encode(classificationProvider, forKey: .classificationProvider)
        try container.encode(chatGPT, forKey: .chatGPT)
        try container.encode(isPaused, forKey: .isPaused)
        try container.encodeIfPresent(researchEnabled, forKey: .researchEnabled)
        try container.encode(order, forKey: .order)
        try container.encode(updatedAtMilliseconds, forKey: .updatedAtMilliseconds)
    }
}
