import Foundation

// The platform registry (source kind, definition) and the per-platform binding.
// (Split out of the former WorkspaceAssets.swift; CLASSIFIER-INDEPENDENCE §7.)

public enum CollectionSourceKind: String, Equatable, Sendable, CaseIterable {
    case creator
    case account
    case subreddit
    case server
}

public struct CollectionPlatformDefinition: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var browser: String
    /// The durable local source that groups a platform's collected entries.
    /// It is a creator for video platforms, but a subreddit, account, or
    /// server where that is the platform's real public-content source.
    public var sourceKind: CollectionSourceKind
    /// Only a registered adapter can send collection requests today. The
    /// remaining platform entries are intentionally selectable now so their
    /// local tree/dataset binding exists before an adapter is added.
    public var collectorAvailable: Bool
    /// A manual-only platform can retain public entries and human tags, but
    /// cannot use the on-device video classifier.
    public var supportsLocalModel: Bool
    /// The optional local public-data API profile that belongs to this
    /// platform. A missing value means the platform keeps local collected data
    /// only; it never causes a generic provider profile to be selected.
    public var apiProviderType: APIKeyProviderType? {
        switch id {
        case "youtube": return .youtubeData
        case "facebook": return .facebookGraph
        case "instagram": return .instagramGraph
        case "twitch": return .twitch
        case "reddit": return .reddit
        case "twitter": return .xPlatform
        case "discord", "bilibili": return nil
        default: return nil
        }
    }

    public init(
        id: String,
        name: String,
        browser: String = CollectionPlatformRegistry.browserDescription,
        sourceKind: CollectionSourceKind = .creator,
        collectorAvailable: Bool = false,
        supportsLocalModel: Bool = true
    ) {
        self.id = id
        self.name = name
        self.browser = browser
        self.sourceKind = sourceKind
        self.collectorAvailable = collectorAvailable
        self.supportsLocalModel = supportsLocalModel
    }
}

public enum CollectionPlatformRegistry {
    public static var browserDescription: String {
        #if os(Windows)
        return "Chrome and Edge"
        #else
        return "Chrome, Edge and Safari"
        #endif
    }
    public static let definitions: [CollectionPlatformDefinition] = [
        .init(id: "youtube", name: "YouTube", collectorAvailable: true),
        // Only YouTube, Bilibili, Reddit and X classify (owner 2026-09-30).
        .init(id: "facebook", name: "Facebook", collectorAvailable: true, supportsLocalModel: false),
        .init(id: "instagram", name: "Instagram", collectorAvailable: true, supportsLocalModel: false),
        .init(id: "twitch", name: "Twitch", collectorAvailable: true, supportsLocalModel: false),
        .init(id: "reddit", name: "Reddit", sourceKind: .subreddit, collectorAvailable: true),
        .init(id: "discord", name: "Discord", sourceKind: .server, collectorAvailable: true, supportsLocalModel: false),
        .init(id: "twitter", name: "Twitter / X", sourceKind: .account, collectorAvailable: true),
        .init(id: "bilibili", name: "Bilibili", collectorAvailable: true),
    ]

    public static func definition(for id: String) -> CollectionPlatformDefinition? {
        definitions.first(where: { $0.id == id })
    }
}

public struct PlatformBinding: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var browser: String
    public var treeID: String
    public var datasetID: String
    /// The reusable decision configuration selected for this platform.
    public var activeClassifierTypeID: String?
    /// Raw public-content collection is on by default for a newly added local
    /// platform binding. The browser still sends nothing unless this binding
    /// exists and its extension-side collection setting is also on.
    public var collectionEnabled: Bool
    /// Days to keep this platform's collected entries: -1 = the same as all
    /// platforms (`WorkspaceCatalog.collectionKeepDays`), 0 = forever.
    public var collectionKeepDays: Int

    public init(id: String, name: String, browser: String = CollectionPlatformRegistry.browserDescription, treeID: String, datasetID: String, activeClassifierTypeID: String? = nil, collectionEnabled: Bool = true, collectionKeepDays: Int = -1) {
        self.id = id
        self.name = name
        self.browser = browser
        self.treeID = treeID
        self.datasetID = datasetID
        self.activeClassifierTypeID = activeClassifierTypeID
        self.collectionEnabled = collectionEnabled
        self.collectionKeepDays = max(-1, collectionKeepDays)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, browser, treeID, datasetID, activeClassifierTypeID, collectionEnabled, collectionKeepDays
    }


    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        browser = try container.decodeIfPresent(String.self, forKey: .browser) ?? CollectionPlatformRegistry.browserDescription
        treeID = try container.decode(String.self, forKey: .treeID)
        datasetID = try container.decode(String.self, forKey: .datasetID)
        activeClassifierTypeID = try container.decodeIfPresent(String.self, forKey: .activeClassifierTypeID)
        collectionEnabled = try container.decodeIfPresent(Bool.self, forKey: .collectionEnabled) ?? true
        if let keep = try container.decodeIfPresent(Int.self, forKey: .collectionKeepDays) {
            collectionKeepDays = max(-1, keep)
        } else {
            // Saved before per-platform Keep (owner 2026-09-30): every platform
            // was switched on by default then; a platform nothing classifies now
            // records only when the person turns it on.
            collectionKeepDays = -1
            if CollectionPlatformRegistry.definition(for: id)?.supportsLocalModel != true { collectionEnabled = false }
        }
    }
}
