import Foundation

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
    /// color migration runs exactly once without invalidating trained models.
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

public enum ClassificationRecordOrigin: String, Codable, Sendable, CaseIterable {
    case manual
    case llmAssist
    case legacy
}

public enum ClassificationReviewStatus: String, Codable, Sendable, CaseIterable {
    case approved
    case pending
    case rejected
}

public struct ClassificationRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var tagIDs: [String]
    public var origin: ClassificationRecordOrigin
    public var review: ClassificationReviewStatus
    public var platformID: String
    public var treeRevision: Int
    public var modelVersion: String?
    public var supersedesID: String?
    public var createdAtMilliseconds: Int64

    public init(id: String = UUID().uuidString, title: String, tagIDs: [String], origin: ClassificationRecordOrigin, review: ClassificationReviewStatus, platformID: String, treeRevision: Int, modelVersion: String? = nil, supersedesID: String? = nil, createdAtMilliseconds: Int64 = WorkspaceCatalog.now()) {
        self.id = id
        self.title = title
        self.tagIDs = tagIDs.sorted()
        self.origin = origin
        self.review = review
        self.platformID = platformID
        self.treeRevision = treeRevision
        self.modelVersion = modelVersion
        self.supersedesID = supersedesID
        self.createdAtMilliseconds = createdAtMilliseconds
    }
}

/// The durable current classification for a content creator within one
/// classifier type. It is deliberately distinct from an entry label: one
/// creator decision can safely supply the labels for each of that creator's
/// locally retained public entries when a local model is trained.
public struct CreatorClassificationRecord: Codable, Equatable, Sendable, Identifiable {
    public static let maximumTagIDs = 64

    public var id: String
    public var classifierTypeID: String
    public var creatorID: String
    public var creatorName: String
    public var platformID: String
    public var treeID: String
    public var treeRevision: Int
    /// Tags explicitly confirmed for this creator. Tags absent from both this
    /// list and `negativeTagIDs` remain undecided.
    public var tagIDs: [String]
    /// Tags explicitly ruled out for this creator. This is deliberately
    /// separate from absent positive tags so each leaf tag can be decided
    /// independently.
    public var negativeTagIDs: [String]
    public var origin: ClassificationRecordOrigin
    public var review: ClassificationReviewStatus
    public var createdAtMilliseconds: Int64
    public var updatedAtMilliseconds: Int64

    public init(
        id: String = UUID().uuidString,
        classifierTypeID: String,
        creatorID: String,
        creatorName: String,
        platformID: String,
        treeID: String,
        treeRevision: Int,
        tagIDs: [String],
        negativeTagIDs: [String] = [],
        origin: ClassificationRecordOrigin,
        review: ClassificationReviewStatus,
        createdAtMilliseconds: Int64 = WorkspaceCatalog.now(),
        updatedAtMilliseconds: Int64 = WorkspaceCatalog.now()
    ) {
        self.id = id
        self.classifierTypeID = classifierTypeID
        self.creatorID = creatorID
        self.creatorName = creatorName
        self.platformID = platformID
        self.treeID = treeID
        self.treeRevision = treeRevision
        self.tagIDs = Array(Set(tagIDs)).sorted()
        self.negativeTagIDs = Array(Set(negativeTagIDs)).sorted()
        self.origin = origin
        self.review = review
        self.createdAtMilliseconds = createdAtMilliseconds
        self.updatedAtMilliseconds = updatedAtMilliseconds
    }

    /// A decision is current per classifier type, creator, and decision
    /// source. Human and explicitly run LLM decisions can therefore both
    /// contribute to the same creator without overwriting one another.
    public var identityKey: String { "\(classifierTypeID)\u{1F}\(platformID)\u{1F}\(creatorID)\u{1F}\(origin.rawValue)" }

    private enum CodingKeys: String, CodingKey {
        case id, classifierTypeID, creatorID, creatorName, platformID, treeID,
             treeRevision, tagIDs, negativeTagIDs, origin, review,
             createdAtMilliseconds, updatedAtMilliseconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        classifierTypeID = try container.decode(String.self, forKey: .classifierTypeID)
        creatorID = try container.decode(String.self, forKey: .creatorID)
        creatorName = try container.decode(String.self, forKey: .creatorName)
        platformID = try container.decode(String.self, forKey: .platformID)
        treeID = try container.decode(String.self, forKey: .treeID)
        treeRevision = try container.decode(Int.self, forKey: .treeRevision)
        tagIDs = Array(Set(try container.decode([String].self, forKey: .tagIDs))).sorted()
        negativeTagIDs = Array(Set(try container.decodeIfPresent([String].self, forKey: .negativeTagIDs) ?? [])).sorted()
        origin = try container.decode(ClassificationRecordOrigin.self, forKey: .origin)
        review = try container.decode(ClassificationReviewStatus.self, forKey: .review)
        createdAtMilliseconds = try container.decode(Int64.self, forKey: .createdAtMilliseconds)
        updatedAtMilliseconds = try container.decode(Int64.self, forKey: .updatedAtMilliseconds)
    }
}

/// Rendered public-content metadata the user has explicitly chosen to retain
/// from a supported browser platform. It is not a classification label and
/// therefore never changes the dataset revision or enters training until the
/// user creates or approves a separate entry or creator classification record.
public struct CollectedPlatformEntry: Codable, Equatable, Sendable, Identifiable {
    public static let maximumRetainedEntries = 5_000
    public static let maximumAttributes = 16
    public static let maximumAttributeKeyLength = 64
    public static let maximumAttributeValueLength = 512
    public static let maximumSuppliedTags = EntryEvidenceValidator.tagLimit

    /// The platform's durable public-content identifier. It is scoped by
    /// `platformID`, so the same raw identifier on different platforms is
    /// retained independently.
    public var id: String
    public var platformID: String
    public var entryID: String
    public var creatorID: String
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
        case id, platformID, entryID, creatorID, creatorName, entryType, title
        case surface, text, summary, suppliedTags, canonicalURL, sourceIconURL
        case attributes, firstObservedAtMilliseconds, lastObservedAtMilliseconds, observationCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        let decodedPlatformID = try container.decode(String.self, forKey: .platformID)
        platformID = decodedPlatformID
        entryID = try container.decode(String.self, forKey: .entryID)
        creatorID = try container.decode(String.self, forKey: .creatorID)
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
    /// Compatibility-only entry rows from earlier development shells. New
    /// labels are creator classifications, and local-model training excludes
    /// these rows because they do not identify a retained creator.
    public var records: [ClassificationRecord]
    /// Creator decisions are the durable source-of-truth labels. Their
    /// associated collected entries become local-training examples only after
    /// the user explicitly saves a manual or LLM-assisted creator decision.
    public var creatorClassifications: [CreatorClassificationRecord]
    /// Browser-collected entries are deliberately separate from labelled
    /// records. They support reviewing a creator's observed public entries,
    /// but cannot silently become model-training material.
    public var collectedEntries: [CollectedPlatformEntry]
    public var revision: Int

    public init(id: String = UUID().uuidString, name: String, records: [ClassificationRecord] = [], creatorClassifications: [CreatorClassificationRecord] = [], collectedEntries: [CollectedPlatformEntry] = [], revision: Int = 1) {
        self.id = id
        self.name = name
        self.records = records
        self.creatorClassifications = creatorClassifications
        self.collectedEntries = Array(collectedEntries.suffix(CollectedPlatformEntry.maximumRetainedEntries))
        self.revision = revision
    }

    /// Replaces the current decision for one classifier type, creator, and
    /// source while retaining its durable identity and original creation time.
    @discardableResult
    public mutating func upsertCreatorClassification(_ classification: CreatorClassificationRecord) -> CreatorClassificationRecord {
        if let index = creatorClassifications.firstIndex(where: { $0.identityKey == classification.identityKey }) {
            var updated = classification
            updated.id = creatorClassifications[index].id
            updated.createdAtMilliseconds = creatorClassifications[index].createdAtMilliseconds
            creatorClassifications[index] = updated
            return updated
        }
        creatorClassifications.append(classification)
        return classification
    }

    /// Removes the current decision for one classifier type, creator, and
    /// source. This is used only after a user explicitly removes that source's
    /// final tag.
    @discardableResult
    public mutating func removeCreatorClassification(
        classifierTypeID: String,
        platformID: String,
        creatorID: String,
        origin: ClassificationRecordOrigin
    ) -> Bool {
        let initialCount = creatorClassifications.count
        creatorClassifications.removeAll { classification in
            classification.classifierTypeID == classifierTypeID &&
            classification.platformID == platformID &&
            classification.creatorID == creatorID &&
            classification.origin == origin
        }
        return creatorClassifications.count != initialCount
    }

    /// Updates a previously seen public entry in place, preserving its first
    /// observation. New raw entries are bounded independently from training
    /// labels and never advance the dataset revision.
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

    private enum CodingKeys: String, CodingKey {
        case id, name, records, creatorClassifications, collectedEntries, revision
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        records = try container.decodeIfPresent([ClassificationRecord].self, forKey: .records) ?? []
        creatorClassifications = try container.decodeIfPresent([CreatorClassificationRecord].self, forKey: .creatorClassifications) ?? []
        collectedEntries = Array((try container.decodeIfPresent([CollectedPlatformEntry].self, forKey: .collectedEntries) ?? []).suffix(CollectedPlatformEntry.maximumRetainedEntries))
        revision = try container.decodeIfPresent(Int.self, forKey: .revision) ?? 1
    }
}

/// Optional base packages that a local model may be configured to use. The
/// identifier is deliberately a package identity, not a provider endpoint or
/// credential. Selecting one stays local and is safe to persist before its
/// package is available on this Mac.
public enum LocalBaseEmbedding: String, Codable, Sendable, CaseIterable {
    case allMiniLML6V2 = "all-MiniLM-L6-v2"
    case allMPNetBaseV2 = "all-mpnet-base-v2"
    case multilingualE5Small = "multilingual-e5-small"
    case multilingualE5Base = "multilingual-e5-base"
    case multilingualE5Large = "multilingual-e5-large"
    case bgeM3 = "bge-m3"
}

public struct LocalModelAsset: Codable, Equatable, Sendable, Identifiable {
    public static let maximumTrainingPlatforms = 32

    public var id: String
    public var name: String
    /// The classifier type this model is bound to. The model inherits its tree,
    /// dataset, and platform from that type; it is never configured independently.
    public var classifierTypeID: String
    public var treeID: String
    public var treeRevision: Int
    public var datasetID: String
    public var datasetRevision: Int
    public var version: Int
    public var isReady: Bool
    /// The resolved single platform this model trains from, snapshotted from the
    /// owning classifier type's applicable platform. A type owns exactly one
    /// platform, so a model trains from a single local source.
    public var trainingPlatformID: String?
    /// Retained only for legacy decode of the former multi-platform setup.
    public var trainingPlatformIDs: [String]?
    /// The creator-decision ids already folded into the persisted artifact.
    /// Training is incremental and accumulates once: each approved decision
    /// contributes exactly one time over the model's life. A reset clears this.
    public var incorporatedDecisionIDs: [String]
    /// `nil` means use the compact on-device embedding learned from the local
    /// corpus. A non-nil value records the requested downloadable base package.
    public var baseEmbeddingID: LocalBaseEmbedding?
    /// The trained local artifact is persisted with the model asset so an
    /// explicit run survives an app restart without any server dependency.
    public var embeddedNeuralModel: EmbeddedNeuralTextClassifier?
    public var embeddedTrainingReport: EmbeddedNeuralTrainingReport?
    public var trainedAtMilliseconds: Int64?

    public init(
        id: String = UUID().uuidString,
        name: String,
        classifierTypeID: String,
        treeID: String,
        treeRevision: Int,
        datasetID: String,
        datasetRevision: Int,
        version: Int = 1,
        isReady: Bool = false,
        trainingPlatformID: String? = nil,
        trainingPlatformIDs: [String]? = nil,
        incorporatedDecisionIDs: [String] = [],
        baseEmbeddingID: LocalBaseEmbedding? = nil,
        embeddedNeuralModel: EmbeddedNeuralTextClassifier? = nil,
        embeddedTrainingReport: EmbeddedNeuralTrainingReport? = nil,
        trainedAtMilliseconds: Int64? = nil
    ) {
        self.id = id
        self.name = name
        self.classifierTypeID = classifierTypeID
        self.treeID = treeID
        self.treeRevision = treeRevision
        self.datasetID = datasetID
        self.datasetRevision = datasetRevision
        self.version = version
        self.isReady = isReady
        self.trainingPlatformID = trainingPlatformID
        self.trainingPlatformIDs = trainingPlatformIDs.map { Array(Set($0)).sorted() }
        self.incorporatedDecisionIDs = Array(Set(incorporatedDecisionIDs)).sorted()
        self.baseEmbeddingID = baseEmbeddingID
        self.embeddedNeuralModel = embeddedNeuralModel
        self.embeddedTrainingReport = embeddedTrainingReport
        self.trainedAtMilliseconds = trainedAtMilliseconds
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, classifierTypeID, treeID, treeRevision, datasetID, datasetRevision,
             version, isReady, trainingPlatformID, trainingPlatformIDs, incorporatedDecisionIDs,
             baseEmbeddingID, embeddedNeuralModel, embeddedTrainingReport, trainedAtMilliseconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        // Absent on models persisted before the model became bound to a type;
        // `WorkspaceCatalog` migration rebinds these from the legacy selection.
        classifierTypeID = try container.decodeIfPresent(String.self, forKey: .classifierTypeID) ?? ""
        treeID = try container.decode(String.self, forKey: .treeID)
        treeRevision = try container.decode(Int.self, forKey: .treeRevision)
        datasetID = try container.decode(String.self, forKey: .datasetID)
        datasetRevision = try container.decode(Int.self, forKey: .datasetRevision)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        isReady = try container.decodeIfPresent(Bool.self, forKey: .isReady) ?? false
        trainingPlatformID = try container.decodeIfPresent(String.self, forKey: .trainingPlatformID)
        trainingPlatformIDs = (try container.decodeIfPresent([String].self, forKey: .trainingPlatformIDs))
            .map { Array(Set($0)).sorted() }
        incorporatedDecisionIDs = Array(Set(try container.decodeIfPresent([String].self, forKey: .incorporatedDecisionIDs) ?? [])).sorted()
        baseEmbeddingID = try container.decodeIfPresent(LocalBaseEmbedding.self, forKey: .baseEmbeddingID)
        embeddedNeuralModel = try container.decodeIfPresent(EmbeddedNeuralTextClassifier.self, forKey: .embeddedNeuralModel)
        embeddedTrainingReport = try container.decodeIfPresent(EmbeddedNeuralTrainingReport.self, forKey: .embeddedTrainingReport)
        trainedAtMilliseconds = try container.decodeIfPresent(Int64.self, forKey: .trainedAtMilliseconds)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(classifierTypeID, forKey: .classifierTypeID)
        try container.encode(treeID, forKey: .treeID)
        try container.encode(treeRevision, forKey: .treeRevision)
        try container.encode(datasetID, forKey: .datasetID)
        try container.encode(datasetRevision, forKey: .datasetRevision)
        try container.encode(version, forKey: .version)
        try container.encode(isReady, forKey: .isReady)
        try container.encodeIfPresent(trainingPlatformID, forKey: .trainingPlatformID)
        try container.encodeIfPresent(trainingPlatformIDs, forKey: .trainingPlatformIDs)
        try container.encode(incorporatedDecisionIDs, forKey: .incorporatedDecisionIDs)
        try container.encodeIfPresent(baseEmbeddingID, forKey: .baseEmbeddingID)
        try container.encodeIfPresent(embeddedNeuralModel, forKey: .embeddedNeuralModel)
        try container.encodeIfPresent(embeddedTrainingReport, forKey: .embeddedTrainingReport)
        try container.encodeIfPresent(trainedAtMilliseconds, forKey: .trainedAtMilliseconds)
    }

    public var effectiveTrainingPlatformIDs: [String] {
        let configured = trainingPlatformIDs ?? trainingPlatformID.map { [$0] } ?? []
        return Array(Set(configured)).sorted()
    }
}

/// The source used to make a classifier-type decision. The order in a
/// `ClassifierTypeAsset` is an explicit user policy, not an automatic model
/// fallback: LLM work always remains an independently initiated action.
public enum ClassifierDecisionSource: String, Codable, Sendable, CaseIterable {
    case human
    case llmAssist
    case localModel
}

/// Web search is either executed by the model provider or exposed to the
/// classifier model as one app-owned external function. The attached mode is
/// deliberately not a prefetch: the model decides whether to call it.
public enum LLMWebSearchMode: String, Codable, Sendable, CaseIterable {
    case off
    case providerNative
    case attached
}

/// The one explicit LLM decision configuration a classifier type may use.
/// It contains no credential material: `providerProfileID` refers to a
/// separate local profile. The credential is not duplicated into this
/// classifier configuration.
public struct LLMAssistConfiguration: Codable, Equatable, Sendable {
    public static let maximumModelIdentifierLength = 256
    public static let defaultDailyTokenLimit = 10_000
    public static let maximumDailyTokenLimit = 1_000_000
    public static let defaultMaximumOutputTokensPerRequest = 4_096
    public static let maximumOutputTokensPerRequest = 1_000_000
    public static let maximumExtraDirectionLength = 4_096
    /// The conservative default leaves ten seconds between provider requests.
    public static let defaultClassificationRequestsPerMinute = 6
    public static let maximumClassificationRequestsPerMinute = 120
    public static let defaultBatchSize = 5
    public static let maximumBatchSize = 32
    /// The maximum official recent-content records requested by any platform
    /// adapter. An adapter may return fewer when its documented API has a lower
    /// limit, but no platform receives a smaller app-owned evidence setting.
    public static let defaultOfficialContentEvidenceCount = 25
    public static let maximumOfficialContentEvidenceCount = 50
    public static let defaultMaximumTagCount = 8

    public var providerProfileID: String
    public var modelIdentifier: String
    /// A per-classifier-type daily ceiling. Individual provider requests are
    /// also capped by the remaining allowance and the user's per-request cap.
    public var dailyTokenLimit: Int
    /// The maximum output-token allowance sent for one model request. The
    /// remaining daily allowance can lower the effective request cap.
    public var maximumOutputTokensPerRequest: Int
    /// Optional owner-authored classification context appended before the
    /// fixed output contract. It cannot expand the accepted response schema.
    public var extraDirection: String
    /// The maximum rate at which the app starts model-classification requests.
    /// Provider response time may make completed classifications slower.
    public var classificationRequestsPerMinute: Int
    /// The number of creators an explicit batch action may classify in order.
    public var batchSize: Int
    /// The maximum number of recent official content records requested by the
    /// applicable platform adapter for one creator prompt.
    public var officialContentEvidenceCount: Int
    /// A bounded response may contain no more than this many tag IDs.
    public var maximumTagCount: Int
    /// When enabled, only active leaf tags are included in the model prompt.
    /// When disabled, active parent tags are also available as generic labels.
    public var restrictToLeafTags: Bool
    /// Selects either provider-hosted search or one app-owned external search
    /// function. Off means no search capability is sent to the model.
    public var webSearchMode: LLMWebSearchMode
    /// The Serper or You.com Search connection executed only after the same
    /// classifier model calls the attached `web_search` function.
    public var webSearchProviderProfileID: String?
    /// Activation is an explicit per-classifier-type permission for the app to
    /// classify eligible collected creators sequentially.
    public var isActive: Bool

    public init(
        providerProfileID: String,
        modelIdentifier: String,
        dailyTokenLimit: Int = Self.defaultDailyTokenLimit,
        maximumOutputTokensPerRequest: Int = Self.defaultMaximumOutputTokensPerRequest,
        extraDirection: String = "",
        classificationRequestsPerMinute: Int = Self.defaultClassificationRequestsPerMinute,
        batchSize: Int = Self.defaultBatchSize,
        officialContentEvidenceCount: Int = Self.defaultOfficialContentEvidenceCount,
        maximumTagCount: Int = Self.defaultMaximumTagCount,
        restrictToLeafTags: Bool = true,
        webSearchMode: LLMWebSearchMode = .off,
        webSearchProviderProfileID: String? = nil,
        isActive: Bool = false
    ) {
        self.providerProfileID = providerProfileID
        self.modelIdentifier = modelIdentifier
        self.dailyTokenLimit = dailyTokenLimit
        self.maximumOutputTokensPerRequest = maximumOutputTokensPerRequest
        self.extraDirection = String(extraDirection.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maximumExtraDirectionLength))
        self.classificationRequestsPerMinute = classificationRequestsPerMinute
        self.batchSize = batchSize
        self.officialContentEvidenceCount = officialContentEvidenceCount
        self.maximumTagCount = maximumTagCount
        self.restrictToLeafTags = restrictToLeafTags
        self.webSearchMode = webSearchMode
        let cleanedSearchProfileID = webSearchProviderProfileID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.webSearchProviderProfileID = webSearchMode == .attached && !cleanedSearchProfileID.isEmpty
            ? cleanedSearchProfileID
            : nil
        self.isActive = isActive
    }

    public func validate() throws {
        let cleanedProviderProfileID = providerProfileID.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedModelIdentifier = modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedSearchProfileID = webSearchProviderProfileID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !cleanedProviderProfileID.isEmpty, cleanedProviderProfileID.count <= 128,
              !cleanedModelIdentifier.isEmpty, cleanedModelIdentifier.count <= Self.maximumModelIdentifierLength,
              dailyTokenLimit > 0, dailyTokenLimit <= Self.maximumDailyTokenLimit,
              maximumOutputTokensPerRequest > 0, maximumOutputTokensPerRequest <= Self.maximumOutputTokensPerRequest,
              extraDirection.count <= Self.maximumExtraDirectionLength,
              classificationRequestsPerMinute > 0,
              classificationRequestsPerMinute <= Self.maximumClassificationRequestsPerMinute,
              batchSize > 0, batchSize <= Self.maximumBatchSize,
              officialContentEvidenceCount > 0,
              officialContentEvidenceCount <= Self.maximumOfficialContentEvidenceCount,
              maximumTagCount > 0, maximumTagCount <= EntryEvidenceValidator.tagLimit,
              cleanedSearchProfileID.count <= 128,
              (webSearchMode == .attached) == !cleanedSearchProfileID.isEmpty else {
            throw LLMAssistConfigurationError.invalidConfiguration
        }
    }

    private enum CodingKeys: String, CodingKey {
        case providerProfileID, modelIdentifier, dailyTokenLimit, maximumOutputTokensPerRequest, extraDirection, classificationRequestsPerMinute, batchSize,
             officialContentEvidenceCount, maximumTagCount, restrictToLeafTags, webSearchMode, webSearchEnabled, webSearchProviderProfileID, isActive,
             dailyOutputTokenLimit, youtubeVideoEvidenceCount,
             webResearchProviderProfileID, webResearchModelIdentifier,
             externalToolEnabled, usePlatformAPIKeyFallback,
             maximumTokens, externalToolProfileID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providerProfileID = try container.decode(String.self, forKey: .providerProfileID)
        modelIdentifier = try container.decode(String.self, forKey: .modelIdentifier)
        // Previous per-request token caps and hand-picked tool profile IDs are
        // retired. Decode them only as ignored keys so existing local state
        // opens safely; never restore their old behaviour.
        dailyTokenLimit = try container.decodeIfPresent(Int.self, forKey: .dailyTokenLimit)
            ?? container.decodeIfPresent(Int.self, forKey: .dailyOutputTokenLimit)
            ?? Self.defaultDailyTokenLimit
        maximumOutputTokensPerRequest = try container.decodeIfPresent(Int.self, forKey: .maximumOutputTokensPerRequest)
            ?? Self.defaultMaximumOutputTokensPerRequest
        extraDirection = String((try container.decodeIfPresent(String.self, forKey: .extraDirection) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(Self.maximumExtraDirectionLength))
        classificationRequestsPerMinute = try container.decodeIfPresent(Int.self, forKey: .classificationRequestsPerMinute)
            ?? Self.defaultClassificationRequestsPerMinute
        batchSize = try container.decodeIfPresent(Int.self, forKey: .batchSize) ?? Self.defaultBatchSize
        officialContentEvidenceCount = try container.decodeIfPresent(Int.self, forKey: .officialContentEvidenceCount)
            ?? container.decodeIfPresent(Int.self, forKey: .youtubeVideoEvidenceCount)
            ?? Self.defaultOfficialContentEvidenceCount
        maximumTagCount = try container.decodeIfPresent(Int.self, forKey: .maximumTagCount)
            ?? Self.defaultMaximumTagCount
        restrictToLeafTags = try container.decodeIfPresent(Bool.self, forKey: .restrictToLeafTags) ?? true
        let decodedSearchProfileID = (try container.decodeIfPresent(String.self, forKey: .webSearchProviderProfileID)?
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
        if let decodedMode = try container.decodeIfPresent(LLMWebSearchMode.self, forKey: .webSearchMode) {
            webSearchMode = decodedMode
        } else if try container.decodeIfPresent(Bool.self, forKey: .webSearchEnabled) == true {
            webSearchMode = decodedSearchProfileID.isEmpty ? .providerNative : .attached
        } else {
            webSearchMode = .off
        }
        webSearchProviderProfileID = webSearchMode == .attached && !decodedSearchProfileID.isEmpty
            ? decodedSearchProfileID
            : nil
        // The retired two-model research selection is intentionally discarded.
        // It is decoded only so existing local state opens without a crash.
        _ = try container.decodeIfPresent(String.self, forKey: .webResearchProviderProfileID)
        _ = try container.decodeIfPresent(String.self, forKey: .webResearchModelIdentifier)
        // These retired toggles are read only to let existing local state open
        // safely. Creator evidence now follows the platform's fixed strategy;
        // public creator-page scraping has no replacement path.
        _ = try container.decodeIfPresent(Bool.self, forKey: .externalToolEnabled)
        _ = try container.decodeIfPresent(Bool.self, forKey: .usePlatformAPIKeyFallback)
        isActive = try container.decodeIfPresent(Bool.self, forKey: .isActive) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(providerProfileID, forKey: .providerProfileID)
        try container.encode(modelIdentifier, forKey: .modelIdentifier)
        try container.encode(dailyTokenLimit, forKey: .dailyTokenLimit)
        try container.encode(maximumOutputTokensPerRequest, forKey: .maximumOutputTokensPerRequest)
        try container.encode(extraDirection, forKey: .extraDirection)
        try container.encode(classificationRequestsPerMinute, forKey: .classificationRequestsPerMinute)
        try container.encode(batchSize, forKey: .batchSize)
        try container.encode(officialContentEvidenceCount, forKey: .officialContentEvidenceCount)
        try container.encode(maximumTagCount, forKey: .maximumTagCount)
        try container.encode(restrictToLeafTags, forKey: .restrictToLeafTags)
        try container.encode(webSearchMode, forKey: .webSearchMode)
        try container.encodeIfPresent(webSearchProviderProfileID, forKey: .webSearchProviderProfileID)
        try container.encode(isActive, forKey: .isActive)
    }
}

public enum LLMAssistConfigurationError: Error, Equatable, LocalizedError, Sendable {
    case invalidConfiguration

    public var errorDescription: String? {
        "The LLM-assist configuration is invalid."
    }
}

/// Durable form state for a selected provider before it has one fetched model
/// attached. Keeping this separate from `LLMAssistConfiguration` means a
/// rerender or relaunch cannot discard edits simply because model selection is
/// the last step of configuration.
public struct LLMAssistDraftConfiguration: Codable, Equatable, Sendable {
    public var providerProfileID: String
    public var dailyTokenLimit: Int
    public var maximumOutputTokensPerRequest: Int
    public var extraDirection: String
    public var classificationRequestsPerMinute: Int
    public var batchSize: Int
    public var officialContentEvidenceCount: Int
    public var maximumTagCount: Int
    public var restrictToLeafTags: Bool
    public var webSearchMode: LLMWebSearchMode
    public var webSearchProviderProfileID: String?

    public init(
        providerProfileID: String,
        dailyTokenLimit: Int = LLMAssistConfiguration.defaultDailyTokenLimit,
        maximumOutputTokensPerRequest: Int = LLMAssistConfiguration.defaultMaximumOutputTokensPerRequest,
        extraDirection: String = "",
        classificationRequestsPerMinute: Int = LLMAssistConfiguration.defaultClassificationRequestsPerMinute,
        batchSize: Int = LLMAssistConfiguration.defaultBatchSize,
        officialContentEvidenceCount: Int = LLMAssistConfiguration.defaultOfficialContentEvidenceCount,
        maximumTagCount: Int = LLMAssistConfiguration.defaultMaximumTagCount,
        restrictToLeafTags: Bool = true,
        webSearchMode: LLMWebSearchMode = .off,
        webSearchProviderProfileID: String? = nil
    ) {
        self.providerProfileID = providerProfileID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.dailyTokenLimit = dailyTokenLimit
        self.maximumOutputTokensPerRequest = maximumOutputTokensPerRequest
        self.extraDirection = String(extraDirection.trimmingCharacters(in: .whitespacesAndNewlines).prefix(LLMAssistConfiguration.maximumExtraDirectionLength))
        self.classificationRequestsPerMinute = classificationRequestsPerMinute
        self.batchSize = batchSize
        self.officialContentEvidenceCount = officialContentEvidenceCount
        self.maximumTagCount = maximumTagCount
        self.restrictToLeafTags = restrictToLeafTags
        self.webSearchMode = webSearchMode
        let cleanedSearchProfileID = webSearchProviderProfileID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.webSearchProviderProfileID = webSearchMode == .attached && !cleanedSearchProfileID.isEmpty
            ? cleanedSearchProfileID
            : nil
    }

    public func validate() throws {
        try configuration(modelIdentifier: "draft-model").validate()
    }

    private enum CodingKeys: String, CodingKey {
        case providerProfileID, dailyTokenLimit, maximumOutputTokensPerRequest,
             extraDirection, classificationRequestsPerMinute, batchSize,
             officialContentEvidenceCount, maximumTagCount, restrictToLeafTags,
             webSearchMode, webSearchProviderProfileID,
             dailyOutputTokenLimit, youtubeVideoEvidenceCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            providerProfileID: try container.decode(String.self, forKey: .providerProfileID),
            dailyTokenLimit: try container.decodeIfPresent(Int.self, forKey: .dailyTokenLimit)
                ?? container.decodeIfPresent(Int.self, forKey: .dailyOutputTokenLimit)
                ?? LLMAssistConfiguration.defaultDailyTokenLimit,
            maximumOutputTokensPerRequest: try container.decodeIfPresent(Int.self, forKey: .maximumOutputTokensPerRequest)
                ?? LLMAssistConfiguration.defaultMaximumOutputTokensPerRequest,
            extraDirection: try container.decodeIfPresent(String.self, forKey: .extraDirection) ?? "",
            classificationRequestsPerMinute: try container.decodeIfPresent(Int.self, forKey: .classificationRequestsPerMinute)
                ?? LLMAssistConfiguration.defaultClassificationRequestsPerMinute,
            batchSize: try container.decodeIfPresent(Int.self, forKey: .batchSize)
                ?? LLMAssistConfiguration.defaultBatchSize,
            officialContentEvidenceCount: try container.decodeIfPresent(Int.self, forKey: .officialContentEvidenceCount)
                ?? container.decodeIfPresent(Int.self, forKey: .youtubeVideoEvidenceCount)
                ?? LLMAssistConfiguration.defaultOfficialContentEvidenceCount,
            maximumTagCount: try container.decodeIfPresent(Int.self, forKey: .maximumTagCount)
                ?? LLMAssistConfiguration.defaultMaximumTagCount,
            restrictToLeafTags: try container.decodeIfPresent(Bool.self, forKey: .restrictToLeafTags) ?? true,
            webSearchMode: try container.decodeIfPresent(LLMWebSearchMode.self, forKey: .webSearchMode) ?? .off,
            webSearchProviderProfileID: try container.decodeIfPresent(String.self, forKey: .webSearchProviderProfileID)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(providerProfileID, forKey: .providerProfileID)
        try container.encode(dailyTokenLimit, forKey: .dailyTokenLimit)
        try container.encode(maximumOutputTokensPerRequest, forKey: .maximumOutputTokensPerRequest)
        try container.encode(extraDirection, forKey: .extraDirection)
        try container.encode(classificationRequestsPerMinute, forKey: .classificationRequestsPerMinute)
        try container.encode(batchSize, forKey: .batchSize)
        try container.encode(officialContentEvidenceCount, forKey: .officialContentEvidenceCount)
        try container.encode(maximumTagCount, forKey: .maximumTagCount)
        try container.encode(restrictToLeafTags, forKey: .restrictToLeafTags)
        try container.encode(webSearchMode, forKey: .webSearchMode)
        try container.encodeIfPresent(webSearchProviderProfileID, forKey: .webSearchProviderProfileID)
    }

    public func configuration(modelIdentifier: String, isActive: Bool = false) -> LLMAssistConfiguration {
        .init(
            providerProfileID: providerProfileID,
            modelIdentifier: modelIdentifier,
            dailyTokenLimit: dailyTokenLimit,
            maximumOutputTokensPerRequest: maximumOutputTokensPerRequest,
            extraDirection: extraDirection,
            classificationRequestsPerMinute: classificationRequestsPerMinute,
            batchSize: batchSize,
            officialContentEvidenceCount: officialContentEvidenceCount,
            maximumTagCount: maximumTagCount,
            restrictToLeafTags: restrictToLeafTags,
            webSearchMode: webSearchMode,
            webSearchProviderProfileID: webSearchProviderProfileID,
            isActive: isActive
        )
    }
}

/// A reusable decision brain. It deliberately binds immutable revisions of a
/// tree and data asset, so a model trained against an older revision cannot be
/// selected silently after an edit.
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
    /// Legacy pointer to a formerly user-selected model. A local model is now
    /// bound to its classifier type (owns-one) and resolved by reverse lookup,
    /// not selected here. This is retained only so `WorkspaceCatalog` migration
    /// can rebind the model to its type; it is never part of the authored API
    /// and is never re-encoded.
    public internal(set) var legacyLocalModelID: String?
    /// The provider shown in the LLM Assist editor. This is a persistent
    /// pre-attachment choice, so a user can Probe and choose a provider before
    /// selecting a model. It cannot authorize or activate provider work.
    public var selectedLLMProviderProfileID: String?
    /// Edits made before a fetched model is chosen. This is not executable
    /// configuration and cannot activate or dispatch LLM work.
    public var llmAssistDraftConfiguration: LLMAssistDraftConfiguration?
    /// One configured model may be attached for explicit runs. Its credential
    /// connection stays separate from this classification policy.
    public var llmAssistConfiguration: LLMAssistConfiguration?
    /// Ordered once by the user. Every available source contributes to a
    /// decision, with relative weights of 3, 2, and 1 in this order.
    public var decisionPriority: [ClassifierDecisionSource]
    public var updatedAtMilliseconds: Int64

    public init(
        id: String = UUID().uuidString,
        name: String,
        treeID: String,
        treeRevision: Int,
        datasetID: String,
        datasetRevision: Int,
        applicablePlatformID: String? = nil,
        selectedLLMProviderProfileID: String? = nil,
        llmAssistDraftConfiguration: LLMAssistDraftConfiguration? = nil,
        llmAssistConfiguration: LLMAssistConfiguration? = nil,
        decisionPriority: [ClassifierDecisionSource] = [.human, .llmAssist, .localModel],
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
        self.legacyLocalModelID = nil
        let cleanedLLMProviderID = selectedLLMProviderProfileID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.selectedLLMProviderProfileID = cleanedLLMProviderID.isEmpty
            ? llmAssistConfiguration?.providerProfileID
            : cleanedLLMProviderID
        self.llmAssistDraftConfiguration = llmAssistDraftConfiguration
        self.llmAssistConfiguration = llmAssistConfiguration
        self.decisionPriority = decisionPriority
        self.updatedAtMilliseconds = updatedAtMilliseconds
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, treeID, treeRevision, datasetID, datasetRevision, applicablePlatformID, dataSourcePlatformIDs, localModelID,
             selectedLLMProviderProfileID,
             llmAssistDraftConfiguration, llmAssistConfiguration, llmProfileIDs, decisionPriority, updatedAtMilliseconds
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
        if !decodedPlatformID.isEmpty {
            applicablePlatformID = decodedPlatformID
        } else {
            // The retired multi-source field is read only as a bounded crash
            // guard. It can be preserved only when it already described one
            // platform; a combined legacy type must be configured again.
            let legacyPlatformIDs = Array(Set(try container.decodeIfPresent([String].self, forKey: .dataSourcePlatformIDs) ?? []))
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            applicablePlatformID = legacyPlatformIDs.count == 1 ? legacyPlatformIDs[0] : nil
        }
        // Read the retired selection only so catalog migration can rebind the
        // model to this type. It is not re-encoded and never selected again.
        legacyLocalModelID = try container.decodeIfPresent(String.self, forKey: .localModelID)
        // The former multi-profile selection had no model-specific policy. It
        // is intentionally ignored rather than recreated as an implicit LLM
        // attachment; users configure one explicit model again.
        llmAssistConfiguration = try container.decodeIfPresent(LLMAssistConfiguration.self, forKey: .llmAssistConfiguration)
        let decodedSelectedLLMProviderID = (try container.decodeIfPresent(String.self, forKey: .selectedLLMProviderProfileID)?
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
        selectedLLMProviderProfileID = decodedSelectedLLMProviderID.isEmpty
            ? llmAssistConfiguration?.providerProfileID
            : decodedSelectedLLMProviderID
        llmAssistDraftConfiguration = try container.decodeIfPresent(LLMAssistDraftConfiguration.self, forKey: .llmAssistDraftConfiguration)
        decisionPriority = try container.decodeIfPresent([ClassifierDecisionSource].self, forKey: .decisionPriority)
            ?? [.human, .llmAssist, .localModel]
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
        try container.encodeIfPresent(selectedLLMProviderProfileID, forKey: .selectedLLMProviderProfileID)
        try container.encodeIfPresent(llmAssistDraftConfiguration, forKey: .llmAssistDraftConfiguration)
        try container.encodeIfPresent(llmAssistConfiguration, forKey: .llmAssistConfiguration)
        try container.encode(decisionPriority, forKey: .decisionPriority)
        try container.encode(updatedAtMilliseconds, forKey: .updatedAtMilliseconds)
    }

    public func decisionWeight(for source: ClassifierDecisionSource) -> Double {
        guard let index = decisionPriority.firstIndex(of: source) else { return 0 }
        return Double(ClassifierDecisionSource.allCases.count - index)
    }
}

public enum LocalModelTrainingError: Error, Equatable, LocalizedError, Sendable {
    case incompatibleTree
    case incompatibleDataset
    case missingPlatform
    case noApprovedExamples

    public var errorDescription: String? {
        switch self {
        case .incompatibleTree:
            return "The local model is not configured for this tag tree revision."
        case .incompatibleDataset:
            return "The local model is not configured for this classification dataset revision."
        case .missingPlatform:
            return "Choose a classification-data platform before training this local model."
        case .noApprovedExamples:
            return "Add approved manual or LLM-assisted labels for this tree and platform before training."
        }
    }
}

/// Converts immutable, approved creator classifications into on-device neural
/// samples. A creator decision expands through that creator's retained public
/// entries; browsing activity, legacy entry-level rows, and labels from another
/// tree revision never become training data.
public enum LocalModelTrainer {
    public static let defaultEpochs = 48

    /// Expands one approved creator decision into per-entry neural examples from
    /// that creator's retained public entries. Labels are filtered to the tree's
    /// predictable leaves; a decision with no predictable label or no matching
    /// entry yields nothing and is therefore not trainable.
    private static func examples(
        for classification: CreatorClassificationRecord,
        in dataset: ClassificationDataset,
        availableTagIDs: Set<String>
    ) -> [EmbeddedNeuralTrainingExample] {
        let positiveLabelIDs = classification.tagIDs.filter { availableTagIDs.contains($0) }
        let negativeLabelIDs = classification.negativeTagIDs.filter { availableTagIDs.contains($0) }
        guard !positiveLabelIDs.isEmpty || !negativeLabelIDs.isEmpty else { return [] }
        return dataset.collectedEntries.compactMap { entry in
            guard entry.platformID == classification.platformID,
                  entry.creatorID == classification.creatorID,
                  !entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return .init(
                text: entry.title,
                positiveLabelIDs: positiveLabelIDs,
                negativeLabelIDs: negativeLabelIDs
            )
        }
    }

    public static func approvedExamples(
        for tree: TagTreeAsset,
        dataset: ClassificationDataset,
        platformID: String
    ) -> [EmbeddedNeuralTrainingExample] {
        return approvedExamples(for: tree, dataset: dataset, platformIDs: [platformID])
    }

    public static func approvedExamples(
        for tree: TagTreeAsset,
        dataset: ClassificationDataset,
        platformIDs: [String]
    ) -> [EmbeddedNeuralTrainingExample] {
        let sourcePlatformIDs = Set(platformIDs)
        guard !sourcePlatformIDs.isEmpty else { return [] }
        let availableTagIDs = (try? tree.inferenceTaxonomy())?.predictableLeafIDs ?? []
        return dataset.creatorClassifications.flatMap { classification -> [EmbeddedNeuralTrainingExample] in
            guard classification.review == .approved,
                  classification.origin == .manual || classification.origin == .llmAssist,
                  sourcePlatformIDs.contains(classification.platformID),
                  classification.treeID == tree.id,
                  classification.treeRevision == tree.revision else {
                return []
            }
            return examples(for: classification, in: dataset, availableTagIDs: availableTagIDs)
        }
    }

    /// The approved manual/LLM creator decisions for a classifier type at a tree
    /// revision that currently expand to at least one neural example — the exact
    /// set eligible to be folded into that type's model, in a stable order.
    public static func approvedDecisions(
        for type: ClassifierTypeAsset,
        in dataset: ClassificationDataset,
        tree: TagTreeAsset
    ) -> [CreatorClassificationRecord] {
        guard let platformID = type.applicablePlatformID else { return [] }
        let availableTagIDs = (try? tree.inferenceTaxonomy())?.predictableLeafIDs ?? []
        return dataset.creatorClassifications
            .filter { classification in
                classification.review == .approved &&
                (classification.origin == .manual || classification.origin == .llmAssist) &&
                classification.classifierTypeID == type.id &&
                classification.platformID == platformID &&
                classification.treeID == tree.id &&
                classification.treeRevision == tree.revision &&
                !examples(for: classification, in: dataset, availableTagIDs: availableTagIDs).isEmpty
            }
            .sorted { ($0.createdAtMilliseconds, $0.id) < ($1.createdAtMilliseconds, $1.id) }
    }

    /// Folds newly approved creator decisions for the model's classifier type
    /// into its persisted artifact. Training is incremental and accumulate-once:
    /// the model keeps its weights and each eligible decision contributes exactly
    /// one online pass over the life of the artifact. A change of tree revision,
    /// label set, or bound dataset resets the artifact and re-folds from empty.
    /// A continue pass with nothing new returns the model unchanged.
    public static func accumulate(
        _ model: LocalModelAsset,
        type: ClassifierTypeAsset,
        tree: TagTreeAsset,
        dataset: ClassificationDataset,
        configuration: EmbeddedNeuralModelConfiguration = .init()
    ) throws -> LocalModelAsset {
        guard let platformID = type.applicablePlatformID else {
            throw LocalModelTrainingError.missingPlatform
        }
        guard tree.id == type.treeID, tree.revision == type.treeRevision else {
            throw LocalModelTrainingError.incompatibleTree
        }
        guard dataset.id == type.datasetID else {
            throw LocalModelTrainingError.incompatibleDataset
        }
        // The label space is the tree's full predictable leaf taxonomy so any
        // decision at this revision is representable by an output head.
        let currentLabelIDs = Array((try? tree.inferenceTaxonomy())?.predictableLeafIDs ?? []).sorted()
        guard !currentLabelIDs.isEmpty else {
            throw LocalModelTrainingError.noApprovedExamples
        }

        let existing = model.embeddedNeuralModel
        let canContinue = existing != nil &&
            model.classifierTypeID == type.id &&
            model.treeID == tree.id &&
            model.treeRevision == tree.revision &&
            model.datasetID == dataset.id &&
            existing.map { Set($0.labelIDs) == Set(currentLabelIDs) } == true
        let reset = !canContinue

        let eligibleDecisions = approvedDecisions(for: type, in: dataset, tree: tree)
        var incorporated = reset ? Set<String>() : Set(model.incorporatedDecisionIDs)
        let decisionsToFold = eligibleDecisions.filter { !incorporated.contains($0.id) }

        let availableTagIDs = Set(currentLabelIDs)
        let foldExamples = decisionsToFold.flatMap {
            examples(for: $0, in: dataset, availableTagIDs: availableTagIDs)
        }

        // A continue pass with nothing new to fold is a no-op: the artifact and
        // its ledger are already current. The caller surfaces "up to date".
        if !reset, decisionsToFold.isEmpty {
            var refreshed = model
            refreshed.datasetRevision = dataset.revision
            refreshed.trainingPlatformID = platformID
            refreshed.trainingPlatformIDs = [platformID]
            return refreshed
        }

        guard !foldExamples.isEmpty else {
            throw LocalModelTrainingError.noApprovedExamples
        }

        var classifier: EmbeddedNeuralTextClassifier
        if reset {
            // Build the vocabulary from every eligible decision at this revision
            // so continued passes share a stable, representative token space.
            let vocabularyExamples = eligibleDecisions.flatMap {
                examples(for: $0, in: dataset, availableTagIDs: availableTagIDs)
            }
            let vocabulary = LocalEmbeddingVocabulary.build(
                from: vocabularyExamples.isEmpty ? foldExamples : vocabularyExamples,
                limit: configuration.vocabularyLimit
            )
            classifier = try EmbeddedNeuralTextClassifier(
                configuration: configuration,
                labelIDs: currentLabelIDs,
                vocabulary: vocabulary
            )
        } else {
            classifier = existing!
        }

        let runReport = try classifier.train(foldExamples, epochs: 1)
        for decision in decisionsToFold { incorporated.insert(decision.id) }

        var trained = model
        trained.classifierTypeID = type.id
        trained.treeID = tree.id
        trained.treeRevision = tree.revision
        trained.datasetID = dataset.id
        trained.datasetRevision = dataset.revision
        trained.trainingPlatformID = platformID
        trained.trainingPlatformIDs = [platformID]
        trained.incorporatedDecisionIDs = incorporated.sorted()
        trained.version += 1
        trained.isReady = true
        trained.embeddedNeuralModel = classifier
        trained.embeddedTrainingReport = EmbeddedNeuralTrainingReport(
            epochs: runReport.epochs,
            exampleCount: runReport.exampleCount,
            labelUpdateCount: runReport.labelUpdateCount,
            meanBinaryCrossEntropy: runReport.meanBinaryCrossEntropy,
            decisionsFolded: decisionsToFold.count,
            incorporatedDecisions: incorporated.count
        )
        trained.trainedAtMilliseconds = WorkspaceCatalog.now()
        return trained
    }

    public static func train(
        _ model: LocalModelAsset,
        tree: TagTreeAsset,
        dataset: ClassificationDataset,
        epochs: Int = defaultEpochs,
        configuration: EmbeddedNeuralModelConfiguration = .init()
    ) throws -> LocalModelAsset {
        guard model.treeID == tree.id, model.treeRevision == tree.revision else {
            throw LocalModelTrainingError.incompatibleTree
        }
        guard model.datasetID == dataset.id, model.datasetRevision == dataset.revision else {
            throw LocalModelTrainingError.incompatibleDataset
        }
        let platformIDs = model.effectiveTrainingPlatformIDs
        guard !platformIDs.isEmpty else {
            throw LocalModelTrainingError.missingPlatform
        }
        let examples = approvedExamples(for: tree, dataset: dataset, platformIDs: platformIDs)
        let labelIDs = Array(Set(examples.flatMap(\.positiveLabelIDs))).sorted()
        guard !examples.isEmpty, !labelIDs.isEmpty else {
            throw LocalModelTrainingError.noApprovedExamples
        }

        var classifier = try EmbeddedNeuralTextClassifier(
            configuration: configuration,
            labelIDs: labelIDs,
            trainingExamples: examples
        )
        let report = try classifier.train(examples, epochs: epochs)
        var trained = model
        trained.version += 1
        trained.isReady = true
        trained.embeddedNeuralModel = classifier
        trained.embeddedTrainingReport = report
        trained.trainedAtMilliseconds = WorkspaceCatalog.now()
        return trained
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
    /// never contributes training examples to a local model.
    public var supportsLocalModel: Bool
    /// A manual-only platform can retain public entries and human tags, but
    /// must never be sent through an LLM-assist classification path.
    public var supportsLLMAssist: Bool
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
        supportsLocalModel: Bool = true,
        supportsLLMAssist: Bool = true
    ) {
        self.id = id
        self.name = name
        self.browser = browser
        self.sourceKind = sourceKind
        self.collectorAvailable = collectorAvailable
        self.supportsLocalModel = supportsLocalModel
        self.supportsLLMAssist = supportsLLMAssist
    }
}

public enum CollectionPlatformRegistry {
    public static let definitions: [CollectionPlatformDefinition] = [
        .init(id: "youtube", name: "YouTube", collectorAvailable: true),
        .init(id: "tiktok", name: "TikTok", collectorAvailable: true),
        .init(id: "facebook", name: "Facebook", collectorAvailable: true),
        .init(id: "instagram", name: "Instagram", collectorAvailable: true),
        .init(id: "twitch", name: "Twitch", collectorAvailable: true, supportsLocalModel: false, supportsLLMAssist: false),
        .init(id: "reddit", name: "Reddit", sourceKind: .subreddit, collectorAvailable: true, supportsLocalModel: false, supportsLLMAssist: false),
        .init(id: "discord", name: "Discord", sourceKind: .server, collectorAvailable: true, supportsLocalModel: false, supportsLLMAssist: false),
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
    /// The reusable decision configuration selected for this platform. A
    /// binding without a classifier type remains on the legacy engine until
    /// the person explicitly selects one.
    public var activeClassifierTypeID: String?
    public var activeModelID: String?
    public var policyID: String?
    /// Raw public-content collection is on by default for a newly added local
    /// platform binding. The browser still sends nothing unless this binding
    /// exists and its extension-side collection setting is also on.
    public var collectionEnabled: Bool

    public init(id: String, name: String, browser: String = "Chrome and Edge", treeID: String, datasetID: String, activeClassifierTypeID: String? = nil, activeModelID: String? = nil, policyID: String? = nil, collectionEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.browser = browser
        self.treeID = treeID
        self.datasetID = datasetID
        self.activeClassifierTypeID = activeClassifierTypeID
        self.activeModelID = activeModelID
        self.policyID = policyID
        self.collectionEnabled = collectionEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, browser, treeID, datasetID, activeClassifierTypeID, activeModelID, policyID, collectionEnabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        browser = try container.decodeIfPresent(String.self, forKey: .browser) ?? "Chrome and Edge"
        treeID = try container.decode(String.self, forKey: .treeID)
        datasetID = try container.decode(String.self, forKey: .datasetID)
        activeClassifierTypeID = try container.decodeIfPresent(String.self, forKey: .activeClassifierTypeID)
        activeModelID = try container.decodeIfPresent(String.self, forKey: .activeModelID)
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
    public var createdAtMilliseconds: Int64

    public init(id: String = UUID().uuidString, provider: String, model: String, tokenCount: Int, status: String, createdAtMilliseconds: Int64 = WorkspaceCatalog.now()) {
        self.id = id
        self.provider = provider
        self.model = model
        self.tokenCount = max(0, tokenCount)
        self.status = status
        self.createdAtMilliseconds = createdAtMilliseconds
    }

    private enum CodingKeys: String, CodingKey {
        case id, provider, model, tokenCount, status, createdAtMilliseconds
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
        createdAtMilliseconds = try container.decode(Int64.self, forKey: .createdAtMilliseconds)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(provider, forKey: .provider)
        try container.encode(model, forKey: .model)
        try container.encode(tokenCount, forKey: .tokenCount)
        try container.encode(status, forKey: .status)
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
    case missingModel(String)
    case incompatibleActiveModel(String)
    case missingClassifierType(String)
    case incompatibleActiveClassifierType(String)
    case unsupportedCollectionPlatform(String)
    case invalidCollectedEntry(String)
    case invalidCreatorClassification(String)
    case invalidLocalModel(String)
    case invalidProviderProfile(String)
    case invalidClassifierType(String)
    case treeInUse(String)

    public var errorDescription: String? {
        switch self {
        case .duplicateIdentifier(let value): return "Duplicate local asset identifier: \(value)."
        case .missingTree(let value): return "The platform binding references a missing tag tree: \(value)."
        case .missingDataset(let value): return "The platform binding references a missing classification dataset: \(value)."
        case .missingModel(let value): return "The platform binding references a missing local model: \(value)."
        case .incompatibleActiveModel(let value): return "The active local model is not compatible with the platform tree and dataset: \(value)."
        case .missingClassifierType(let value): return "The platform binding references a missing classifier type: \(value)."
        case .incompatibleActiveClassifierType(let value): return "The active classifier type is not compatible with the platform tree and dataset: \(value)."
        case .unsupportedCollectionPlatform(let value): return "The collection platform is not supported: \(value)."
        case .invalidCollectedEntry(let value): return "The collected platform entry is invalid: \(value)."
        case .invalidCreatorClassification(let value): return "The creator classification is invalid: \(value)."
        case .invalidLocalModel(let value): return "The local model has incompatible training data sources: \(value)."
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
    public var creatorClassifications: [CreatorClassificationRecord]
    public var collectedEntries: [CollectedPlatformEntry]
    public var models: [LocalModelAsset]

    public init(
        id: String = UUID().uuidString,
        kind: TrashedEntryKind,
        name: String,
        deletedAtMilliseconds: Int64 = WorkspaceCatalog.now(),
        classifierType: ClassifierTypeAsset? = nil,
        binding: PlatformBinding? = nil,
        tree: TagTreeAsset? = nil,
        datasetID: String? = nil,
        creatorClassifications: [CreatorClassificationRecord] = [],
        collectedEntries: [CollectedPlatformEntry] = [],
        models: [LocalModelAsset] = []
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.deletedAtMilliseconds = deletedAtMilliseconds
        self.classifierType = classifierType
        self.binding = binding
        self.tree = tree
        self.datasetID = datasetID
        self.creatorClassifications = creatorClassifications
        self.collectedEntries = collectedEntries
        self.models = models
    }

    /// Default 24-hour trash lifetime, expressed in milliseconds.
    public static let defaultTTLMilliseconds: Int64 = 24 * 60 * 60 * 1_000
}

public struct WorkspaceCatalog: Codable, Equatable, Sendable {
    public var trees: [TagTreeAsset]
    public var datasets: [ClassificationDataset]
    public var models: [LocalModelAsset]
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

    public init(trees: [TagTreeAsset] = [], datasets: [ClassificationDataset] = [], models: [LocalModelAsset] = [], bindings: [PlatformBinding] = [], classifierTypes: [ClassifierTypeAsset] = [], tokenUsage: [TokenUsageRecord] = [], providerRequestRecords: [ProviderRequestRecord] = [], providerProfiles: [APIKeyProviderProfile] = [], trash: [TrashedEntry] = []) {
        self.trees = trees
        self.datasets = datasets
        self.models = models
        self.bindings = bindings
        self.classifierTypes = classifierTypes
        self.tokenUsage = tokenUsage
        self.providerRequestRecords = providerRequestRecords
        self.providerProfiles = providerProfiles
        self.trash = trash
    }

    public static func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1_000) }

    public static func starter() -> WorkspaceCatalog {
        // A personal tree begins as an empty canvas. The Vault taxonomy remains
        // an optional import rather than an imposed first node or hierarchy.
        let tree = TagTreeAsset(id: "vault-starter", name: "Vault starter tree", nodes: [])
        let dataset = ClassificationDataset(id: "local-dataset", name: "Local classification data")
        return .init(trees: [tree], datasets: [dataset])
    }

    public func validate() throws {
        try unique(trees.map(\.id) + datasets.map(\.id) + models.map(\.id) + bindings.map(\.id) + classifierTypes.map(\.id) + providerProfiles.map(\.id))
        for binding in bindings {
            guard CollectionPlatformRegistry.definition(for: binding.id) != nil else {
                throw WorkspaceCatalogError.unsupportedCollectionPlatform(binding.id)
            }
            guard let tree = trees.first(where: { $0.id == binding.treeID }) else { throw WorkspaceCatalogError.missingTree(binding.treeID) }
            guard let dataset = datasets.first(where: { $0.id == binding.datasetID }) else { throw WorkspaceCatalogError.missingDataset(binding.datasetID) }
            guard let activeModelID = binding.activeModelID else { continue }
            guard let model = models.first(where: { $0.id == activeModelID }) else { throw WorkspaceCatalogError.missingModel(activeModelID) }
            // A model stays valid as approved decisions accrue (the dataset
            // revision only advances); usability is gated by the tree revision,
            // the label-set boundary, not by exact dataset-revision equality.
            guard model.isReady, model.embeddedNeuralModel != nil,
                  model.treeID == tree.id, model.treeRevision == tree.revision,
                  model.datasetID == dataset.id else {
                throw WorkspaceCatalogError.incompatibleActiveModel(activeModelID)
            }
        }
        for model in models {
            // A model is bound to exactly one classifier type and inherits that
            // type's tree, dataset, and single platform.
            guard let owningType = classifierTypes.first(where: { $0.id == model.classifierTypeID }) else {
                throw WorkspaceCatalogError.invalidLocalModel(model.id)
            }
            let sourcePlatformIDs = model.effectiveTrainingPlatformIDs
            guard sourcePlatformIDs.count <= LocalModelAsset.maximumTrainingPlatforms,
                  model.treeID == owningType.treeID,
                  model.datasetID == owningType.datasetID,
                  owningType.applicablePlatformID.map({ sourcePlatformIDs == [$0] }) == true,
                  sourcePlatformIDs.allSatisfy({ platformID in
                      CollectionPlatformRegistry.definition(for: platformID)?.supportsLocalModel == true &&
                      bindings.contains(where: { binding in
                          binding.id == platformID &&
                          binding.treeID == model.treeID &&
                          binding.datasetID == model.datasetID
                      })
                  }) else {
                throw WorkspaceCatalogError.invalidLocalModel(model.id)
            }
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
            var seenCreatorClassifications = Set<String>()
            for classification in dataset.creatorClassifications {
                guard !classification.id.isEmpty,
                      !classification.classifierTypeID.isEmpty,
                      !classification.creatorID.isEmpty,
                      !classification.creatorName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !classification.treeID.isEmpty,
                      classification.treeRevision > 0,
                      CollectionPlatformRegistry.definition(for: classification.platformID) != nil,
                      (!classification.tagIDs.isEmpty || !classification.negativeTagIDs.isEmpty || classification.origin == .llmAssist),
                      classification.tagIDs.count + classification.negativeTagIDs.count <= CreatorClassificationRecord.maximumTagIDs,
                      Set(classification.tagIDs).count == classification.tagIDs.count,
                      Set(classification.negativeTagIDs).count == classification.negativeTagIDs.count,
                      Set(classification.tagIDs).isDisjoint(with: classification.negativeTagIDs),
                      seenCreatorClassifications.insert(classification.identityKey).inserted else {
                    throw WorkspaceCatalogError.invalidCreatorClassification(classification.id)
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
                      binding.id == classifierType.applicablePlatformID && binding.treeID == tree.id && binding.datasetID == dataset.id
                  })),
                  classifierType.decisionPriority.count == ClassifierDecisionSource.allCases.count,
                  Set(classifierType.decisionPriority) == Set(ClassifierDecisionSource.allCases) else {
                throw WorkspaceCatalogError.invalidClassifierType(classifierType.id)
            }
            if let llmAssist = classifierType.llmAssistConfiguration {
                do {
                    try llmAssist.validate()
                } catch {
                    throw WorkspaceCatalogError.invalidClassifierType(classifierType.id)
                }
                guard let classifierProfile = providerProfiles.first(where: {
                    $0.id == llmAssist.providerProfileID && $0.type.supportsLLMConfiguration
                }) else {
                    throw WorkspaceCatalogError.invalidClassifierType(classifierType.id)
                }
                if llmAssist.webSearchMode == .providerNative,
                   !classifierProfile.type.supportsProviderNativeWebSearch {
                    throw WorkspaceCatalogError.invalidClassifierType(classifierType.id)
                }
                if llmAssist.webSearchMode == .attached {
                    guard classifierProfile.type.supportsAttachedWebSearchTool,
                          let searchProfileID = llmAssist.webSearchProviderProfileID else {
                        throw WorkspaceCatalogError.invalidClassifierType(classifierType.id)
                    }
                    guard providerProfiles.contains(where: {
                        $0.id == searchProfileID && $0.type.supportsRawWebSearch
                    }) else {
                        throw WorkspaceCatalogError.invalidClassifierType(classifierType.id)
                    }
                }
            }
            if let draft = classifierType.llmAssistDraftConfiguration {
                do {
                    try draft.validate()
                } catch {
                    throw WorkspaceCatalogError.invalidClassifierType(classifierType.id)
                }
                guard let classifierProfile = providerProfiles.first(where: {
                    $0.id == draft.providerProfileID && $0.type.supportsLLMConfiguration
                }) else {
                    throw WorkspaceCatalogError.invalidClassifierType(classifierType.id)
                }
                if draft.webSearchMode == .providerNative,
                   !classifierProfile.type.supportsProviderNativeWebSearch {
                    throw WorkspaceCatalogError.invalidClassifierType(classifierType.id)
                }
                if draft.webSearchMode == .attached {
                    guard classifierProfile.type.supportsAttachedWebSearchTool,
                          let searchProfileID = draft.webSearchProviderProfileID,
                          providerProfiles.contains(where: {
                              $0.id == searchProfileID && $0.type.supportsRawWebSearch
                          }) else {
                        throw WorkspaceCatalogError.invalidClassifierType(classifierType.id)
                    }
                }
            }
            if let selectedLLMProviderProfileID = classifierType.selectedLLMProviderProfileID {
                guard !selectedLLMProviderProfileID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      selectedLLMProviderProfileID.count <= 128,
                      providerProfiles.contains(where: {
                          $0.id == selectedLLMProviderProfileID && $0.type.supportsLLMConfiguration
                      }) else {
                    throw WorkspaceCatalogError.invalidClassifierType(classifierType.id)
                }
            }
            // The bound model, if any, is validated in the models loop above. A
            // type contributes the local-model source only when its model is
            // trained and current (`readyLocalModel`).
            let usesLocalModel = typeUsesLocalModel(classifierType)
            let usesLLMAssist = classifierType.llmAssistConfiguration != nil
            let applicablePlatform = classifierType.applicablePlatformID.flatMap(CollectionPlatformRegistry.definition(for:))
            guard (!usesLocalModel || applicablePlatform?.supportsLocalModel == true),
                  (!usesLLMAssist || applicablePlatform?.supportsLLMAssist == true) else {
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
                  let platform = CollectionPlatformRegistry.definition(for: binding.id),
                  classifierType.treeRevision == tree.revision,
                  classifierType.datasetRevision == dataset.revision else {
                throw WorkspaceCatalogError.incompatibleActiveClassifierType(classifierTypeID)
            }
            guard (platform.supportsLocalModel ||
                   localModel(for: classifierType.id) == nil),
                  (platform.supportsLLMAssist ||
                   classifierType.llmAssistConfiguration == nil) else {
                throw WorkspaceCatalogError.incompatibleActiveClassifierType(classifierTypeID)
            }
            // The active model on the binding must be exactly the type's ready
            // bound model (nil when it has none or still needs training).
            guard binding.activeModelID == readyLocalModel(for: classifierType)?.id else {
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
        case trees, datasets, models, bindings, classifierTypes, tokenUsage, providerRequestRecords, providerProfiles, trash
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        trees = try container.decodeIfPresent([TagTreeAsset].self, forKey: .trees) ?? []
        datasets = try container.decodeIfPresent([ClassificationDataset].self, forKey: .datasets) ?? []
        models = try container.decodeIfPresent([LocalModelAsset].self, forKey: .models) ?? []
        bindings = try container.decodeIfPresent([PlatformBinding].self, forKey: .bindings) ?? []
        classifierTypes = try container.decodeIfPresent([ClassifierTypeAsset].self, forKey: .classifierTypes) ?? []
        tokenUsage = try container.decodeIfPresent([TokenUsageRecord].self, forKey: .tokenUsage) ?? []
        providerRequestRecords = try container.decodeIfPresent([ProviderRequestRecord].self, forKey: .providerRequestRecords) ?? []
        providerProfiles = try container.decodeIfPresent([APIKeyProviderProfile].self, forKey: .providerProfiles) ?? []
        trash = try container.decodeIfPresent([TrashedEntry].self, forKey: .trash) ?? []
        migrateLegacyLocalModelBindings()
    }

    // MARK: - Local model binding

    /// The local model bound to a classifier type, if one exists. A type owns at
    /// most one model, resolved by reverse lookup rather than user selection.
    public func localModel(for classifierTypeID: String) -> LocalModelAsset? {
        models.first { $0.classifierTypeID == classifierTypeID }
    }

    /// The bound model only when it is trained and usable at the type's current
    /// tree revision. A model whose tree revision has moved needs retraining and
    /// is deliberately excluded until it is trained again.
    public func readyLocalModel(for type: ClassifierTypeAsset) -> LocalModelAsset? {
        guard let model = localModel(for: type.id),
              model.isReady,
              model.embeddedNeuralModel != nil,
              model.treeID == type.treeID,
              model.treeRevision == type.treeRevision,
              model.datasetID == type.datasetID,
              type.applicablePlatformID.map({ model.effectiveTrainingPlatformIDs == [$0] }) == true else {
            return nil
        }
        return model
    }

    /// Whether a type currently contributes a local-model decision source: a
    /// ready, bound model exists for its current tree revision.
    public func typeUsesLocalModel(_ type: ClassifierTypeAsset) -> Bool {
        readyLocalModel(for: type) != nil
    }

    /// Approved decisions for a type not yet folded into its bound model at the
    /// current tree revision. A stale-revision or untrained artifact treats
    /// every eligible decision as pending. Nonzero means a training pass is due.
    public func pendingLocalModelDecisions(for type: ClassifierTypeAsset) -> [CreatorClassificationRecord] {
        guard let model = localModel(for: type.id),
              let tree = trees.first(where: { $0.id == type.treeID }),
              tree.revision == type.treeRevision,
              let dataset = datasets.first(where: { $0.id == type.datasetID }) else {
            return []
        }
        let usable = model.isReady && model.embeddedNeuralModel != nil && model.treeRevision == tree.revision
        let incorporated: Set<String> = usable ? Set(model.incorporatedDecisionIDs) : []
        return LocalModelTrainer.approvedDecisions(for: type, in: dataset, tree: tree)
            .filter { !incorporated.contains($0.id) }
    }

    /// Whether a type's bound model would change on the next training pass: it is
    /// untrained, stale for the current tree revision, or has newly approved
    /// decisions to fold.
    public func localModelNeedsTraining(for type: ClassifierTypeAsset) -> Bool {
        guard localModel(for: type.id) != nil else { return false }
        if readyLocalModel(for: type) == nil { return true }
        return !pendingLocalModelDecisions(for: type).isEmpty
    }

    /// One-time migration for state written before a local model was bound to
    /// its classifier type. The retired `ClassifierTypeAsset.localModelID`
    /// selection is consumed to set the model's owning type, its single platform
    /// snapshot, and — for an already-trained artifact — the incremental
    /// "incorporated" ledger, so an existing trained model survives without a
    /// forced full retrain. Models left without an owning type are dropped.
    private mutating func migrateLegacyLocalModelBindings() {
        for typeIndex in classifierTypes.indices {
            guard let legacyModelID = classifierTypes[typeIndex].legacyLocalModelID else { continue }
            classifierTypes[typeIndex].legacyLocalModelID = nil
            guard let modelIndex = models.firstIndex(where: { $0.id == legacyModelID }),
                  models[modelIndex].classifierTypeID.isEmpty else { continue }
            let type = classifierTypes[typeIndex]
            models[modelIndex].classifierTypeID = type.id
            if let platformID = type.applicablePlatformID {
                models[modelIndex].trainingPlatformID = platformID
                models[modelIndex].trainingPlatformIDs = [platformID]
            }
            if models[modelIndex].isReady,
               models[modelIndex].incorporatedDecisionIDs.isEmpty,
               let dataset = datasets.first(where: { $0.id == models[modelIndex].datasetID }),
               let tree = trees.first(where: { $0.id == models[modelIndex].treeID }),
               tree.revision == models[modelIndex].treeRevision {
                let incorporated = LocalModelTrainer.approvedDecisions(for: type, in: dataset, tree: tree).map(\.id)
                models[modelIndex].incorporatedDecisionIDs = Array(Set(incorporated)).sorted()
            }
        }
        models.removeAll { model in
            model.classifierTypeID.isEmpty || !classifierTypes.contains(where: { $0.id == model.classifierTypeID })
        }
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

    /// Removes one local platform binding together with the public entries and
    /// durable creator decisions that belong to that platform. Shared tree and
    /// dataset assets are deliberately retained. Any model whose source set or
    /// bound dataset changes is reset before it can be used again.
    @discardableResult
    public mutating func removePlatformBinding(_ platformID: String) -> Bool {
        guard let bindingIndex = bindings.firstIndex(where: { $0.id == platformID }) else {
            return false
        }

        let binding = bindings.remove(at: bindingIndex)
        var datasetChanged = false
        if let datasetIndex = datasets.firstIndex(where: { $0.id == binding.datasetID }) {
            let classificationCount = datasets[datasetIndex].creatorClassifications.count
            datasets[datasetIndex].collectedEntries.removeAll(where: { $0.platformID == platformID })
            datasets[datasetIndex].creatorClassifications.removeAll(where: { $0.platformID == platformID })
            datasetChanged = classificationCount != datasets[datasetIndex].creatorClassifications.count
            if datasetChanged {
                datasets[datasetIndex].revision += 1
            }
        }

        let updatedDatasetRevision = datasets.first(where: { $0.id == binding.datasetID })?.revision
        var invalidatedModelIDs = Set<String>()
        models = models.compactMap { model in
            var updated = model
            let remainingSourcePlatformIDs = model.effectiveTrainingPlatformIDs.filter { $0 != platformID }
            if remainingSourcePlatformIDs.count != model.effectiveTrainingPlatformIDs.count {
                invalidatedModelIDs.insert(model.id)
                guard !remainingSourcePlatformIDs.isEmpty else { return nil }
                updated.trainingPlatformID = remainingSourcePlatformIDs.first
                updated.trainingPlatformIDs = remainingSourcePlatformIDs
            }
            if datasetChanged, updated.datasetID == binding.datasetID, let updatedDatasetRevision {
                invalidatedModelIDs.insert(model.id)
                updated.datasetRevision = updatedDatasetRevision
            }
            if invalidatedModelIDs.contains(model.id) {
                updated.isReady = false
                updated.embeddedNeuralModel = nil
                updated.embeddedTrainingReport = nil
                updated.trainedAtMilliseconds = nil
            }
            return updated
        }

        for index in bindings.indices where invalidatedModelIDs.contains(bindings[index].activeModelID ?? "") {
            bindings[index].activeModelID = nil
            bindings[index].activeClassifierTypeID = nil
        }
        reconcileClassifierTypes()
        return true
    }

    // MARK: - Trash (soft delete)

    /// Moves a classifier type and its dependent data (its approved/pending
    /// decisions and, when no other type still uses it, its trained model) into
    /// a self-contained trash snapshot. Nothing is destroyed until the entry is
    /// permanently deleted or purged.
    @discardableResult
    public mutating func trashClassifierType(_ typeID: String) -> TrashedEntry? {
        guard let index = classifierTypes.firstIndex(where: { $0.id == typeID }) else { return nil }
        let type = classifierTypes.remove(at: index)
        var capturedDecisions: [CreatorClassificationRecord] = []
        for dIndex in datasets.indices {
            capturedDecisions.append(contentsOf: datasets[dIndex].creatorClassifications.filter { $0.classifierTypeID == typeID })
            datasets[dIndex].creatorClassifications.removeAll { $0.classifierTypeID == typeID }
        }
        // A model is owned by exactly one type, so trashing the type captures
        // and removes its bound model with it.
        var capturedModels: [LocalModelAsset] = []
        if let modelIndex = models.firstIndex(where: { $0.classifierTypeID == typeID }) {
            capturedModels.append(models.remove(at: modelIndex))
        }
        for bindingIndex in bindings.indices where bindings[bindingIndex].activeClassifierTypeID == typeID {
            bindings[bindingIndex].activeClassifierTypeID = nil
        }
        let entry = TrashedEntry(
            kind: .classifierType,
            name: type.name,
            classifierType: type,
            datasetID: type.datasetID,
            creatorClassifications: capturedDecisions,
            models: capturedModels
        )
        trash.append(entry)
        reconcileClassifierTypes()
        return entry
    }

    /// Moves a collection platform and its dependent data (its collected
    /// entries, decisions, and single-platform models) into a trash snapshot,
    /// reusing the vetted `removePlatformBinding` cascade for removal.
    @discardableResult
    public mutating func trashCollectionPlatform(_ platformID: String) -> TrashedEntry? {
        guard let binding = bindings.first(where: { $0.id == platformID }) else { return nil }
        let capturedEntries = datasets.flatMap { $0.collectedEntries.filter { $0.platformID == platformID } }
        let capturedDecisions = datasets.flatMap { $0.creatorClassifications.filter { $0.platformID == platformID } }
        let capturedModels = models.filter { Set($0.effectiveTrainingPlatformIDs) == Set([platformID]) }
        guard removePlatformBinding(platformID) else { return nil }
        let entry = TrashedEntry(
            kind: .collectionPlatform,
            name: binding.name,
            binding: binding,
            datasetID: binding.datasetID,
            creatorClassifications: capturedDecisions,
            collectedEntries: capturedEntries,
            models: capturedModels
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

    /// Re-inserts a trashed entry and every dependent record it captured. A
    /// dependent model may need retraining if the dataset revision moved while
    /// the entry sat in trash; the data itself is fully restored.
    @discardableResult
    public mutating func restoreTrashedEntry(_ id: String) -> Bool {
        guard let index = trash.firstIndex(where: { $0.id == id }) else { return false }
        let entry = trash.remove(at: index)
        switch entry.kind {
        case .classifierType:
            guard let type = entry.classifierType, !classifierTypes.contains(where: { $0.id == type.id }) else { break }
            classifierTypes.append(type)
            if let datasetID = entry.datasetID, let dIndex = datasets.firstIndex(where: { $0.id == datasetID }) {
                datasets[dIndex].creatorClassifications.append(contentsOf: entry.creatorClassifications)
            }
            models.append(contentsOf: entry.models.filter { candidate in !models.contains(where: { $0.id == candidate.id }) })
        case .collectionPlatform:
            guard let binding = entry.binding else { break }
            if !bindings.contains(where: { $0.id == binding.id }) { bindings.append(binding) }
            if let datasetID = entry.datasetID, let dIndex = datasets.firstIndex(where: { $0.id == datasetID }) {
                datasets[dIndex].collectedEntries.append(contentsOf: entry.collectedEntries)
                datasets[dIndex].creatorClassifications.append(contentsOf: entry.creatorClassifications)
            }
            models.append(contentsOf: entry.models.filter { candidate in !models.contains(where: { $0.id == candidate.id }) })
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

    /// Tree/data revisions are immutable model boundaries. Edits therefore
    /// retain the classifier type but move it to the new selected revision and
    /// remove only dependencies that are no longer compatible. This keeps the
    /// user-visible brain editable while never letting an old model decide for
    /// a changed tree or dataset.
    public mutating func reconcileClassifierTypes() {
        for index in trees.indices {
            TagColorAssignment.reconcileColors(in: &trees[index])
        }
        providerProfiles = providerProfiles.filter { (try? $0.validate()) != nil }
        models = models.compactMap { model in
            var reconciled = model
            let eligiblePlatformIDs = model.effectiveTrainingPlatformIDs.filter {
                CollectionPlatformRegistry.definition(for: $0)?.supportsLocalModel == true
            }
            guard !eligiblePlatformIDs.isEmpty else { return nil }
            if eligiblePlatformIDs != model.effectiveTrainingPlatformIDs {
                reconciled.trainingPlatformID = eligiblePlatformIDs.first
                reconciled.trainingPlatformIDs = eligiblePlatformIDs
                reconciled.isReady = false
                reconciled.embeddedNeuralModel = nil
                reconciled.embeddedTrainingReport = nil
                reconciled.trainedAtMilliseconds = nil
            }
            return reconciled
        }
        classifierTypes = classifierTypes.compactMap { classifierType in
            guard let tree = trees.first(where: { $0.id == classifierType.treeID }),
                  let dataset = datasets.first(where: { $0.id == classifierType.datasetID }) else {
                return nil
            }
            var reconciled = classifierType
            reconciled.treeRevision = tree.revision
            reconciled.datasetRevision = dataset.revision
            let applicableBinding = reconciled.applicablePlatformID.flatMap { platformID in
                bindings.first(where: { binding in
                    binding.id == platformID && binding.treeID == tree.id && binding.datasetID == dataset.id
                })
            }
            reconciled.applicablePlatformID = applicableBinding?.id
            let applicablePlatform = reconciled.applicablePlatformID.flatMap(CollectionPlatformRegistry.definition(for:))
            let supportsLLMAssist = applicablePlatform?.supportsLLMAssist == true
            if let llmAssist = reconciled.llmAssistConfiguration,
               supportsLLMAssist,
               providerProfiles.contains(where: { $0.id == llmAssist.providerProfileID && $0.type.supportsLLMConfiguration }),
               (try? llmAssist.validate()) != nil {
                var retainedLLMAssist = llmAssist
                let classifierProfile = providerProfiles.first(where: {
                    $0.id == retainedLLMAssist.providerProfileID && $0.type.supportsLLMConfiguration
                })
                let nativeModeInvalid = retainedLLMAssist.webSearchMode == .providerNative &&
                    classifierProfile?.type.supportsProviderNativeWebSearch != true
                let attachedModeInvalid = retainedLLMAssist.webSearchMode == .attached && (
                    classifierProfile?.type.supportsAttachedWebSearchTool != true ||
                    retainedLLMAssist.webSearchProviderProfileID == nil ||
                    !providerProfiles.contains(where: {
                        $0.id == retainedLLMAssist.webSearchProviderProfileID && $0.type.supportsRawWebSearch
                    })
                )
                if nativeModeInvalid || attachedModeInvalid {
                    retainedLLMAssist.webSearchMode = .off
                    retainedLLMAssist.webSearchProviderProfileID = nil
                    retainedLLMAssist.isActive = false
                }
                reconciled.llmAssistConfiguration = retainedLLMAssist
            } else {
                reconciled.llmAssistConfiguration = nil
            }
            if let draft = reconciled.llmAssistDraftConfiguration,
               supportsLLMAssist,
               providerProfiles.contains(where: { $0.id == draft.providerProfileID && $0.type.supportsLLMConfiguration }),
               (try? draft.validate()) != nil {
                var retainedDraft = draft
                let classifierProfile = providerProfiles.first(where: {
                    $0.id == retainedDraft.providerProfileID && $0.type.supportsLLMConfiguration
                })
                let nativeModeInvalid = retainedDraft.webSearchMode == .providerNative &&
                    classifierProfile?.type.supportsProviderNativeWebSearch != true
                let attachedModeInvalid = retainedDraft.webSearchMode == .attached && (
                    classifierProfile?.type.supportsAttachedWebSearchTool != true ||
                    retainedDraft.webSearchProviderProfileID == nil ||
                    !providerProfiles.contains(where: {
                        $0.id == retainedDraft.webSearchProviderProfileID && $0.type.supportsRawWebSearch
                    })
                )
                if nativeModeInvalid || attachedModeInvalid {
                    retainedDraft.webSearchMode = .off
                    retainedDraft.webSearchProviderProfileID = nil
                }
                reconciled.llmAssistDraftConfiguration = retainedDraft
            } else {
                reconciled.llmAssistDraftConfiguration = nil
            }
            if let selectedProviderID = reconciled.selectedLLMProviderProfileID,
               supportsLLMAssist,
               providerProfiles.contains(where: { $0.id == selectedProviderID && $0.type.supportsLLMConfiguration }) {
                reconciled.selectedLLMProviderProfileID = selectedProviderID
            } else {
                reconciled.selectedLLMProviderProfileID = reconciled.llmAssistConfiguration?.providerProfileID
            }
            // A local model is bound to its type by reverse lookup; there is no
            // per-type model selection to reconcile here. Models bound to a type
            // whose platform stopped supporting local models are pruned below.
            let retainedPriority = reconciled.decisionPriority.reduce(into: [ClassifierDecisionSource]()) { result, source in
                if !result.contains(source) { result.append(source) }
            }
            reconciled.decisionPriority = retainedPriority + ClassifierDecisionSource.allCases.filter { !retainedPriority.contains($0) }
            reconciled.updatedAtMilliseconds = WorkspaceCatalog.now()
            return reconciled
        }
        // Drop models orphaned by a removed type or a platform that no longer
        // supports a local model, then clear bindings pointing at a dropped model.
        models.removeAll { model in
            guard let owningType = classifierTypes.first(where: { $0.id == model.classifierTypeID }) else { return true }
            let platform = owningType.applicablePlatformID.flatMap(CollectionPlatformRegistry.definition(for:))
            return platform?.supportsLocalModel != true
        }
        for index in bindings.indices where bindings[index].activeModelID.map({ id in !models.contains(where: { $0.id == id }) }) == true {
            bindings[index].activeModelID = nil
        }
        for index in bindings.indices {
            guard let classifierTypeID = bindings[index].activeClassifierTypeID else { continue }
            guard let classifierType = classifierTypes.first(where: { $0.id == classifierTypeID }),
                  let tree = trees.first(where: { $0.id == bindings[index].treeID }),
                  let dataset = datasets.first(where: { $0.id == bindings[index].datasetID }),
                  let platform = CollectionPlatformRegistry.definition(for: bindings[index].id),
                  classifierType.treeID == tree.id,
                  classifierType.treeRevision == tree.revision,
                  classifierType.datasetID == dataset.id,
                  classifierType.datasetRevision == dataset.revision,
                  classifierType.applicablePlatformID == bindings[index].id else {
                bindings[index].activeClassifierTypeID = nil
                bindings[index].activeModelID = nil
                continue
            }
            if (!platform.supportsLocalModel &&
                localModel(for: classifierType.id) != nil) ||
                (!platform.supportsLLMAssist &&
                classifierType.llmAssistConfiguration != nil) {
                bindings[index].activeClassifierTypeID = nil
                bindings[index].activeModelID = nil
                continue
            }
            // The active model is the type's ready bound model, if it has one.
            // An untrained or stale-revision model leaves the binding without an
            // active model (the type still classifies via its other sources).
            bindings[index].activeModelID = readyLocalModel(for: classifierType)?.id
        }
    }
}
