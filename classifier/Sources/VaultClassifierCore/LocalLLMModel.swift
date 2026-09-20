import Foundation

// Data model for the local-LLM-centered, per-video pipeline.

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

    public var id: String
    public var classifierTypeID: String
    public var platformID: String
    public var entryID: String
    public var creatorID: String
    public var treeID: String
    public var treeRevision: Int
    /// Per-tag scored result (1–5 confidence).
    public var tags: [ScoredTag]
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
             treeRevision, tags, knowledgeRefs, source,
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
        // (Legacy `unknownTerms` key is intentionally ignored on decode — dropped in Phase 1.)
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

    /// Minimum specificity for a TERM subject to be matched against titles (and
    /// to be stored at all). Research term extraction can emit junk — single
    /// letters ("e", "T"), abbreviations ("CE", "ml"), bare numbers, corrupt
    /// text — and a raw substring match on those hits essentially every title,
    /// injecting the whole "meaning" into every prompt (measured live:
    /// ~570 tokens per video, i.e. the entire tagging slowdown). CJK has no word
    /// boundaries, so two characters suffice there; other scripts need three
    /// characters including a real word of three or more letters.
    public static func isSpecificTermSubject(_ subject: String) -> Bool {
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.unicodeScalars.contains(where: { $0.value == 0xFFFD }) else { return false }
        if containsCJK(trimmed) {
            return trimmed.unicodeScalars.filter(isCJK).count >= 2
        }
        guard trimmed.count >= 3 else { return false }
        var run = 0
        for scalar in trimmed.unicodeScalars {
            if CharacterSet.letters.contains(scalar) {
                run += 1
                if run >= 3 { return true }
            } else {
                run = 0
            }
        }
        return false
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xAC00...0xD7AF: return true
        default: return false
        }
    }

    private static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: isCJK)
    }

    /// A term entry matches a title when its subject appears in the title — as a
    /// whole word for scripts with word boundaries, as a substring for CJK —
    /// and only for specific subjects (see `isSpecificTermSubject`). Creator
    /// entries are matched by key, not by title.
    public func matches(title: String) -> Bool {
        guard kind == .term, Self.isSpecificTermSubject(subject) else { return false }
        let needle = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.containsCJK(needle) {
            return title.lowercased().contains(needle.lowercased())
        }
        let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: needle) + "(?![\\p{L}\\p{N}])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return false }
        return regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)) != nil
    }

    /// A TTL of zero means knowledge never expires. Expired entries stay in
    /// the durable map but are excluded from prompts and research deduping.
    ///
    /// Creator descriptions are keyed forever: a creator's grounded identity is
    /// stable, so it is never expired by TTL regardless of the setting.
    public func isActive(
        ttlDays: Int,
        nowMilliseconds: Int64 = WorkspaceCatalog.now()
    ) -> Bool {
        guard kind == .term else { return true }
        let clampedDays = min(ResearchSettings.maximumKnowledgeTTLDays, max(0, ttlDays))
        guard clampedDays > 0 else { return true }
        let lifetime = Int64(clampedDays) * 24 * 60 * 60 * 1_000
        return updatedAtMilliseconds >= nowMilliseconds - lifetime
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
    /// Sum of confidence² — lets us report a stdev without storing every value.
    /// Absent on histograms built before this field (defaults 0); stdev then
    /// reads 0 until the creator's next video re-accumulates it.
    public var confidenceSumOfSquares: Int

    public init(count: Int = 0, confidenceSum: Int = 0, confidenceSumOfSquares: Int = 0) {
        self.count = count
        self.confidenceSum = confidenceSum
        self.confidenceSumOfSquares = confidenceSumOfSquares
    }

    private enum CodingKeys: String, CodingKey { case count, confidenceSum, confidenceSumOfSquares }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        count = try c.decode(Int.self, forKey: .count)
        confidenceSum = try c.decode(Int.self, forKey: .confidenceSum)
        confidenceSumOfSquares = try c.decodeIfPresent(Int.self, forKey: .confidenceSumOfSquares) ?? 0
    }

    public var averageConfidence: Double {
        count > 0 ? Double(confidenceSum) / Double(count) : 0
    }

    /// Population stdev of the 1–5 confidences (0 when count < 2 or on legacy
    /// data lacking the sum-of-squares); variance clamped non-negative.
    public var confidenceStdev: Double {
        guard count > 1, confidenceSumOfSquares > 0 else { return 0 }
        let mean = averageConfidence
        let variance = Double(confidenceSumOfSquares) / Double(count) - mean * mean
        return variance > 0 ? variance.squareRoot() : 0
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
            stat.confidenceSumOfSquares += tag.confidence * tag.confidence
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

// MARK: - Author research accumulator (RESEARCH-REDESIGN §8)

/// One windowed per-video urgency sample for a creator.
public struct CreatorUrgencySample: Codable, Equatable, Sendable {
    public var urgency: Int
    public var atMilliseconds: Int64
    public init(urgency: Int, atMilliseconds: Int64) {
        self.urgency = min(5, max(1, urgency))
        self.atMilliseconds = atMilliseconds
    }
}

/// Accumulates a creator's recent derived-urgency samples (per classifier type)
/// so author research can fire when they are consistently hard to classify.
public struct CreatorResearchAccumulator: Codable, Equatable, Sendable, Identifiable {
    /// `classifierTypeID\u{1F}creatorID`.
    public var id: String
    public var samples: [CreatorUrgencySample]
    public init(id: String, samples: [CreatorUrgencySample] = []) {
        self.id = id
        self.samples = samples
    }
    public static func key(classifierTypeID: String, creatorID: String) -> String {
        "\(classifierTypeID)\u{1F}\(creatorID)"
    }
}

// MARK: - Catalog integration (additive)

public extension WorkspaceCatalog {
    static let maximumRetainedVideoClassifications = 5_000
    static let maximumKnowledgeEntries = 20_000
    static let maximumResearchAttempts = 20_000
    static let maximumCorrectionExamples = 5_000
    static let maximumMatchedKnowledgeEntries = 8
    static let maximumCreatorAccumulators = 20_000
    static let maximumCreatorUrgencySamples = 512

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

    /// Term knowledge relevant to one video: term entries whose subject appears
    /// in the title. This is the classify-time RAG lookup for the primary
    /// (content-based) decode — creator descriptions are looked up separately
    /// via `creatorKnowledgeEntry(for:)` and used only as a low-confidence
    /// fallback, so they are deliberately not returned here.
    func matchedKnowledge(
        title: String,
        creatorID: String,
        limit requestedLimit: Int = Self.maximumMatchedKnowledgeEntries,
        ttlDays: Int = 0,
        nowMilliseconds: Int64 = WorkspaceCatalog.now()
    ) -> [KnowledgeEntry] {
        let limit = min(ResearchSettings.maximumKnowledgePerVideo, max(1, requestedLimit))
        let terms = knowledgeEntries
            .filter {
                $0.kind == .term
                    && $0.isActive(ttlDays: ttlDays, nowMilliseconds: nowMilliseconds)
                    && $0.matches(title: title)
            }
            .sorted { lhs, rhs in
                if lhs.subject.count != rhs.subject.count { return lhs.subject.count > rhs.subject.count }
                if lhs.updatedAtMilliseconds != rhs.updatedAtMilliseconds {
                    return lhs.updatedAtMilliseconds > rhs.updatedAtMilliseconds
                }
                return lhs.id < rhs.id
            }
        return Array(terms.prefix(limit))
    }

    /// The stored, permanent description for a creator (or nil if not keyed yet).
    func creatorKnowledgeEntry(for creatorID: String) -> KnowledgeEntry? {
        let creatorKey = KnowledgeEntry.key(kind: .creator, subject: creatorID)
        return creatorKnowledge.first(where: { $0.id == creatorKey })
    }

    /// Insert or update a knowledge entry (dedup by key), routed to the term or
    /// creator map by kind. Bounded by trimming the oldest when over the cap.
    mutating func upsertKnowledgeEntry(_ entry: KnowledgeEntry) {
        // Junk term subjects (see isSpecificTermSubject) are never stored: they
        // could never match legitimately and would only bloat the catalog.
        if entry.kind == .term, !KnowledgeEntry.isSpecificTermSubject(entry.subject) { return }
        switch entry.kind {
        case .creator:
            if let index = creatorKnowledge.firstIndex(where: { $0.id == entry.id }) {
                creatorKnowledge[index] = entry
            } else {
                creatorKnowledge.append(entry)
                if creatorKnowledge.count > Self.maximumKnowledgeEntries {
                    creatorKnowledge.sort { $0.updatedAtMilliseconds > $1.updatedAtMilliseconds }
                    creatorKnowledge = Array(creatorKnowledge.prefix(Self.maximumKnowledgeEntries))
                }
            }
        case .term:
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
    }

    mutating func upsertResearchAttempt(_ attempt: ResearchAttemptRecord) {
        researchAttempts.removeAll {
            $0.classifierTypeID == attempt.classifierTypeID && $0.subjectKey == attempt.subjectKey
        }
        researchAttempts.insert(attempt, at: 0)
        if researchAttempts.count > Self.maximumResearchAttempts {
            researchAttempts = Array(researchAttempts.prefix(Self.maximumResearchAttempts))
        }
    }

    mutating func removeResearchAttempt(subjectKey: String, classifierTypeID: String? = nil) {
        researchAttempts.removeAll {
            $0.classifierTypeID == classifierTypeID && $0.subjectKey == subjectKey
        }
    }

    /// Records one video's derived urgency against a creator's accumulator
    /// (pruning samples outside the window), and — when the creator now has at
    /// least `threshold.count` samples averaging at least `threshold.level` — RESETS
    /// the accumulator and returns the rounded mean urgency to research the author
    /// with. Returns nil when the threshold is not yet met (RESEARCH-REDESIGN §8).
    @discardableResult
    mutating func recordCreatorResearchUrgency(
        classifierTypeID: String,
        creatorID: String,
        urgency: Int,
        threshold: AuthorResearchThreshold,
        nowMilliseconds: Int64
    ) -> Int? {
        let key = CreatorResearchAccumulator.key(classifierTypeID: classifierTypeID, creatorID: creatorID)
        let windowMilliseconds = Int64(threshold.windowDays) * 24 * 60 * 60 * 1_000
        let cutoff = nowMilliseconds - windowMilliseconds

        var accumulator = creatorResearchAccumulators.first(where: { $0.id == key }) ?? .init(id: key)
        accumulator.samples.removeAll { $0.atMilliseconds < cutoff }
        accumulator.samples.append(.init(urgency: urgency, atMilliseconds: nowMilliseconds))
        if accumulator.samples.count > Self.maximumCreatorUrgencySamples {
            accumulator.samples = Array(accumulator.samples.suffix(Self.maximumCreatorUrgencySamples))
        }

        var crossed: Int?
        if accumulator.samples.count >= threshold.count {
            let mean = Double(accumulator.samples.reduce(0) { $0 + $1.urgency }) / Double(accumulator.samples.count)
            if mean >= Double(threshold.level) {
                crossed = min(5, max(1, Int(mean.rounded())))
                accumulator.samples.removeAll()   // reset after firing
            }
        }

        creatorResearchAccumulators.removeAll { $0.id == key }
        // Keep only non-empty accumulators, newest activity first, under the bound.
        if !accumulator.samples.isEmpty {
            creatorResearchAccumulators.insert(accumulator, at: 0)
            if creatorResearchAccumulators.count > Self.maximumCreatorAccumulators {
                creatorResearchAccumulators = Array(creatorResearchAccumulators.prefix(Self.maximumCreatorAccumulators))
            }
        }
        return crossed
    }

    /// Stores one authoritative correction per classifier type/platform/video.
    /// Replacing an existing identity retains its stable id, while new examples
    /// are kept newest-first under the catalog's persisted bound.
    mutating func appendCorrectionExample(_ example: CorrectionExample) {
        let identity = "\(example.classifierTypeID)\u{1F}\(example.platformID)\u{1F}\(example.entryID)"
        if let index = correctionExamples.firstIndex(where: {
            "\($0.classifierTypeID)\u{1F}\($0.platformID)\u{1F}\($0.entryID)" == identity
        }) {
            var replacement = example
            replacement.id = correctionExamples[index].id
            correctionExamples[index] = replacement
        } else {
            correctionExamples.insert(example, at: 0)
        }
        correctionExamples.sort {
            if $0.createdAtMilliseconds != $1.createdAtMilliseconds {
                return $0.createdAtMilliseconds > $1.createdAtMilliseconds
            }
            return $0.id < $1.id
        }
        if correctionExamples.count > Self.maximumCorrectionExamples {
            correctionExamples = Array(correctionExamples.prefix(Self.maximumCorrectionExamples))
        }
    }

    /// Light structural validation for the new stores. Empty stores pass trivially,
    /// so existing/greenfield states are unaffected.
    func validateLocalLLMStores() throws {
        guard videoClassifications.count <= Self.maximumRetainedVideoClassifications else {
            throw WorkspaceCatalogError.invalidCollectedEntry("videoClassifications")
        }
        guard knowledgeEntries.count <= Self.maximumKnowledgeEntries,
              creatorKnowledge.count <= Self.maximumKnowledgeEntries,
              researchAttempts.count <= Self.maximumResearchAttempts,
              correctionExamples.count <= Self.maximumCorrectionExamples else {
            throw WorkspaceCatalogError.invalidCollectedEntry("localLLMStores")
        }
        try llmUniqueIDs(videoClassifications.map(\.id))
        try llmUniqueIDs(knowledgeEntries.map(\.id))
        try llmUniqueIDs(creatorKnowledge.map(\.id))
        try llmUniqueIDs(researchAttempts.map(\.id))
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
