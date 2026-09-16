import Foundation

// Builds the classification prompt as a cached static prefix + a small per-video
// dynamic suffix (see REWORK §7.1). The split is deliberate: the prefix (task
// rules + taxonomy + house-rules) is identical for every video, so its KV cache
// is reused; only the suffix (knowledge, creator prior, the title) changes.
// Everything here is deterministic so the prefix is byte-stable for cache hits.

public struct ClassificationPromptParts: Sendable, Equatable {
    public let staticPrefix: String
    public let dynamicSuffix: String
    public let allowedTagNames: [String]
    /// Readable tag name → internal tag id, for mapping the model's output back.
    public let nameToTagID: [String: String]
}

/// One tag in a creator's history, as raw stats fed to the model (no framing —
/// the model judges how much to weight it): how many of the creator's classified
/// videos carry the tag, its share, and the confidence mean ± stdev.
public struct CreatorPriorTag: Sendable, Equatable {
    public let tagName: String
    public let count: Int
    public let share: Double
    public let averageConfidence: Double
    public let confidenceStdev: Double
    public init(tagName: String, count: Int, share: Double, averageConfidence: Double, confidenceStdev: Double) {
        self.tagName = tagName
        self.count = count
        self.share = share
        self.averageConfidence = averageConfidence
        self.confidenceStdev = confidenceStdev
    }
}

public enum ClassificationPromptAssembler {
    public static let maximumEvidenceTextLength = 1_000

    /// Non-retired tags as readable options, with their parent name for context.
    public static func tagOptions(from tree: TagTreeAsset) -> [LLMTagOption] {
        let nameByID = Dictionary(tree.nodes.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        return tree.nodes
            .filter { !$0.isRetired }
            .map { node in
                LLMTagOption(
                    id: node.id,
                    name: node.name,
                    description: node.description,
                    parentName: node.parentID.flatMap { nameByID[$0] }
                )
            }
    }

    /// The cached static prefix: task rules + taxonomy + optional house-rules.
    public static func staticPrefix(taxonomy: [LLMTagOption], houseRules: String?, maximumTags: Int) -> String {
        var lines: [String] = []
        lines.append("You are a tagging model. Classify a single video into tags from the taxonomy below, using the video's evidence.")
        lines.append("Rules:")
        lines.append("- Pick the tag(s) that best match the video's topic; prefer specific child tags over broad parents. Infer the topic from the title even when it is short — a named subject (a person, product, game, show, place, event, or theme) is usually enough to place it, so do not decline just because the title is brief.")
        lines.append("- Assign at most \(maximumTags) tags.")
        lines.append("- For each chosen tag give a confidence from 1 to 5 for how sure you are the tag is correct (not how popular the tag is): 5 = the evidence names a subject you are certain maps to this tag; 4 = strong evidence; 3 = a plausible inference; 2 = a weak guess; 1 = little basis. Reserve 4 and 5 for clear cases, and use 1-2 when you are mostly guessing.")
        lines.append("- If the title is uninformative, use the creator prior when provided, but treat it as a weak, partial sample of what the creator makes — it may not represent them fully.")
        lines.append("- Reply with one JSON object only: {\"tags\":[{\"name\":\"<tag name>\",\"confidence\":<1-5>}]}. Use tag names exactly as written. No prose.")
        lines.append("- Use none only when the title names no topic at all — a bare question, reaction, or phrase with no subject. Do not force a tag onto a genuinely topicless title, and do not invent a topic the title does not state.")

        if let houseRules, !houseRules.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("")
            lines.append("House rules (the user's tagging preferences):")
            lines.append(houseRules.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        lines.append("")
        lines.append("Taxonomy:")
        if taxonomy.isEmpty {
            lines.append("(no tags defined yet)")
        } else {
            for option in taxonomy {
                var line = "- \(option.name)"
                if let parent = option.parentName, !parent.isEmpty { line += " (under \(parent))" }
                if let description = option.description, !description.isEmpty { line += ": \(description)" }
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n")
    }

    /// The per-video dynamic suffix: matched knowledge, the derived creator prior
    /// (with the required view-history caveat), and the video's own evidence.
    public static func dynamicSuffix(
        title: String,
        summary: String?,
        text: String?,
        creatorPrior: [CreatorPriorTag],
        creatorVideoCount: Int,
        knowledge: [KnowledgeEntry],
        correctionExemplars: [CorrectionExemplar] = []
    ) -> String {
        var lines: [String] = []

        if !knowledge.isEmpty {
            lines.append("Known context (grounded facts):")
            for entry in knowledge {
                lines.append("- \(entry.subject): \(entry.meaning)")
            }
            lines.append("")
        }

        // Grounded generalization: the user's own past corrections most similar
        // to THIS video (see CorrectionRetriever). Real title → chosen tag pairs,
        // on-taxonomy — the model generalizes from these concrete decisions, not
        // from an invented rule. Presented as labeled data (the user's authored
        // corrections on related videos); the model judges how closely they apply
        // rather than being commanded to copy them.
        if !correctionExemplars.isEmpty {
            lines.append("The user's own past corrections on related videos (title → the tag they chose):")
            for exemplar in correctionExemplars {
                let decision = exemplar.tagNames.isEmpty
                    ? "no tag"
                    : exemplar.tagNames.joined(separator: ", ")
                var line = "- \"\(String(exemplar.title.prefix(160)))\" → \(decision)"
                if let note = exemplar.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
                    line += " (\(String(note.prefix(120))))"
                }
                lines.append(line)
            }
            lines.append("")
        }

        // Plain data — the model judges how much to weight it (no framing).
        // Per tag: share of the creator's classified videos + confidence mean±stdev.
        if !creatorPrior.isEmpty, creatorVideoCount > 0 {
            lines.append("Creator's tag history (\(creatorVideoCount) of their videos classified):")
            for item in creatorPrior {
                lines.append("- \(item.tagName): \(item.count)/\(creatorVideoCount) (\(Int((item.share * 100).rounded()))%), confidence \(String(format: "%.1f", item.averageConfidence))±\(String(format: "%.1f", item.confidenceStdev))")
            }
            lines.append("")
        }

        lines.append("Video:")
        lines.append("Title: \(title)")
        if let summary = summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            lines.append("Summary: \(String(summary.prefix(maximumEvidenceTextLength)))")
        }
        if let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            lines.append("Text: \(String(text.prefix(maximumEvidenceTextLength)))")
        }
        // FINAL CONTRACT (Phase-0, 2026-08-15): the JSON scaffold is the model's
        // structural runway and must be IN the prompt — prefilled in parallel,
        // never generated. The engine's grammar then admits only a tag name, so
        // the model's first decoded token is the decision itself. Removing this
        // scaffold (or the reply-shape rule above) measurably regressed
        // accuracy from 7/8 to 5/8.
        lines.append("Output JSON: {\"tags\":[{\"name\":\"")
        return lines.joined(separator: "\n")
    }

    /// Assemble the full prompt parts for one video against one tree.
    public static func assemble(
        tree: TagTreeAsset,
        houseRules: String?,
        maximumTags: Int,
        title: String,
        summary: String?,
        text: String?,
        creatorPrior: [CreatorPriorTag],
        creatorVideoCount: Int,
        knowledge: [KnowledgeEntry],
        correctionExemplars: [CorrectionExemplar] = []
    ) -> ClassificationPromptParts {
        let taxonomy = tagOptions(from: tree)
        // De-duplicate names for the allowed set + mapping (a tree with duplicate
        // names keeps the first id; that is the author's ambiguity, not ours).
        var nameToTagID: [String: String] = [:]
        var allowedTagNames: [String] = []
        for option in taxonomy where nameToTagID[option.name] == nil {
            nameToTagID[option.name] = option.id
            allowedTagNames.append(option.name)
        }
        return ClassificationPromptParts(
            staticPrefix: staticPrefix(taxonomy: taxonomy, houseRules: houseRules, maximumTags: maximumTags),
            dynamicSuffix: dynamicSuffix(title: title, summary: summary, text: text, creatorPrior: creatorPrior, creatorVideoCount: creatorVideoCount, knowledge: knowledge, correctionExemplars: correctionExemplars),
            allowedTagNames: allowedTagNames,
            nameToTagID: nameToTagID
        )
    }
}
