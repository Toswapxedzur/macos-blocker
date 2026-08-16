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
        lines.append("- Choose only tags that clearly apply; prefer specific child tags over broad parents.")
        lines.append("- Assign at most \(maximumTags) tags.")
        lines.append("- For each chosen tag give a confidence from 1 (low) to 5 (high).")
        lines.append("- If the title is uninformative, use the creator prior when provided, but treat it as a weak, partial sample of what the creator makes — it may not represent them fully.")
        lines.append("- Reply with one JSON object only: {\"tags\":[{\"name\":\"<tag name>\",\"confidence\":<1-5>}]}. Use tag names exactly as written. No prose.")
        lines.append("- If no tag clearly applies, use the word none as the name.")

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
        creatorPrior: [(tagName: String, averageConfidence: Double)],
        knowledge: [KnowledgeEntry]
    ) -> String {
        var lines: [String] = []

        if !knowledge.isEmpty {
            lines.append("Known context (grounded facts):")
            for entry in knowledge {
                lines.append("- \(entry.subject): \(entry.meaning)")
            }
            lines.append("")
        }

        if !creatorPrior.isEmpty {
            lines.append("Creator prior — tags from videos you've seen from this creator. This is a partial, possibly biased sample of their content (your view history), NOT their full range; weight it lightly:")
            for item in creatorPrior {
                lines.append("- \(item.tagName): average confidence \(String(format: "%.1f", item.averageConfidence))")
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
        creatorPrior: [(tagName: String, averageConfidence: Double)],
        knowledge: [KnowledgeEntry]
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
            dynamicSuffix: dynamicSuffix(title: title, summary: summary, text: text, creatorPrior: creatorPrior, knowledge: knowledge),
            allowedTagNames: allowedTagNames,
            nameToTagID: nameToTagID
        )
    }
}
