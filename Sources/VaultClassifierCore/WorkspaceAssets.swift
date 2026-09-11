import Foundation

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

public struct VideoTagsProjection: Sendable, Equatable {
    public var tags: [TagNode]
    public var predicted: Bool
    /// Model confidence (1...5) per tag id, preserved from the stored
    /// `ScoredTag`s so tag-based block policy can gate on a confidence floor.
    /// A tag id absent here (e.g. a hand-built projection) is treated as max.
    public var confidenceByTagID: [String: Int]

    public init(tags: [TagNode], predicted: Bool, confidenceByTagID: [String: Int] = [:]) {
        self.tags = tags
        self.predicted = predicted
        self.confidenceByTagID = confidenceByTagID
    }
}

/// User-owned assets behind the five Vault Classifier workspaces. These remain
/// local profile data; neither a browser nor a provider may mutate them.
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

public struct CollectedPlatformEntry: Codable, Equatable, Sendable, Identifiable {
    public static let maximumRetainedEntries = 5_000
    public static let maximumAttributes = 16
    public static let maximumAttributeKeyLength = 64
    public static let maximumAttributeValueLength = 512
    public static let maximumSuppliedTags = EntryEvidenceValidator.tagLimit
    public static let maximumSourceAliases = EntryEvidenceValidator.sourceAliasLimit

    /// The platform's durable public-content identifier. It is scoped by
    /// `platformID`, so the same raw identifier on different platforms is
    /// retained independently.
    public var id: String
    public var platformID: String
    public var entryID: String
    public var creatorID: String
    /// Other identity forms observed for this creator alongside `creatorID`
    /// (e.g. the channel `UC…` seen with the `@handle`). The workspace unions
    /// these to treat one creator's forms as a single source for tags and
    /// de-duplication.
    public var sourceAliases: [String]
    public var creatorName: String
    /// A small, platform-provided content kind such as `video`, `short`,
    /// `live`, `post`, or `track`. Advertisement kinds are rejected before
    /// persistence.
    public var entryType: String
    public var title: String
    public var surface: EntrySurface
    public var text: String?
    public var summary: String?
    public var suppliedTags: [String]
    public var canonicalURL: String?
    public var sourceIconURL: String?
    public var attributes: [String: String]
    public var firstObservedAtMilliseconds: Int64
    public var lastObservedAtMilliseconds: Int64
    public var observationCount: Int

    public init(
        id: String,
        platformID: String,
        entryID: String,
        creatorID: String,
        sourceAliases: [String] = [],
        creatorName: String,
        entryType: String,
        title: String,
        surface: EntrySurface = .feed,
        text: String? = nil,
        summary: String? = nil,
        suppliedTags: [String] = [],
        canonicalURL: String? = nil,
        sourceIconURL: String? = nil,
        attributes: [String: String] = [:],
        firstObservedAtMilliseconds: Int64 = WorkspaceCatalog.now(),
        lastObservedAtMilliseconds: Int64 = WorkspaceCatalog.now(),
        observationCount: Int = 1
    ) {
        self.id = id
        self.platformID = platformID
        self.entryID = entryID
        self.creatorID = creatorID
        self.sourceAliases = Self.normalizedSourceAliases(sourceAliases, primary: creatorID, platformID: platformID)
        self.creatorName = creatorName
        self.entryType = entryType
        self.title = title
        self.surface = surface
        self.text = text
        self.summary = summary
        self.suppliedTags = Array(NSOrderedSet(array: suppliedTags)).compactMap { $0 as? String }.prefix(Self.maximumSuppliedTags).map(\.self)
        self.canonicalURL = canonicalURL
        self.sourceIconURL = sourceIconURL
        self.attributes = Self.reconciledAttributes(attributes)
        self.firstObservedAtMilliseconds = firstObservedAtMilliseconds
        self.lastObservedAtMilliseconds = lastObservedAtMilliseconds
        self.observationCount = max(1, observationCount)
    }

    public var deduplicationKey: String { "\(platformID)\u{1F}\(entryID)" }

    private enum CodingKeys: String, CodingKey {
        case id, platformID, entryID, creatorID, sourceAliases, creatorName, entryType, title
        case surface, text, summary, suppliedTags, canonicalURL, sourceIconURL
        case attributes, firstObservedAtMilliseconds, lastObservedAtMilliseconds, observationCount
    }

    /// Dedupes aliases, drops the primary and anything not scoped to the same
    /// platform, and caps the list — so an alias is always another same-platform
    /// identity of this creator.
    static func normalizedSourceAliases(_ aliases: [String], primary: String, platformID: String) -> [String] {
        var seen = Set<String>()
        var output: [String] = []
        for alias in aliases {
            let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  trimmed != primary,
                  trimmed.hasPrefix("\(platformID):"),
                  trimmed.count <= EntryEvidenceValidator.sourceIDLimit,
                  seen.insert(trimmed).inserted else {
                continue
            }
            output.append(trimmed)
            if output.count >= maximumSourceAliases { break }
        }
        return output
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        let decodedPlatformID = try container.decode(String.self, forKey: .platformID)
        platformID = decodedPlatformID
        entryID = try container.decode(String.self, forKey: .entryID)
        let decodedCreatorID = try container.decode(String.self, forKey: .creatorID)
        creatorID = decodedCreatorID
        sourceAliases = Self.normalizedSourceAliases(
            try container.decodeIfPresent([String].self, forKey: .sourceAliases) ?? [],
            primary: decodedCreatorID,
            platformID: decodedPlatformID
        )
        creatorName = try container.decode(String.self, forKey: .creatorName)
        entryType = try container.decode(String.self, forKey: .entryType)
        title = try container.decode(String.self, forKey: .title)
        surface = try container.decodeIfPresent(EntrySurface.self, forKey: .surface) ?? .feed
        text = try container.decodeIfPresent(String.self, forKey: .text)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        suppliedTags = Array(NSOrderedSet(array: try container.decodeIfPresent([String].self, forKey: .suppliedTags) ?? []))
            .compactMap { $0 as? String }
            .prefix(Self.maximumSuppliedTags)
            .map(\.self)
        canonicalURL = try container.decodeIfPresent(String.self, forKey: .canonicalURL)
        var decodedAttributes = try container.decodeIfPresent([String: String].self, forKey: .attributes) ?? [:]
        let retiredCreatorAvatarURL = decodedAttributes.removeValue(forKey: "creatorAvatarURL")
        let embeddedSourceIconURL = decodedAttributes.removeValue(forKey: "sourceIconURL")
        let iconCandidate = try container.decodeIfPresent(String.self, forKey: .sourceIconURL)
            ?? embeddedSourceIconURL
            ?? retiredCreatorAvatarURL
        sourceIconURL = iconCandidate.flatMap {
            SourceIconURLPolicy.isAccepted(platformID: decodedPlatformID, value: $0) ? $0 : nil
        }
        attributes = Self.reconciledAttributes(decodedAttributes)
        firstObservedAtMilliseconds = try container.decode(Int64.self, forKey: .firstObservedAtMilliseconds)
        lastObservedAtMilliseconds = try container.decode(Int64.self, forKey: .lastObservedAtMilliseconds)
        observationCount = max(1, try container.decodeIfPresent(Int.self, forKey: .observationCount) ?? 1)
    }

    private static func reconciledAttributes(_ input: [String: String]) -> [String: String] {
        var output = input
        if output["sourceURL"] == nil, let retiredCreatorURL = output.removeValue(forKey: "creatorURL") {
            output["sourceURL"] = retiredCreatorURL
        } else {
            output.removeValue(forKey: "creatorURL")
        }
        output.removeValue(forKey: "creatorAvatarURL")
        output.removeValue(forKey: "sourceIconURL")
        return output
    }
}

public struct ClassificationDataset: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// Collected public entries are observations only; per-video decisions live
    /// in `WorkspaceCatalog.videoClassifications`.
    public var collectedEntries: [CollectedPlatformEntry]
    public var revision: Int

    public init(
        id: String = UUID().uuidString,
        name: String,
        collectedEntries: [CollectedPlatformEntry] = [],
        revision: Int = 1
    ) {
        self.id = id
        self.name = name
        self.collectedEntries = Array(collectedEntries.suffix(CollectedPlatformEntry.maximumRetainedEntries))
        self.revision = revision
    }

    @discardableResult
    public mutating func upsertCollectedEntry(_ entry: CollectedPlatformEntry) -> Bool {
        if let index = collectedEntries.firstIndex(where: { $0.deduplicationKey == entry.deduplicationKey }) {
            let existing = collectedEntries[index]
            var refreshed = entry
            refreshed.firstObservedAtMilliseconds = min(existing.firstObservedAtMilliseconds, entry.firstObservedAtMilliseconds)
            refreshed.lastObservedAtMilliseconds = max(existing.lastObservedAtMilliseconds, entry.lastObservedAtMilliseconds)
            refreshed.observationCount = existing.observationCount > Int.max - entry.observationCount
                ? Int.max
                : existing.observationCount + entry.observationCount
            refreshed.surface = existing.surface == .page || entry.surface == .page ? .page : .feed
            refreshed.text = Self.richerCollectedText(existing.text, entry.text)
            refreshed.summary = Self.richerCollectedText(existing.summary, entry.summary)
            refreshed.suppliedTags = Array(NSOrderedSet(array: existing.suppliedTags + entry.suppliedTags))
                .compactMap { $0 as? String }
                .prefix(CollectedPlatformEntry.maximumSuppliedTags)
                .map(\.self)
            refreshed.sourceAliases = CollectedPlatformEntry.normalizedSourceAliases(
                existing.sourceAliases + entry.sourceAliases,
                primary: refreshed.creatorID,
                platformID: refreshed.platformID
            )
            refreshed.canonicalURL = entry.canonicalURL ?? existing.canonicalURL
            refreshed.sourceIconURL = entry.sourceIconURL ?? existing.sourceIconURL
            refreshed.attributes = existing.attributes.merging(entry.attributes) { _, incoming in incoming }
            collectedEntries[index] = refreshed
            return false
        }
        collectedEntries.append(entry)
        if collectedEntries.count > CollectedPlatformEntry.maximumRetainedEntries {
            collectedEntries.sort { lhs, rhs in
                if lhs.lastObservedAtMilliseconds == rhs.lastObservedAtMilliseconds { return lhs.id < rhs.id }
                return lhs.lastObservedAtMilliseconds > rhs.lastObservedAtMilliseconds
            }
            collectedEntries = Array(collectedEntries.prefix(CollectedPlatformEntry.maximumRetainedEntries))
        }
        return true
    }

    private static func richerCollectedText(_ existing: String?, _ incoming: String?) -> String? {
        guard let incoming, !incoming.isEmpty else { return existing }
        guard let existing, !existing.isEmpty else { return incoming }
        return incoming.count >= existing.count ? incoming : existing
    }

    private enum CodingKeys: String, CodingKey { case id, name, collectedEntries, revision }
    private enum RetiredCodingKeys: String, CodingKey { case records, creatorClassifications }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let retired = try decoder.container(keyedBy: RetiredCodingKeys.self)
        _ = retired.contains(.records)
        _ = retired.contains(.creatorClassifications)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        collectedEntries = Array(
            (try container.decodeIfPresent([CollectedPlatformEntry].self, forKey: .collectedEntries) ?? [])
                .suffix(CollectedPlatformEntry.maximumRetainedEntries)
        )
        revision = try container.decodeIfPresent(Int.self, forKey: .revision) ?? 1
    }
}
/// A reusable per-video decision configuration bound to exact tree and data
/// revisions.
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
    /// Optional request-time overrides for this type. Context/runtime controls
    /// stay global and apply to every resident model engine.
    public var localModelOverrides: LocalModelOverrides?
    /// Nil inherits the app-wide model choice. A file name selects a resident
    /// per-type GGUF engine while retaining global runtime controls.
    public var modelFileName: String?
    /// Optional grounded-research defaults for this type. The app-wide
    /// research consent remains the master gate even when this value enables
    /// research for the type.
    public var researchOverrides: ResearchSettings?
    /// The preset a person chose when creating this type (a `VaultPreset`
    /// rawValue), or nil for legacy/hand-built types. Stored as a string so an
    /// unknown preset from a newer build survives a round-trip. Advanced edits
    /// keep it, so the UI can flag "modified from <preset>".
    public var presetID: String?
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
        modelFileName: String? = nil,
        researchOverrides: ResearchSettings? = nil,
        presetID: String? = nil,
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
        let cleanedModelFileName = modelFileName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.modelFileName = cleanedModelFileName.isEmpty ? nil : String(cleanedModelFileName.prefix(255))
        self.researchOverrides = researchOverrides
        let cleanedPresetID = presetID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.presetID = cleanedPresetID.isEmpty ? nil : String(cleanedPresetID.prefix(64))
        self.order = order
        self.updatedAtMilliseconds = updatedAtMilliseconds
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, treeID, treeRevision, datasetID, datasetRevision, applicablePlatformID,
             localModelOverrides, modelFileName, researchOverrides, presetID, order, updatedAtMilliseconds
    }

    private enum RetiredCodingKeys: String, CodingKey {
        case dataSourcePlatformIDs, localModelID, selectedLLMProviderProfileID,
             llmAssistDraftConfiguration, llmAssistConfiguration, llmProfileIDs,
             decisionPriority, platformLocked
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let retired = try decoder.container(keyedBy: RetiredCodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        treeID = try container.decode(String.self, forKey: .treeID)
        treeRevision = try container.decode(Int.self, forKey: .treeRevision)
        datasetID = try container.decode(String.self, forKey: .datasetID)
        datasetRevision = try container.decode(Int.self, forKey: .datasetRevision)
        let decodedPlatformID = (try container.decodeIfPresent(String.self, forKey: .applicablePlatformID)?.trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
        if !decodedPlatformID.isEmpty {
            applicablePlatformID = decodedPlatformID
        } else {
            // The retired multi-source field is read only as a bounded crash
            // guard. It can be preserved only when it already described one
            // platform; a combined legacy type must be configured again.
            let legacyPlatformIDs = Array(Set(try retired.decodeIfPresent([String].self, forKey: .dataSourcePlatformIDs) ?? []))
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            applicablePlatformID = legacyPlatformIDs.count == 1 ? legacyPlatformIDs[0] : nil
        }
        // Removed trainable-model and per-type provider-assist fields are
        // accepted only as retired keys so old state opens safely. Their values
        // are deliberately discarded and are never re-encoded.
        _ = retired.contains(.localModelID)
        _ = retired.contains(.selectedLLMProviderProfileID)
        _ = retired.contains(.llmAssistDraftConfiguration)
        _ = retired.contains(.llmAssistConfiguration)
        _ = retired.contains(.llmProfileIDs)
        _ = retired.contains(.decisionPriority)
        _ = retired.contains(.platformLocked)
        let decodedOverrides = try container.decodeIfPresent(LocalModelOverrides.self, forKey: .localModelOverrides)
        localModelOverrides = decodedOverrides?.isEmpty == false ? decodedOverrides : nil
        let decodedModelFileName = try container.decodeIfPresent(String.self, forKey: .modelFileName)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        modelFileName = decodedModelFileName.isEmpty ? nil : String(decodedModelFileName.prefix(255))
        researchOverrides = try container.decodeIfPresent(ResearchSettings.self, forKey: .researchOverrides)
        let decodedPresetID = try container.decodeIfPresent(String.self, forKey: .presetID)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        presetID = decodedPresetID.isEmpty ? nil : String(decodedPresetID.prefix(64))
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
        try container.encodeIfPresent(modelFileName, forKey: .modelFileName)
        try container.encodeIfPresent(researchOverrides, forKey: .researchOverrides)
        try container.encodeIfPresent(presetID, forKey: .presetID)
        try container.encode(order, forKey: .order)
        try container.encode(updatedAtMilliseconds, forKey: .updatedAtMilliseconds)
    }
}

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
        case "tiktok": return .tikTok
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
        browser: String = "Chrome and Edge",
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
    public static let definitions: [CollectionPlatformDefinition] = [
        .init(id: "youtube", name: "YouTube", collectorAvailable: true),
        .init(id: "tiktok", name: "TikTok", collectorAvailable: true),
        .init(id: "facebook", name: "Facebook", collectorAvailable: true),
        .init(id: "instagram", name: "Instagram", collectorAvailable: true),
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
    public var policyID: String?
    /// Raw public-content collection is on by default for a newly added local
    /// platform binding. The browser still sends nothing unless this binding
    /// exists and its extension-side collection setting is also on.
    public var collectionEnabled: Bool

    public init(id: String, name: String, browser: String = "Chrome and Edge", treeID: String, datasetID: String, activeClassifierTypeID: String? = nil, policyID: String? = nil, collectionEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.browser = browser
        self.treeID = treeID
        self.datasetID = datasetID
        self.activeClassifierTypeID = activeClassifierTypeID
        self.policyID = policyID
        self.collectionEnabled = collectionEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, browser, treeID, datasetID, activeClassifierTypeID, policyID, collectionEnabled
    }

    private enum RetiredCodingKeys: String, CodingKey { case activeModelID }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let retired = try decoder.container(keyedBy: RetiredCodingKeys.self)
        _ = retired.contains(.activeModelID)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        browser = try container.decodeIfPresent(String.self, forKey: .browser) ?? "Chrome and Edge"
        treeID = try container.decode(String.self, forKey: .treeID)
        datasetID = try container.decode(String.self, forKey: .datasetID)
        activeClassifierTypeID = try container.decodeIfPresent(String.self, forKey: .activeClassifierTypeID)
        policyID = try container.decodeIfPresent(String.self, forKey: .policyID)
        collectionEnabled = try container.decodeIfPresent(Bool.self, forKey: .collectionEnabled) ?? true
    }
}

private func nonnegativeSaturatingSum(_ lhs: Int, _ rhs: Int) -> Int {
    let addition = max(0, lhs).addingReportingOverflow(max(0, rhs))
    return addition.overflow ? Int.max : addition.partialValue
}

public struct TokenUsageRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var provider: String
    public var model: String
    public var tokenCount: Int
    public var status: String
    /// Grounded-research budgets are independent for each classifier type.
    /// Nil identifies legacy/global records and remains readable.
    public var classifierTypeID: String?
    public var createdAtMilliseconds: Int64

    public init(id: String = UUID().uuidString, provider: String, model: String, tokenCount: Int, status: String, classifierTypeID: String? = nil, createdAtMilliseconds: Int64 = WorkspaceCatalog.now()) {
        self.id = id
        self.provider = provider
        self.model = model
        self.tokenCount = max(0, tokenCount)
        self.status = status
        self.classifierTypeID = classifierTypeID
        self.createdAtMilliseconds = createdAtMilliseconds
    }

    private enum CodingKeys: String, CodingKey {
        case id, provider, model, tokenCount, status, classifierTypeID, createdAtMilliseconds
        case inputTokens, outputTokens
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        provider = try container.decode(String.self, forKey: .provider)
        model = try container.decode(String.self, forKey: .model)
        if let aggregate = try container.decodeIfPresent(Int.self, forKey: .tokenCount) {
            tokenCount = max(0, aggregate)
        } else {
            tokenCount = nonnegativeSaturatingSum(
                try container.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0,
                try container.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
            )
        }
        status = try container.decode(String.self, forKey: .status)
        classifierTypeID = try container.decodeIfPresent(String.self, forKey: .classifierTypeID)
        createdAtMilliseconds = try container.decode(Int64.self, forKey: .createdAtMilliseconds)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(provider, forKey: .provider)
        try container.encode(model, forKey: .model)
        try container.encode(tokenCount, forKey: .tokenCount)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(classifierTypeID, forKey: .classifierTypeID)
        try container.encode(createdAtMilliseconds, forKey: .createdAtMilliseconds)
    }
}

/// A bounded local ledger for explicit provider requests. It tracks only the
/// outcome and token accounting. A parser failure may retain a bounded
/// response-shape summary made only from structural field names and counts;
/// credentials, headers, request text, and response text are never retained.
public struct ProviderRequestRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var profileID: String
    public var provider: String
    public var model: String
    public var operation: String
    public var endpoint: String
    public var method: String
    public var statusCode: Int?
    /// A redacted JSON-envelope description for a 2xx response that could not
    /// be parsed. It never contains response values or text.
    public var responseShape: String?
    public var durationMilliseconds: Int
    public var tokenCount: Int?
    /// Nil for connection tests. LLM classification runs identify the one
    /// classifier type whose daily aggregate allowance they consume.
    public var classifierTypeID: String?
    public var outcome: String
    public var createdAtMilliseconds: Int64

    public init(
        id: String = UUID().uuidString,
        profileID: String,
        provider: String,
        model: String,
        operation: String,
        endpoint: String,
        method: String,
        statusCode: Int?,
        responseShape: String? = nil,
        durationMilliseconds: Int,
        tokenCount: Int?,
        classifierTypeID: String? = nil,
        outcome: String,
        createdAtMilliseconds: Int64 = WorkspaceCatalog.now()
    ) {
        self.id = id
        self.profileID = profileID
        self.provider = provider
        self.model = model
        self.operation = operation
        self.endpoint = endpoint
        self.method = method
        self.statusCode = statusCode
        let cleanedResponseShape = responseShape?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.responseShape = cleanedResponseShape.isEmpty ? nil : String(cleanedResponseShape.prefix(ProviderTestProtocol.maximumResponseShapeCharacters))
        self.durationMilliseconds = durationMilliseconds
        self.tokenCount = tokenCount.map { max(0, $0) }
        let cleanedClassifierTypeID = classifierTypeID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.classifierTypeID = cleanedClassifierTypeID.isEmpty ? nil : cleanedClassifierTypeID
        self.outcome = outcome
        self.createdAtMilliseconds = createdAtMilliseconds
    }

    private enum CodingKeys: String, CodingKey {
        case id, profileID, provider, model, operation, endpoint, method,
             statusCode, responseShape, durationMilliseconds, tokenCount,
             classifierTypeID, outcome, createdAtMilliseconds
        case inputTokens, outputTokens
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        profileID = try container.decode(String.self, forKey: .profileID)
        provider = try container.decode(String.self, forKey: .provider)
        model = try container.decode(String.self, forKey: .model)
        operation = try container.decode(String.self, forKey: .operation)
        endpoint = try container.decode(String.self, forKey: .endpoint)
        method = try container.decode(String.self, forKey: .method)
        statusCode = try container.decodeIfPresent(Int.self, forKey: .statusCode)
        responseShape = try container.decodeIfPresent(String.self, forKey: .responseShape)
        durationMilliseconds = try container.decode(Int.self, forKey: .durationMilliseconds)
        if let aggregate = try container.decodeIfPresent(Int.self, forKey: .tokenCount) {
            tokenCount = max(0, aggregate)
        } else {
            let input = try container.decodeIfPresent(Int.self, forKey: .inputTokens)
            let output = try container.decodeIfPresent(Int.self, forKey: .outputTokens)
            tokenCount = input == nil && output == nil
                ? nil
                : nonnegativeSaturatingSum(input ?? 0, output ?? 0)
        }
        classifierTypeID = try container.decodeIfPresent(String.self, forKey: .classifierTypeID)
        outcome = try container.decode(String.self, forKey: .outcome)
        createdAtMilliseconds = try container.decode(Int64.self, forKey: .createdAtMilliseconds)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(profileID, forKey: .profileID)
        try container.encode(provider, forKey: .provider)
        try container.encode(model, forKey: .model)
        try container.encode(operation, forKey: .operation)
        try container.encode(endpoint, forKey: .endpoint)
        try container.encode(method, forKey: .method)
        try container.encodeIfPresent(statusCode, forKey: .statusCode)
        try container.encodeIfPresent(responseShape, forKey: .responseShape)
        try container.encode(durationMilliseconds, forKey: .durationMilliseconds)
        try container.encodeIfPresent(tokenCount, forKey: .tokenCount)
        try container.encodeIfPresent(classifierTypeID, forKey: .classifierTypeID)
        try container.encode(outcome, forKey: .outcome)
        try container.encode(createdAtMilliseconds, forKey: .createdAtMilliseconds)
    }
}

/// A normalized provider key or token used to build an explicit provider
/// request. Its storage and presentation are owned by `APIKeyProviderProfile`.
public struct ProviderCredentialRecord: Codable, Equatable, Sendable {
    public static let maximumCharacters = 2_048

    public var values: [ProviderCredentialField: String]

    public init(values: [ProviderCredentialField: String]) {
        self.values = Dictionary(uniqueKeysWithValues: values.map { field, value in
            (field, value.trimmingCharacters(in: .whitespacesAndNewlines))
        })
    }

    public func validate(for descriptor: ProviderProtocolDescriptor) throws {
        guard Set(values.keys) == Set(descriptor.credentialFields) else {
            throw ProviderCredentialError.invalidCredential
        }
        for field in descriptor.credentialFields {
            guard let value = values[field], Self.isValid(value) else {
                throw ProviderCredentialError.missingCredential(field)
            }
        }
    }

    public static func isValid(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= maximumCharacters else { return false }
        return value.unicodeScalars.allSatisfy { $0.properties.generalCategory != .control }
    }
}

public enum ProviderCredentialError: Error, LocalizedError, Sendable {
    case invalidCredential
    case missingCredential(ProviderCredentialField)

    public var errorDescription: String? {
        switch self {
        case .invalidCredential: return "The provider credential is malformed."
        case .missingCredential: return "Enter a valid API key or token."
        }
    }
}

/// A local provider profile includes its ordinary saved API key or token plus
/// the connection settings needed for the selected provider protocol.
public enum APIKeyProviderType: String, Codable, Sendable, CaseIterable {
    case openAI
    case openAICompatible
    case deepSeek
    case gemini
    case anthropic
    case mistral
    case cohere
    case groq
    case openRouter
    case ollama
    case youtubeData
    case twitch
    case reddit
    case xPlatform
    case tikTok
    case instagramGraph
    case facebookGraph
    case serper
    case youSearch
    case custom

    public var supportsLLMConfiguration: Bool {
        ProviderProtocolRegistry.descriptor(for: self).supportsLLMConfiguration
    }

    public var supportsRawWebSearch: Bool {
        ProviderProtocolRegistry.descriptor(for: self).supportsRawWebSearch
    }

    /// A provider-native search invocation has an explicit request grammar in
    /// this app. Do not advertise search merely because a provider's separate
    /// consumer product or agent integration can browse the web.
    public var supportsProviderNativeWebSearch: Bool {
        switch self {
        case .openAI, .gemini, .anthropic:
            return true
        default:
            return false
        }
    }

    /// Standard provider integrations whose documented generation grammar
    /// supports client-executed function calls. Custom and generic compatible
    /// endpoints are intentionally excluded because Probe cannot establish
    /// that contract from an arbitrary `/models` response.
    public var supportsAttachedWebSearchTool: Bool {
        switch self {
        case .openAI, .deepSeek, .gemini, .anthropic, .mistral, .cohere, .groq, .openRouter:
            return true
        case .ollama:
            // Probe retains every installed model and annotates each model's
            // declared tool capability.
            return true
        default:
            return false
        }
    }

    public var defaultProfileName: String {
        switch self {
        case .openAI: return "OpenAI key"
        case .openAICompatible: return "OpenAI-compatible API"
        case .deepSeek: return "DeepSeek key"
        case .gemini: return "Gemini key"
        case .anthropic: return "Anthropic key"
        case .mistral: return "Mistral key"
        case .cohere: return "Cohere key"
        case .groq: return "Groq key"
        case .openRouter: return "OpenRouter key"
        case .ollama: return "Ollama profile"
        case .youtubeData: return "YouTube Data API key"
        case .twitch: return "Twitch credential"
        case .reddit: return "Reddit credential"
        case .xPlatform: return "X API credential"
        case .tikTok: return "TikTok credential"
        case .instagramGraph: return "Instagram Graph API credential"
        case .facebookGraph: return "Facebook Graph API credential"
        case .serper: return "Serper key"
        case .youSearch: return "You.com Search key"
        case .custom: return "Custom API key"
        }
    }

    public var defaultModelIdentifier: String {
        switch self {
        case .openAI: return "gpt-4.1-mini"
        case .openAICompatible: return ""
        case .deepSeek: return "deepseek-v4-flash"
        case .gemini: return "gemini-3.1-flash-lite"
        case .anthropic: return "claude-sonnet-4-5"
        case .mistral: return "mistral-large-latest"
        case .cohere: return "command-a-plus-05-2026"
        case .groq: return "llama-3.3-70b-versatile"
        case .openRouter: return "openai/gpt-4.1-mini"
        case .ollama: return "llama3.3"
        case .youtubeData, .twitch, .reddit, .xPlatform, .tikTok,
             .instagramGraph, .facebookGraph, .serper, .youSearch: return ""
        case .custom: return "custom-model"
        }
    }

    /// A removed profile type is reset to an inert configurable profile while
    /// its enclosing catalog is reconciled. It never restores the old adapter.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if let type = APIKeyProviderType(rawValue: raw) {
            self = type
            return
        }
        self = .openAICompatible
    }
}

public struct APIKeyProviderProfile: Codable, Equatable, Sendable, Identifiable {
    public static let maximumNameLength = 128
    public static let maximumEndpointLength = 2_048
    public static let maximumTestModelIdentifierLength = 256

    public var id: String
    public var name: String
    public var type: APIKeyProviderType
    /// An optional endpoint override supports compatible cloud, self-hosted,
    /// and custom entries. It is connection configuration only; the selected
    /// LLM model and classification limits belong to `ClassifierTypeAsset`.
    public var customEndpoint: String?
    /// Non-secret protocol settings such as cloud account, region, or API
    /// version. The versioned descriptor controls which keys are allowed.
    public var protocolConfiguration: [String: String]
    /// A non-secret model used only by the compact connection test when the
    /// provider does not publish a fixed test model. Classifier types still
    /// choose their own model for classification.
    public var testModelIdentifier: String?
    /// A plain, locally persisted API key or token. This is intentionally shown
    /// and edited as an ordinary text field in the local WebView.
    public var credential: String?
    public var updatedAtMilliseconds: Int64

    public init(
        id: String = UUID().uuidString,
        name: String? = nil,
        type: APIKeyProviderType,
        customEndpoint: String? = nil,
        protocolConfiguration: [String: String]? = nil,
        testModelIdentifier: String? = nil,
        credential: String? = nil,
        updatedAtMilliseconds: Int64 = WorkspaceCatalog.now()
    ) {
        self.id = id
        self.name = name ?? type.defaultProfileName
        self.type = type
        self.customEndpoint = customEndpoint
        self.protocolConfiguration = protocolConfiguration ?? ProviderProtocolRegistry.descriptor(for: type).defaultConfiguration()
        self.testModelIdentifier = testModelIdentifier
        let normalizedCredential = credential?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.credential = normalizedCredential.isEmpty ? nil : normalizedCredential
        self.updatedAtMilliseconds = updatedAtMilliseconds
    }

    public func validate() throws {
        let cleanedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, id.count <= 128,
              !cleanedName.isEmpty, cleanedName.count <= Self.maximumNameLength else {
            throw APIKeyProviderProfileError.invalidConfiguration
        }

        let descriptor = ProviderProtocolRegistry.descriptor(for: type)
        let normalizedEndpoint = customEndpoint?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedEndpoint?.count ?? 0 <= Self.maximumEndpointLength else {
            throw APIKeyProviderProfileError.invalidConfiguration
        }
        let normalizedTestModelIdentifier = testModelIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedTestModelIdentifier?.count ?? 0 <= Self.maximumTestModelIdentifierLength else {
            throw APIKeyProviderProfileError.invalidConfiguration
        }
        let normalizedCredential = credential?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedCredential?.count ?? 0 <= ProviderCredentialRecord.maximumCharacters,
              normalizedCredential?.unicodeScalars.allSatisfy({ $0.properties.generalCategory != .control }) ?? true else {
            throw APIKeyProviderProfileError.invalidConfiguration
        }
        do {
            try descriptor.validateConfiguration(protocolConfiguration, endpointOverride: normalizedEndpoint, requireDispatchReadiness: false)
        } catch {
            throw APIKeyProviderProfileError.invalidConfiguration
        }
    }

    /// Used by an explicit provider run before it reads the saved credential.
    /// Editing a profile intentionally permits incomplete values.
    public func validateForDispatch() throws {
        try validate()
        do {
            try ProviderProtocolRegistry.descriptor(for: type).validateConfiguration(
                protocolConfiguration,
                endpointOverride: customEndpoint,
                requireDispatchReadiness: true
            )
        } catch {
            throw APIKeyProviderProfileError.invalidConfiguration
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, type, customEndpoint, protocolConfiguration, testModelIdentifier, credential, updatedAtMilliseconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        let rawType = try container.decode(String.self, forKey: .type)
        let isRetiredType = APIKeyProviderType(rawValue: rawType) == nil
        type = APIKeyProviderType(rawValue: rawType) ?? .openAICompatible
        // The catalog reconciler removes this invalid placeholder before it is
        // exposed. That keeps old local state from crashing the app without
        // preserving a removed adapter behind a compatibility path.
        name = isRetiredType ? "" : try container.decode(String.self, forKey: .name)
        customEndpoint = try container.decodeIfPresent(String.self, forKey: .customEndpoint)
        protocolConfiguration = try container.decodeIfPresent([String: String].self, forKey: .protocolConfiguration)
            ?? ProviderProtocolRegistry.descriptor(for: type).defaultConfiguration()
        testModelIdentifier = try container.decodeIfPresent(String.self, forKey: .testModelIdentifier)
        let descriptor = ProviderProtocolRegistry.descriptor(for: type)
        if let plainCredential = try? container.decode(String.self, forKey: .credential) {
            let normalizedCredential = plainCredential.trimmingCharacters(in: .whitespacesAndNewlines)
            credential = normalizedCredential.isEmpty ? nil : normalizedCredential
        } else if let legacyCredential = try? container.decode(ProviderCredentialRecord.self, forKey: .credential),
                  let descriptorField = descriptor.credentialFields.first,
                  (try? legacyCredential.validate(for: descriptor)) != nil {
            credential = legacyCredential.values[descriptorField]
        } else {
            credential = nil
        }
        updatedAtMilliseconds = try container.decodeIfPresent(Int64.self, forKey: .updatedAtMilliseconds) ?? WorkspaceCatalog.now()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(type.rawValue, forKey: .type)
        try container.encodeIfPresent(customEndpoint, forKey: .customEndpoint)
        try container.encode(protocolConfiguration, forKey: .protocolConfiguration)
        try container.encodeIfPresent(testModelIdentifier, forKey: .testModelIdentifier)
        try container.encodeIfPresent(credential, forKey: .credential)
        try container.encode(updatedAtMilliseconds, forKey: .updatedAtMilliseconds)
    }
}

public enum APIKeyProviderProfileError: Error, Equatable, LocalizedError, Sendable {
    case invalidConfiguration

    public var errorDescription: String? {
        "The provider profile configuration is invalid."
    }
}

public enum WorkspaceCatalogError: Error, Equatable, LocalizedError, Sendable {
    case duplicateIdentifier(String)
    case missingTree(String)
    case missingDataset(String)
    case missingClassifierType(String)
    case incompatibleActiveClassifierType(String)
    case unsupportedCollectionPlatform(String)
    case invalidCollectedEntry(String)
    case invalidProviderProfile(String)
    case invalidClassifierType(String)
    case treeInUse(String)

    public var errorDescription: String? {
        switch self {
        case .duplicateIdentifier(let value): return "Duplicate local asset identifier: \(value)."
        case .missingTree(let value): return "The platform binding references a missing tag tree: \(value)."
        case .missingDataset(let value): return "The platform binding references a missing classification dataset: \(value)."
        case .missingClassifierType(let value): return "The platform binding references a missing classifier type: \(value)."
        case .incompatibleActiveClassifierType(let value): return "The active classifier type is not compatible with the platform tree and dataset: \(value)."
        case .unsupportedCollectionPlatform(let value): return "The collection platform is not supported: \(value)."
        case .invalidCollectedEntry(let value): return "The collected platform entry is invalid: \(value)."
        case .invalidProviderProfile(let value): return "The API provider profile is invalid: \(value)."
        case .invalidClassifierType(let value): return "The classifier type has incompatible local assets: \(value)."
        case .treeInUse(let value): return "The tag tree is still used by a classifier type or platform: \(value)."
        }
    }
}

public enum TrashedEntryKind: String, Codable, Sendable, CaseIterable {
    case classifierType
    case collectionPlatform
    case tagTree
}

/// A self-contained snapshot of a deleted entity and every dependent record it
/// owned, so a restore re-inserts the whole thing. Only the fields relevant to
/// `kind` are populated. Entries are opportunistically purged 24h after
/// deletion (there is no background timer).
public struct TrashedEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var kind: TrashedEntryKind
    public var name: String
    public var deletedAtMilliseconds: Int64
    public var classifierType: ClassifierTypeAsset?
    public var binding: PlatformBinding?
    public var tree: TagTreeAsset?
    public var datasetID: String?
    public var collectedEntries: [CollectedPlatformEntry]

    public init(
        id: String = UUID().uuidString,
        kind: TrashedEntryKind,
        name: String,
        deletedAtMilliseconds: Int64 = WorkspaceCatalog.now(),
        classifierType: ClassifierTypeAsset? = nil,
        binding: PlatformBinding? = nil,
        tree: TagTreeAsset? = nil,
        datasetID: String? = nil,
        collectedEntries: [CollectedPlatformEntry] = []
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.deletedAtMilliseconds = deletedAtMilliseconds
        self.classifierType = classifierType
        self.binding = binding
        self.tree = tree
        self.datasetID = datasetID
        self.collectedEntries = collectedEntries
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, name, deletedAtMilliseconds, classifierType, binding, tree
        case datasetID, collectedEntries
    }

    private enum RetiredCodingKeys: String, CodingKey { case creatorClassifications, models }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let retired = try decoder.container(keyedBy: RetiredCodingKeys.self)
        _ = retired.contains(.creatorClassifications)
        _ = retired.contains(.models)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(TrashedEntryKind.self, forKey: .kind)
        name = try container.decode(String.self, forKey: .name)
        deletedAtMilliseconds = try container.decode(Int64.self, forKey: .deletedAtMilliseconds)
        classifierType = try container.decodeIfPresent(ClassifierTypeAsset.self, forKey: .classifierType)
        binding = try container.decodeIfPresent(PlatformBinding.self, forKey: .binding)
        tree = try container.decodeIfPresent(TagTreeAsset.self, forKey: .tree)
        datasetID = try container.decodeIfPresent(String.self, forKey: .datasetID)
        collectedEntries = try container.decodeIfPresent([CollectedPlatformEntry].self, forKey: .collectedEntries) ?? []
    }

    /// Default 24-hour trash lifetime, expressed in milliseconds.
    public static let defaultTTLMilliseconds: Int64 = 24 * 60 * 60 * 1_000
}

public struct WorkspaceCatalog: Codable, Equatable, Sendable {
    public var trees: [TagTreeAsset]
    public var datasets: [ClassificationDataset]
    public var bindings: [PlatformBinding]
    /// Reusable decision brains. A platform may later select one explicitly;
    /// the asset itself does not grant a browser or provider permission.
    public var classifierTypes: [ClassifierTypeAsset]
    public var tokenUsage: [TokenUsageRecord]
    public var providerRequestRecords: [ProviderRequestRecord]
    /// Provider profiles include their saved connection fields, including the
    /// ordinary API key/token text. They remain local to workspace state and
    /// the local WebView; browser-bridge messages and request diagnostics do
    /// not include them.
    public var providerProfiles: [APIKeyProviderProfile]
    public var trash: [TrashedEntry]
    // Local-LLM rework stores (additive; see LocalLLMModel.swift). Primary per-video
    // labels, the grounded-research knowledge map, user corrections, and the derived
    // creator priors. Empty until the new pipeline populates them.
    public var videoClassifications: [VideoClassification]
    /// Term knowledge only. Creator descriptions live in `creatorKnowledge`, a
    /// deliberately separate, permanent map (creator identities are keyed
    /// forever and are used as a low-confidence classification fallback rather
    /// than injected into every decode).
    public var knowledgeEntries: [KnowledgeEntry]
    /// Creator descriptions, keyed by creator id — permanent and stored apart
    /// from term knowledge.
    public var creatorKnowledge: [KnowledgeEntry]
    public var researchAttempts: [ResearchAttemptRecord]
    public var correctionExamples: [CorrectionExample]
    public var creatorHistograms: [CreatorTagHistogram]

    public init(trees: [TagTreeAsset] = [], datasets: [ClassificationDataset] = [], bindings: [PlatformBinding] = [], classifierTypes: [ClassifierTypeAsset] = [], tokenUsage: [TokenUsageRecord] = [], providerRequestRecords: [ProviderRequestRecord] = [], providerProfiles: [APIKeyProviderProfile] = [], trash: [TrashedEntry] = [], videoClassifications: [VideoClassification] = [], knowledgeEntries: [KnowledgeEntry] = [], creatorKnowledge: [KnowledgeEntry] = [], researchAttempts: [ResearchAttemptRecord] = [], correctionExamples: [CorrectionExample] = [], creatorHistograms: [CreatorTagHistogram] = []) {
        self.trees = trees
        self.datasets = datasets
        self.bindings = bindings
        self.classifierTypes = classifierTypes
        self.tokenUsage = tokenUsage
        self.providerRequestRecords = providerRequestRecords
        self.providerProfiles = providerProfiles
        self.trash = trash
        self.videoClassifications = videoClassifications
        self.knowledgeEntries = knowledgeEntries
        self.creatorKnowledge = creatorKnowledge
        self.researchAttempts = researchAttempts
        self.correctionExamples = correctionExamples
        self.creatorHistograms = creatorHistograms
    }

    public static func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1_000) }

    public static func starter() -> WorkspaceCatalog {
        // A personal tree begins as an empty canvas. The Vault taxonomy remains
        // an optional import rather than an imposed first node or hierarchy.
        let tree = TagTreeAsset(id: "vault-starter", name: "Vault starter tree", nodes: [])
        let dataset = ClassificationDataset(id: "local-dataset", name: "Local classification data")
        // Every supported platform is collected by default; the person turns any
        // one off rather than adding them one at a time. Bindings share the local
        // dataset (entries self-tag with their platform); classifier types own
        // their own trees, so the shared starter tree is only the binding anchor.
        let bindings = CollectionPlatformRegistry.definitions.map { definition in
            PlatformBinding(
                id: definition.id,
                name: definition.name,
                browser: definition.browser,
                treeID: tree.id,
                datasetID: dataset.id,
                collectionEnabled: true
            )
        }
        return .init(trees: [tree], datasets: [dataset], bindings: bindings)
    }

    public func validate() throws {
        try unique(trees.map(\.id) + datasets.map(\.id) + bindings.map(\.id) + classifierTypes.map(\.id) + providerProfiles.map(\.id))
        try validateLocalLLMStores()
        for binding in bindings {
            guard CollectionPlatformRegistry.definition(for: binding.id) != nil else {
                throw WorkspaceCatalogError.unsupportedCollectionPlatform(binding.id)
            }
            guard let tree = trees.first(where: { $0.id == binding.treeID }) else { throw WorkspaceCatalogError.missingTree(binding.treeID) }
            guard let dataset = datasets.first(where: { $0.id == binding.datasetID }) else { throw WorkspaceCatalogError.missingDataset(binding.datasetID) }
            _ = tree
            _ = dataset
        }
        for dataset in datasets {
            guard dataset.collectedEntries.count <= CollectedPlatformEntry.maximumRetainedEntries else {
                throw WorkspaceCatalogError.invalidCollectedEntry(dataset.id)
            }
            var seenEntries = Set<String>()
            for entry in dataset.collectedEntries {
                guard CollectionPlatformRegistry.definition(for: entry.platformID) != nil,
                      !entry.id.isEmpty,
                      !entry.entryID.isEmpty,
                      !entry.creatorID.isEmpty,
                      !entry.creatorName.isEmpty,
                      !entry.entryType.isEmpty,
                      !entry.title.isEmpty,
                      entry.title.count <= EntryEvidenceValidator.titleLimit,
                      entry.text.map({ !$0.isEmpty && $0.count <= EntryEvidenceValidator.textLimit }) ?? true,
                      entry.summary.map({ !$0.isEmpty && $0.count <= EntryEvidenceValidator.summaryLimit }) ?? true,
                      entry.suppliedTags.count <= CollectedPlatformEntry.maximumSuppliedTags,
                      entry.suppliedTags.allSatisfy({
                          !$0.isEmpty &&
                          $0.count <= EntryEvidenceValidator.tagLengthLimit &&
                          $0.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f })
                      }),
                      entry.sourceIconURL.map({
                          SourceIconURLPolicy.isAccepted(platformID: entry.platformID, value: $0)
                      }) ?? true,
                      entry.attributes.count <= CollectedPlatformEntry.maximumAttributes,
                      entry.attributes.allSatisfy({ key, value in
                          !key.isEmpty && key.count <= CollectedPlatformEntry.maximumAttributeKeyLength &&
                          value.count <= CollectedPlatformEntry.maximumAttributeValueLength &&
                          key.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f }) &&
                          value.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f })
                      }),
                      entry.observationCount > 0,
                      seenEntries.insert(entry.deduplicationKey).inserted else {
                    throw WorkspaceCatalogError.invalidCollectedEntry(entry.id)
                }
            }
        }
        for classifierType in classifierTypes {
            guard !classifierType.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  classifierType.name.count <= ClassifierTypeAsset.maximumNameLength,
                  let tree = trees.first(where: { $0.id == classifierType.treeID }),
                  tree.revision == classifierType.treeRevision,
                  let dataset = datasets.first(where: { $0.id == classifierType.datasetID }),
                  dataset.revision == classifierType.datasetRevision,
                  (classifierType.applicablePlatformID == nil || (classifierType.applicablePlatformID?.count ?? 0) <= 64),
                  (classifierType.applicablePlatformID == nil || bindings.contains(where: { binding in
                      // Multiple types may target one platform, each owning its own
                      // tree; only the platform + shared dataset must match here.
                      binding.id == classifierType.applicablePlatformID && binding.datasetID == dataset.id
                  })) else {
                throw WorkspaceCatalogError.invalidClassifierType(classifierType.id)
            }
        }
        for binding in bindings {
            guard let classifierTypeID = binding.activeClassifierTypeID else { continue }
            guard let classifierType = classifierTypes.first(where: { $0.id == classifierTypeID }) else {
                throw WorkspaceCatalogError.missingClassifierType(classifierTypeID)
            }
            guard classifierType.treeID == binding.treeID,
                  classifierType.datasetID == binding.datasetID,
                  classifierType.applicablePlatformID == binding.id,
                  let tree = trees.first(where: { $0.id == binding.treeID }),
                  let dataset = datasets.first(where: { $0.id == binding.datasetID }),
                  classifierType.treeRevision == tree.revision,
                  classifierType.datasetRevision == dataset.revision else {
                throw WorkspaceCatalogError.incompatibleActiveClassifierType(classifierTypeID)
            }
        }
        for profile in providerProfiles {
            do {
                try profile.validate()
            } catch {
                throw WorkspaceCatalogError.invalidProviderProfile(profile.id)
            }
        }
        for record in providerRequestRecords {
            guard providerProfiles.contains(where: { $0.id == record.profileID }),
                  record.durationMilliseconds >= 0 else {
                throw WorkspaceCatalogError.invalidProviderProfile(record.profileID)
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case trees, datasets, bindings, classifierTypes, tokenUsage, providerRequestRecords, providerProfiles, trash,
             videoClassifications, knowledgeEntries, creatorKnowledge, researchAttempts, correctionExamples, creatorHistograms
    }

    private enum RetiredCodingKeys: String, CodingKey { case models }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let retired = try decoder.container(keyedBy: RetiredCodingKeys.self)
        _ = retired.contains(.models)
        trees = try container.decodeIfPresent([TagTreeAsset].self, forKey: .trees) ?? []
        datasets = try container.decodeIfPresent([ClassificationDataset].self, forKey: .datasets) ?? []
        bindings = try container.decodeIfPresent([PlatformBinding].self, forKey: .bindings) ?? []
        classifierTypes = try container.decodeIfPresent([ClassifierTypeAsset].self, forKey: .classifierTypes) ?? []
        tokenUsage = try container.decodeIfPresent([TokenUsageRecord].self, forKey: .tokenUsage) ?? []
        providerRequestRecords = try container.decodeIfPresent([ProviderRequestRecord].self, forKey: .providerRequestRecords) ?? []
        providerProfiles = try container.decodeIfPresent([APIKeyProviderProfile].self, forKey: .providerProfiles) ?? []
        trash = try container.decodeIfPresent([TrashedEntry].self, forKey: .trash) ?? []
        videoClassifications = try container.decodeIfPresent([VideoClassification].self, forKey: .videoClassifications) ?? []
        // Migration: older states stored terms and creators together in
        // `knowledgeEntries`. Keep terms there and move any creator entries into
        // the dedicated `creatorKnowledge` map. New states already write both.
        let decodedKnowledge = try container.decodeIfPresent([KnowledgeEntry].self, forKey: .knowledgeEntries) ?? []
        let decodedCreatorKnowledge = try container.decodeIfPresent([KnowledgeEntry].self, forKey: .creatorKnowledge) ?? []
        knowledgeEntries = decodedKnowledge.filter { $0.kind == .term }
        var creators = decodedCreatorKnowledge.filter { $0.kind == .creator }
        var creatorKeys = Set(creators.map(\.id))
        for entry in decodedKnowledge where entry.kind == .creator && creatorKeys.insert(entry.id).inserted {
            creators.append(entry)
        }
        creatorKnowledge = creators
        researchAttempts = try container.decodeIfPresent([ResearchAttemptRecord].self, forKey: .researchAttempts) ?? []
        correctionExamples = try container.decodeIfPresent([CorrectionExample].self, forKey: .correctionExamples) ?? []
        creatorHistograms = try container.decodeIfPresent([CreatorTagHistogram].self, forKey: .creatorHistograms) ?? []
    }

    private func unique(_ identifiers: [String]) throws {
        guard Set(identifiers).count == identifiers.count else {
            throw WorkspaceCatalogError.duplicateIdentifier("workspace catalog")
        }
    }

    /// Returns the local classification-data binding for a supported platform,
    /// creating it from this catalog's default tree and dataset when the
    /// platform has not been added yet. A platform is added at most once.
    @discardableResult
    public mutating func ensurePlatformBinding(_ platformID: String) throws -> PlatformBinding {
        guard let definition = CollectionPlatformRegistry.definition(for: platformID) else {
            throw WorkspaceCatalogError.unsupportedCollectionPlatform(platformID)
        }
        if let existing = bindings.first(where: { $0.id == definition.id }) {
            return existing
        }
        guard let tree = trees.first else {
            throw WorkspaceCatalogError.missingTree("workspace default")
        }
        guard let dataset = datasets.first else {
            throw WorkspaceCatalogError.missingDataset("workspace default")
        }
        let binding = PlatformBinding(
            id: definition.id,
            name: definition.name,
            browser: definition.browser,
            treeID: tree.id,
            datasetID: dataset.id,
            collectionEnabled: true
        )
        bindings.append(binding)
        return binding
    }

    /// Removes one local platform binding and its collected public entries.
    /// Shared tree and dataset assets are retained.
    @discardableResult
    public mutating func removePlatformBinding(_ platformID: String) -> Bool {
        guard let bindingIndex = bindings.firstIndex(where: { $0.id == platformID }) else {
            return false
        }

        let binding = bindings.remove(at: bindingIndex)
        if let datasetIndex = datasets.firstIndex(where: { $0.id == binding.datasetID }) {
            datasets[datasetIndex].collectedEntries.removeAll(where: { $0.platformID == platformID })
        }
        reconcileClassifierTypes()
        return true
    }

    // MARK: - Trash (soft delete)

    /// Moves a classifier type into trash.
    @discardableResult
    public mutating func trashClassifierType(_ typeID: String) -> TrashedEntry? {
        guard let index = classifierTypes.firstIndex(where: { $0.id == typeID }) else { return nil }
        let type = classifierTypes.remove(at: index)
        for bindingIndex in bindings.indices where bindings[bindingIndex].activeClassifierTypeID == typeID {
            bindings[bindingIndex].activeClassifierTypeID = nil
        }
        let entry = TrashedEntry(
            kind: .classifierType,
            name: type.name,
            classifierType: type,
            datasetID: type.datasetID
        )
        trash.append(entry)
        reconcileClassifierTypes()
        return entry
    }

    /// Moves a collection platform and its collected entries into a trash snapshot,
    /// reusing the vetted `removePlatformBinding` cascade for removal.
    @discardableResult
    public mutating func trashCollectionPlatform(_ platformID: String) -> TrashedEntry? {
        guard let binding = bindings.first(where: { $0.id == platformID }) else { return nil }
        let capturedEntries = datasets.flatMap { $0.collectedEntries.filter { $0.platformID == platformID } }
        guard removePlatformBinding(platformID) else { return nil }
        let entry = TrashedEntry(
            kind: .collectionPlatform,
            name: binding.name,
            binding: binding,
            datasetID: binding.datasetID,
            collectedEntries: capturedEntries
        )
        trash.append(entry)
        return entry
    }

    /// Moves an unreferenced tag tree into trash. A tree still referenced by any
    /// classifier type or platform binding cannot be trashed; the caller must
    /// remove those dependents first.
    @discardableResult
    public mutating func trashTagTree(_ treeID: String) throws -> TrashedEntry? {
        guard let index = trees.firstIndex(where: { $0.id == treeID }) else { return nil }
        if bindings.contains(where: { $0.treeID == treeID }) || classifierTypes.contains(where: { $0.treeID == treeID }) {
            throw WorkspaceCatalogError.treeInUse(treeID)
        }
        let tree = trees.remove(at: index)
        let entry = TrashedEntry(kind: .tagTree, name: tree.name, tree: tree)
        trash.append(entry)
        return entry
    }

    /// Re-inserts a trashed entry and every dependent configuration it captured.
    @discardableResult
    public mutating func restoreTrashedEntry(_ id: String) -> Bool {
        guard let index = trash.firstIndex(where: { $0.id == id }) else { return false }
        let entry = trash.remove(at: index)
        switch entry.kind {
        case .classifierType:
            guard let type = entry.classifierType, !classifierTypes.contains(where: { $0.id == type.id }) else { break }
            classifierTypes.append(type)
        case .collectionPlatform:
            guard let binding = entry.binding else { break }
            if !bindings.contains(where: { $0.id == binding.id }) { bindings.append(binding) }
            if let datasetID = entry.datasetID, let dIndex = datasets.firstIndex(where: { $0.id == datasetID }) {
                datasets[dIndex].collectedEntries.append(contentsOf: entry.collectedEntries)
            }
        case .tagTree:
            guard let tree = entry.tree, !trees.contains(where: { $0.id == tree.id }) else { break }
            trees.append(tree)
        }
        reconcileClassifierTypes()
        return true
    }

    @discardableResult
    public mutating func permanentlyDeleteTrashedEntry(_ id: String) -> Bool {
        guard let index = trash.firstIndex(where: { $0.id == id }) else { return false }
        trash.remove(at: index)
        return true
    }

    /// Opportunistic purge: removes trash entries whose lifetime has elapsed.
    /// Called on catalog load and trash interactions rather than on a timer.
    @discardableResult
    public mutating func purgeExpiredTrash(
        nowMilliseconds: Int64 = WorkspaceCatalog.now(),
        ttlMilliseconds: Int64 = TrashedEntry.defaultTTLMilliseconds
    ) -> Int {
        let before = trash.count
        trash.removeAll { nowMilliseconds - $0.deletedAtMilliseconds >= ttlMilliseconds }
        return before - trash.count
    }

    /// Keep classifier types aligned with their current tree and data revisions.
    public mutating func reconcileClassifierTypes() {
        for index in trees.indices {
            TagColorAssignment.reconcileColors(in: &trees[index])
        }
        providerProfiles = providerProfiles.filter { (try? $0.validate()) != nil }
        classifierTypes = classifierTypes.compactMap { classifierType in
            guard let tree = trees.first(where: { $0.id == classifierType.treeID }),
                  let dataset = datasets.first(where: { $0.id == classifierType.datasetID }) else {
                return nil
            }
            var reconciled = classifierType
            reconciled.treeRevision = tree.revision
            reconciled.datasetRevision = dataset.revision
            // A type owns its own tree now; the binding only supplies the shared
            // dataset and the platform. Do not require the binding to hold the
            // type's tree (that would orphan the platform on every reconcile).
            let applicableBinding = reconciled.applicablePlatformID.flatMap { platformID in
                bindings.first(where: { binding in
                    binding.id == platformID && binding.datasetID == dataset.id
                })
            }
            reconciled.applicablePlatformID = applicableBinding?.id
            reconciled.updatedAtMilliseconds = WorkspaceCatalog.now()
            return reconciled
        }
        for index in bindings.indices {
            // Auto-select the sole compatible classifier type for the platform.
            // Ambiguity (zero or several compatible types) leaves the choice to
            // the owner.
            if bindings[index].activeClassifierTypeID == nil,
               let tree = trees.first(where: { $0.id == bindings[index].treeID }),
               let dataset = datasets.first(where: { $0.id == bindings[index].datasetID }) {
                let compatible = classifierTypes.filter { candidate in
                    guard candidate.applicablePlatformID == bindings[index].id,
                          candidate.treeID == tree.id,
                          candidate.treeRevision == tree.revision,
                          candidate.datasetID == dataset.id,
                          candidate.datasetRevision == dataset.revision else {
                        return false
                    }
                    return true
                }
                if compatible.count == 1 {
                    bindings[index].activeClassifierTypeID = compatible[0].id
                }
            }
            guard let classifierTypeID = bindings[index].activeClassifierTypeID else { continue }
            guard let classifierType = classifierTypes.first(where: { $0.id == classifierTypeID }),
                  let tree = trees.first(where: { $0.id == bindings[index].treeID }),
                  let dataset = datasets.first(where: { $0.id == bindings[index].datasetID }),
                  classifierType.treeID == tree.id,
                  classifierType.treeRevision == tree.revision,
                  classifierType.datasetID == dataset.id,
                  classifierType.datasetRevision == dataset.revision,
                  classifierType.applicablePlatformID == bindings[index].id else {
                bindings[index].activeClassifierTypeID = nil
                continue
            }
        }
    }
}
