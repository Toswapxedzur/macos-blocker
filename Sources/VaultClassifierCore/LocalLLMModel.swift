import Foundation

// Data model for the local-LLM-centered, per-video, grounded-search rework
// (see REWORK-local-model-centered.md). These types are ADDITIVE — they live
// alongside the existing creator-classification model so the build stays green
// while the new pipeline is assembled. The old primary path is removed only in
// the cleanup phase, once the new pipeline drives pills.

// MARK: - Scored tag (discrete 1–5 confidence)

/// A predicted tag with a coarse, discrete confidence. The scale is intentionally
/// small (1–5) because a small on-device LLM's finer confidence is poorly
/// calibrated; the value is derived from constrained-decode logprobs where the
/// runtime exposes them, otherwise self-reported. Always clamped into range.
public struct ScoredTag: Codable, Equatable, Sendable {
    public static let minConfidence = 1
    public static let maxConfidence = 5

    public var tagID: String
    public var confidence: Int

    public init(tagID: String, confidence: Int) {
        self.tagID = tagID
        self.confidence = Self.clamp(confidence)
    }

    public static func clamp(_ value: Int) -> Int {
        min(maxConfidence, max(minConfidence, value))
    }

    private enum CodingKeys: String, CodingKey { case tagID, confidence }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tagID = try container.decode(String.self, forKey: .tagID)
        confidence = Self.clamp(try container.decodeIfPresent(Int.self, forKey: .confidence) ?? Self.minConfidence)
    }
}

// MARK: - Per-video classification (the primary label + decision cache)

/// How a video's tags were produced. Only `humanCorrected` is authoritative for
/// preference learning; `model` and `modelKnowledge` are the LLM's own calls.
public enum VideoClassificationSource: String, Codable, Sendable, CaseIterable {
    case model            // local LLM over the video's own evidence only
    case modelKnowledge   // local LLM + injected knowledge-map context
    case humanCorrected   // user confirmed/overrode
}

/// One video classified on its own evidence. This — not a creator decision — is
/// the primary label store and the per-video/​creator decision cache. A creator's
/// tags are *derived* from these (see `CreatorTagHistogram`); there is no creator
/// classification record in the new model.
public struct VideoClassification: Codable, Equatable, Sendable, Identifiable {
    public static let maximumTags = 32
    public static let maximumUnknownTerms = 16

    public var id: String
    public var classifierTypeID: String
    public var platformID: String
    public var entryID: String
    public var creatorID: String
    public var treeID: String
    public var treeRevision: Int
    /// Per-tag scored result (1–5 confidence).
    public var tags: [ScoredTag]
    /// Salient entities/creators the model could not confidently place — the
    /// research queue's input (a creator name may appear here too).
    public var unknownTerms: [String]
    /// Knowledge-map keys injected into the prompt that produced this result.
    public var knowledgeRefs: [String]
    public var source: VideoClassificationSource
    /// Model id + prompt/schema version, so stale results can be recomputed.
    public var modelVersion: String
    public var createdAtMilliseconds: Int64
    public var updatedAtMilliseconds: Int64

    public init(
        id: String = UUID().uuidString,
        classifierTypeID: String,
        platformID: String,
        entryID: String,
        creatorID: String,
        treeID: String,
        treeRevision: Int,
        tags: [ScoredTag],
        unknownTerms: [String] = [],
        knowledgeRefs: [String] = [],
        source: VideoClassificationSource,
        modelVersion: String,
        createdAtMilliseconds: Int64 = WorkspaceCatalog.now(),
        updatedAtMilliseconds: Int64 = WorkspaceCatalog.now()
    ) {
        self.id = id
        self.classifierTypeID = classifierTypeID
        self.platformID = platformID
        self.entryID = entryID
        self.creatorID = creatorID
        self.treeID = treeID
        self.treeRevision = treeRevision
        self.tags = Array(tags.prefix(Self.maximumTags))
        self.unknownTerms = Array(unknownTerms.prefix(Self.maximumUnknownTerms))
        self.knowledgeRefs = knowledgeRefs
        self.source = source
        self.modelVersion = modelVersion
        self.createdAtMilliseconds = createdAtMilliseconds
        self.updatedAtMilliseconds = updatedAtMilliseconds
    }

    /// A classification is current per classifier type + platform + video.
    public var identityKey: String { "\(classifierTypeID)\u{1F}\(platformID)\u{1F}\(entryID)" }

    private enum CodingKeys: String, CodingKey {
        case id, classifierTypeID, platformID, entryID, creatorID, treeID,
             treeRevision, tags, unknownTerms, knowledgeRefs, source,
             modelVersion, createdAtMilliseconds, updatedAtMilliseconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        classifierTypeID = try container.decode(String.self, forKey: .classifierTypeID)
        platformID = try container.decode(String.self, forKey: .platformID)
        entryID = try container.decode(String.self, forKey: .entryID)
        creatorID = try container.decode(String.self, forKey: .creatorID)
        treeID = try container.decode(String.self, forKey: .treeID)
        treeRevision = try container.decode(Int.self, forKey: .treeRevision)
        tags = Array((try container.decodeIfPresent([ScoredTag].self, forKey: .tags) ?? []).prefix(Self.maximumTags))
        unknownTerms = Array((try container.decodeIfPresent([String].self, forKey: .unknownTerms) ?? []).prefix(Self.maximumUnknownTerms))
        knowledgeRefs = try container.decodeIfPresent([String].self, forKey: .knowledgeRefs) ?? []
        source = try container.decodeIfPresent(VideoClassificationSource.self, forKey: .source) ?? .model
        modelVersion = try container.decodeIfPresent(String.self, forKey: .modelVersion) ?? ""
        createdAtMilliseconds = try container.decode(Int64.self, forKey: .createdAtMilliseconds)
        updatedAtMilliseconds = try container.decode(Int64.self, forKey: .updatedAtMilliseconds)
    }
}

// MARK: - Knowledge map (RAG store for grounded research results)

public enum KnowledgeEntryKind: String, Codable, Sendable, CaseIterable {
    case term      // a special noun / entity, e.g. "HermitCraft"
    case creator   // a creator's grounded identity
}

/// One grounded fact learned by research, injected at classify time. Knowledge —
/// not tags — is what research produces (the model still assigns tags). Keyed so
/// a term/creator is researched once and reused: `term:<lowercased>` or
/// `creator:<creatorID>`.
public struct KnowledgeEntry: Codable, Equatable, Sendable, Identifiable {
    public static let maximumMeaningLength = 2_000
    public static let maximumContextTagHints = 16
    public static let maximumSourceURLs = 8

    public var id: String
    public var kind: KnowledgeEntryKind
    /// The raw subject (term text, or creator id/display) for prompting.
    public var subject: String
    /// The grounded description injected into the prompt.
    public var meaning: String
    /// Non-authoritative tag hints (the model may ignore them).
    public var contextTagHints: [String]
    public var sourceURLs: [String]
    public var createdAtMilliseconds: Int64
    public var updatedAtMilliseconds: Int64

    public init(
        kind: KnowledgeEntryKind,
        subject: String,
        meaning: String,
        contextTagHints: [String] = [],
        sourceURLs: [String] = [],
        createdAtMilliseconds: Int64 = WorkspaceCatalog.now(),
        updatedAtMilliseconds: Int64 = WorkspaceCatalog.now()
    ) {
        self.id = Self.key(kind: kind, subject: subject)
        self.kind = kind
        self.subject = subject
        self.meaning = String(meaning.prefix(Self.maximumMeaningLength))
        self.contextTagHints = Array(contextTagHints.prefix(Self.maximumContextTagHints))
        self.sourceURLs = Array(sourceURLs.prefix(Self.maximumSourceURLs))
        self.createdAtMilliseconds = createdAtMilliseconds
        self.updatedAtMilliseconds = updatedAtMilliseconds
    }

    /// Stable key for dedup + lookup. Terms normalize to lowercase; creators use
    /// their id verbatim (already platform-scoped).
    public static func key(kind: KnowledgeEntryKind, subject: String) -> String {
        switch kind {
        case .term:
            return "term:\(subject.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))"
        case .creator:
            return "creator:\(subject.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
    }

    /// A term entry matches a title when its subject appears in the title
    /// (case-insensitive). Creator entries are matched by key, not by title.
    public func matches(title: String) -> Bool {
        guard kind == .term else { return false }
        let needle = subject.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return false }
        return title.lowercased().contains(needle)
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, subject, meaning, contextTagHints, sourceURLs,
             createdAtMilliseconds, updatedAtMilliseconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(KnowledgeEntryKind.self, forKey: .kind)
        subject = try container.decode(String.self, forKey: .subject)
        meaning = String((try container.decodeIfPresent(String.self, forKey: .meaning) ?? "").prefix(Self.maximumMeaningLength))
        contextTagHints = Array((try container.decodeIfPresent([String].self, forKey: .contextTagHints) ?? []).prefix(Self.maximumContextTagHints))
        sourceURLs = Array((try container.decodeIfPresent([String].self, forKey: .sourceURLs) ?? []).prefix(Self.maximumSourceURLs))
        createdAtMilliseconds = try container.decode(Int64.self, forKey: .createdAtMilliseconds)
        updatedAtMilliseconds = try container.decode(Int64.self, forKey: .updatedAtMilliseconds)
    }
}

// MARK: - Correction example (few-shot preference signal)

/// A user correction: the ground-truth tags for a specific video. These feed the
/// distilled house-rules (in the cached prefix) and, if needed later, few-shot
/// retrieval. They are the only authoritative preference signal.
public struct CorrectionExample: Codable, Equatable, Sendable, Identifiable {
    public static let maximumTagIDs = 32
    public static let maximumNoteLength = 500

    public var id: String
    public var classifierTypeID: String
    public var platformID: String
    public var entryID: String
    public var creatorID: String
    public var title: String
    public var correctTagIDs: [String]
    public var note: String?
    public var createdAtMilliseconds: Int64

    public init(
        id: String = UUID().uuidString,
        classifierTypeID: String,
        platformID: String,
        entryID: String,
        creatorID: String,
        title: String,
        correctTagIDs: [String],
        note: String? = nil,
        createdAtMilliseconds: Int64 = WorkspaceCatalog.now()
    ) {
        self.id = id
        self.classifierTypeID = classifierTypeID
        self.platformID = platformID
        self.entryID = entryID
        self.creatorID = creatorID
        self.title = title
        self.correctTagIDs = Array(Array(Set(correctTagIDs)).sorted().prefix(Self.maximumTagIDs))
        self.note = note.map { String($0.prefix(Self.maximumNoteLength)) }
        self.createdAtMilliseconds = createdAtMilliseconds
    }

    private enum CodingKeys: String, CodingKey {
        case id, classifierTypeID, platformID, entryID, creatorID, title,
             correctTagIDs, note, createdAtMilliseconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        classifierTypeID = try container.decode(String.self, forKey: .classifierTypeID)
        platformID = try container.decode(String.self, forKey: .platformID)
        entryID = try container.decodeIfPresent(String.self, forKey: .entryID) ?? ""
        creatorID = try container.decodeIfPresent(String.self, forKey: .creatorID) ?? ""
        title = try container.decode(String.self, forKey: .title)
        correctTagIDs = Array(Array(Set(try container.decodeIfPresent([String].self, forKey: .correctTagIDs) ?? [])).sorted().prefix(Self.maximumTagIDs))
        note = (try container.decodeIfPresent(String.self, forKey: .note)).map { String($0.prefix(Self.maximumNoteLength)) }
        createdAtMilliseconds = try container.decode(Int64.self, forKey: .createdAtMilliseconds)
    }
}

// MARK: - Derived creator tag histogram (view-history prior)

/// Running per-tag stats for one creator, aggregated from that creator's
/// `VideoClassification` rows (ALL of them — the mean naturally down-weights
/// weakly-tagged videos). This is the *derived* creator prior; there is no
/// creator classification. It is scoped to the user's view history and must be
/// presented to the model with that caveat.
public struct CreatorTagStat: Codable, Equatable, Sendable {
    public var count: Int
    public var confidenceSum: Int

    public init(count: Int = 0, confidenceSum: Int = 0) {
        self.count = count
        self.confidenceSum = confidenceSum
    }

    public var averageConfidence: Double {
        count > 0 ? Double(confidenceSum) / Double(count) : 0
    }
}

public struct CreatorTagHistogram: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var classifierTypeID: String
    public var platformID: String
    public var creatorID: String
    public var stats: [String: CreatorTagStat]
    public var videoCount: Int
    public var updatedAtMilliseconds: Int64

    public init(
        classifierTypeID: String,
        platformID: String,
        creatorID: String,
        stats: [String: CreatorTagStat] = [:],
        videoCount: Int = 0,
        updatedAtMilliseconds: Int64 = WorkspaceCatalog.now()
    ) {
        self.id = Self.key(classifierTypeID: classifierTypeID, platformID: platformID, creatorID: creatorID)
        self.classifierTypeID = classifierTypeID
        self.platformID = platformID
        self.creatorID = creatorID
        self.stats = stats
        self.videoCount = videoCount
        self.updatedAtMilliseconds = updatedAtMilliseconds
    }

    public static func key(classifierTypeID: String, platformID: String, creatorID: String) -> String {
        "\(classifierTypeID)\u{1F}\(platformID)\u{1F}\(creatorID)"
    }

    /// Fold one video's scored tags into the histogram (count-all).
    public mutating func record(_ tags: [ScoredTag], at milliseconds: Int64 = WorkspaceCatalog.now()) {
        for tag in tags {
            var stat = stats[tag.tagID] ?? CreatorTagStat()
            stat.count += 1
            stat.confidenceSum += tag.confidence
            stats[tag.tagID] = stat
        }
        videoCount += 1
        updatedAtMilliseconds = milliseconds
    }

    /// Tags with their averaged 1–5 confidence, strongest first — the prior fed
    /// to the model (with the "partial view-history sample" caveat).
    public func averagedTags(minimumAverage: Double = 0) -> [(tagID: String, averageConfidence: Double)] {
        stats
            .compactMap { key, stat -> (String, Double)? in
                let avg = stat.averageConfidence
                return avg >= minimumAverage ? (key, avg) : nil
            }
            .sorted { lhs, rhs in
                lhs.1 == rhs.1 ? lhs.0 < rhs.0 : lhs.1 > rhs.1
            }
            .map { (tagID: $0.0, averageConfidence: $0.1) }
    }

    private enum CodingKeys: String, CodingKey {
        case id, classifierTypeID, platformID, creatorID, stats, videoCount, updatedAtMilliseconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        classifierTypeID = try container.decode(String.self, forKey: .classifierTypeID)
        platformID = try container.decode(String.self, forKey: .platformID)
        creatorID = try container.decode(String.self, forKey: .creatorID)
        stats = try container.decodeIfPresent([String: CreatorTagStat].self, forKey: .stats) ?? [:]
        videoCount = try container.decodeIfPresent(Int.self, forKey: .videoCount) ?? 0
        updatedAtMilliseconds = try container.decode(Int64.self, forKey: .updatedAtMilliseconds)
    }
}

// MARK: - Catalog integration (additive)

public extension WorkspaceCatalog {
    static let maximumRetainedVideoClassifications = 5_000
    static let maximumKnowledgeEntries = 20_000
    static let maximumCorrectionExamples = 5_000

    /// The current per-video classification for a type + platform + video.
    func videoClassification(classifierTypeID: String, platformID: String, entryID: String) -> VideoClassification? {
        let key = "\(classifierTypeID)\u{1F}\(platformID)\u{1F}\(entryID)"
        return videoClassifications.first { $0.identityKey == key }
    }

    /// Insert or replace a per-video classification (current per type/platform/video),
    /// then refresh the affected creator's derived histogram. Bounded by trimming the
    /// oldest when over the retention cap.
    mutating func upsertVideoClassification(_ classification: VideoClassification) {
        if let index = videoClassifications.firstIndex(where: { $0.identityKey == classification.identityKey }) {
            videoClassifications[index] = classification
        } else {
            videoClassifications.append(classification)
            if videoClassifications.count > Self.maximumRetainedVideoClassifications {
                videoClassifications.sort { $0.updatedAtMilliseconds > $1.updatedAtMilliseconds }
                videoClassifications = Array(videoClassifications.prefix(Self.maximumRetainedVideoClassifications))
            }
        }
        rebuildCreatorHistogram(
            classifierTypeID: classification.classifierTypeID,
            platformID: classification.platformID,
            creatorID: classification.creatorID
        )
    }

    /// The derived (view-history) creator prior, if any videos have been classified.
    func creatorHistogram(classifierTypeID: String, platformID: String, creatorID: String) -> CreatorTagHistogram? {
        let key = CreatorTagHistogram.key(classifierTypeID: classifierTypeID, platformID: platformID, creatorID: creatorID)
        return creatorHistograms.first { $0.id == key }
    }

    /// Recompute one creator's histogram from its `VideoClassification` rows
    /// (count-all: every classified video contributes; the mean down-weights weak
    /// tags). O(videos for that creator); cheap given the retention cap.
    mutating func rebuildCreatorHistogram(classifierTypeID: String, platformID: String, creatorID: String) {
        var histogram = CreatorTagHistogram(classifierTypeID: classifierTypeID, platformID: platformID, creatorID: creatorID)
        for classification in videoClassifications
        where classification.classifierTypeID == classifierTypeID
            && classification.platformID == platformID
            && classification.creatorID == creatorID {
            histogram.record(classification.tags, at: classification.updatedAtMilliseconds)
        }
        if let index = creatorHistograms.firstIndex(where: { $0.id == histogram.id }) {
            if histogram.videoCount == 0 { creatorHistograms.remove(at: index) }
            else { creatorHistograms[index] = histogram }
        } else if histogram.videoCount > 0 {
            creatorHistograms.append(histogram)
        }
    }

    /// Rebuild every creator histogram from scratch (e.g. after a bulk import).
    mutating func rebuildAllCreatorHistograms() {
        var byKey: [String: CreatorTagHistogram] = [:]
        for classification in videoClassifications {
            let key = CreatorTagHistogram.key(
                classifierTypeID: classification.classifierTypeID,
                platformID: classification.platformID,
                creatorID: classification.creatorID
            )
            var histogram = byKey[key] ?? CreatorTagHistogram(
                classifierTypeID: classification.classifierTypeID,
                platformID: classification.platformID,
                creatorID: classification.creatorID
            )
            histogram.record(classification.tags, at: classification.updatedAtMilliseconds)
            byKey[key] = histogram
        }
        creatorHistograms = Array(byKey.values)
    }

    /// Knowledge entries relevant to one video: the creator's own entry (by key)
    /// plus any term entries whose subject appears in the title. This is the
    /// classify-time RAG lookup — only matched entries are injected, so a large
    /// map does not affect per-video cost.
    func matchedKnowledge(title: String, creatorID: String) -> [KnowledgeEntry] {
        var matched: [KnowledgeEntry] = []
        let creatorKey = KnowledgeEntry.key(kind: .creator, subject: creatorID)
        if let creatorEntry = knowledgeEntries.first(where: { $0.id == creatorKey }) {
            matched.append(creatorEntry)
        }
        for entry in knowledgeEntries where entry.kind == .term && entry.matches(title: title) {
            matched.append(entry)
        }
        return matched
    }

    /// Insert or update a knowledge entry (dedup by key). Bounded by trimming the
    /// oldest when over the cap.
    mutating func upsertKnowledgeEntry(_ entry: KnowledgeEntry) {
        if let index = knowledgeEntries.firstIndex(where: { $0.id == entry.id }) {
            knowledgeEntries[index] = entry
        } else {
            knowledgeEntries.append(entry)
            if knowledgeEntries.count > Self.maximumKnowledgeEntries {
                knowledgeEntries.sort { $0.updatedAtMilliseconds > $1.updatedAtMilliseconds }
                knowledgeEntries = Array(knowledgeEntries.prefix(Self.maximumKnowledgeEntries))
            }
        }
    }

    /// Light structural validation for the new stores. Empty stores pass trivially,
    /// so existing/greenfield states are unaffected.
    func validateLocalLLMStores() throws {
        guard videoClassifications.count <= Self.maximumRetainedVideoClassifications else {
            throw WorkspaceCatalogError.invalidCollectedEntry("videoClassifications")
        }
        guard knowledgeEntries.count <= Self.maximumKnowledgeEntries,
              correctionExamples.count <= Self.maximumCorrectionExamples else {
            throw WorkspaceCatalogError.invalidCollectedEntry("localLLMStores")
        }
        try llmUniqueIDs(videoClassifications.map(\.id))
        try llmUniqueIDs(knowledgeEntries.map(\.id))
        try llmUniqueIDs(correctionExamples.map(\.id))
        try llmUniqueIDs(creatorHistograms.map(\.id))
        for classification in videoClassifications {
            guard !classification.id.isEmpty, !classification.entryID.isEmpty,
                  !classification.classifierTypeID.isEmpty, !classification.platformID.isEmpty,
                  classification.tags.count <= VideoClassification.maximumTags,
                  classification.tags.allSatisfy({ (ScoredTag.minConfidence...ScoredTag.maxConfidence).contains($0.confidence) }) else {
                throw WorkspaceCatalogError.invalidCollectedEntry(classification.id)
            }
        }
    }
}

/// Uniqueness check local to the local-LLM stores (the catalog's own `unique`
/// helper is file-private to WorkspaceAssets.swift).
private func llmUniqueIDs(_ identifiers: [String]) throws {
    if Set(identifiers).count != identifiers.count {
        throw WorkspaceCatalogError.invalidCollectedEntry("duplicate-local-llm-id")
    }
}
