import Foundation

/// One of the user's past corrections, resolved to on-taxonomy tag names, ready
/// to drop into a prompt as a grounded few-shot exemplar.
public struct CorrectionExemplar: Sendable, Equatable {
    public let title: String
    /// The tags the user chose (empty means the user chose "no tag").
    public let tagNames: [String]
    public let note: String?
    /// Whether this correction is from the same creator as the video being
    /// classified — the caller may surface it, but it is not framing for the model.
    public let sameCreator: Bool
    public init(title: String, tagNames: [String], note: String?, sameCreator: Bool) {
        self.title = title
        self.tagNames = tagNames
        self.note = note
        self.sameCreator = sameCreator
    }
}

/// Grounded generalization: instead of a static, recency-ordered block of the
/// user's corrections (which is the same for every video and can bury the
/// relevant ones), we retrieve — per video — the corrections most SIMILAR to the
/// one being classified and hand those to the model as concrete exemplars. The
/// model then generalizes at inference from real cases the user actually
/// decided, never from an invented rule. Fully deterministic and on-device: no
/// embeddings, just lexical title overlap plus a same-creator signal.
public enum CorrectionRetriever {
    public static let defaultLimit = 6

    /// Minimum lexical (Jaccard) title similarity for a DIFFERENT-creator
    /// correction to be eligible. Same-creator corrections ignore this floor (the
    /// creator is itself a strong relevance signal). 0 disables it.
    ///
    /// Tuned by the dev A/B sweep (`VaultClassifierEval abtest --floor=…`, 120
    /// items): this is deliberately LOW. Raising it to actually remove the two
    /// observed regressions (0.08–0.10) cost more wins than it saved (14W/2R at
    /// ≤0.06 → 12W/1R at 0.08 → 11W/1R at 0.10) — the regressions ride the SAME
    /// 0.07–0.11 similarity band as real wins, so magnitude can't separate them
    /// (their real signature is exemplar DISAGREEMENT, not weakness). 0.06 is
    /// measured-neutral here (identical 14W/2R to no floor) and exists only to
    /// drop near-zero coincidental single-token overlaps for robustness.
    public static let defaultMinimumSimilarity = 0.06

    /// Tokens shorter than this (after normalization) are dropped as noise.
    private static let minimumTokenLength = 2

    /// A deliberately small stopword set — enough to stop generic words from
    /// manufacturing similarity, without discarding real topical tokens.
    private static let stopwords: Set<String> = [
        "the", "a", "an", "of", "to", "and", "in", "on", "for", "with", "is",
        "it", "my", "your", "this", "that", "how", "what", "why", "you", "vs",
        "ep", "part", "official", "video", "new", "best", "top", "full",
    ]

    /// Returns up to `limit` grounded exemplars for the given video, ranked by
    /// relevance. A same-creator correction is always eligible (the creator is
    /// itself a strong relevance signal); a different-creator correction is
    /// eligible only when its title shares a real token with this one. The
    /// current video's own correction, if any, is excluded by `excludingEntryID`.
    public static func retrieve(
        title: String,
        creatorID: String,
        excludingEntryID: String?,
        from corrections: [CorrectionExample],
        tree: TagTreeAsset,
        limit: Int = defaultLimit,
        minimumSimilarity: Double = defaultMinimumSimilarity
    ) -> [CorrectionExemplar] {
        guard limit > 0, !corrections.isEmpty else { return [] }
        let nameByID = Dictionary(tree.nodes.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let queryTokens = tokens(from: title)

        struct Ranked {
            let exemplar: CorrectionExemplar
            let score: Double
            let createdAt: Int64
            let id: String
        }

        var ranked: [Ranked] = []
        for correction in corrections {
            if let excludingEntryID, correction.entryID == excludingEntryID { continue }
            let sameCreator = !creatorID.isEmpty && correction.creatorID == creatorID
            let overlap = jaccard(queryTokens, tokens(from: correction.title))
            // Eligibility: the same creator (always), or a DIFFERENT-creator
            // correction whose title overlap clears the similarity floor. The
            // floor keeps weak, coincidental cross-creator matches (a shared
            // stopword-adjacent token) from dragging a video off its real topic.
            guard sameCreator || (overlap > 0 && overlap >= minimumSimilarity) else { continue }
            // Same-creator dominates lexical overlap (a full unit) but overlap
            // still orders corrections within each creator bucket.
            let score = overlap + (sameCreator ? 1.0 : 0.0)
            let tagNames = correction.correctTagIDs.compactMap { nameByID[$0] }
            // A correction whose tags no longer exist in the tree is not a usable
            // exemplar unless it recorded a deliberate "no tag" decision.
            if tagNames.isEmpty && !correction.correctTagIDs.isEmpty { continue }
            ranked.append(Ranked(
                exemplar: CorrectionExemplar(
                    title: correction.title,
                    tagNames: tagNames,
                    note: correction.note,
                    sameCreator: sameCreator
                ),
                score: score,
                createdAt: correction.createdAtMilliseconds,
                id: correction.id
            ))
        }

        ranked.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.id < rhs.id
        }
        return ranked.prefix(limit).map(\.exemplar)
    }

    /// Weighted set overlap (Jaccard). 0 when either side is empty.
    private static func jaccard(_ lhs: Set<String>, _ rhs: Set<String>) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        let intersection = lhs.intersection(rhs).count
        guard intersection > 0 else { return 0 }
        let union = lhs.union(rhs).count
        return Double(intersection) / Double(union)
    }

    /// Lowercased alphanumeric tokens, minus stopwords and 1-char noise.
    static func tokens(from title: String) -> Set<String> {
        var result: Set<String> = []
        var current = ""
        for scalar in title.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                append(current, to: &result)
                current = ""
            }
        }
        if !current.isEmpty { append(current, to: &result) }
        return result
    }

    private static func append(_ token: String, to set: inout Set<String>) {
        guard token.count >= minimumTokenLength, !stopwords.contains(token) else { return }
        set.insert(token)
    }
}
