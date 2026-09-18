import Foundation

// What collection stores per video: the tags projection, the collected platform entry and the classification dataset.
// (Split out of the former WorkspaceAssets.swift; CLASSIFIER-INDEPENDENCE §7.)

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
