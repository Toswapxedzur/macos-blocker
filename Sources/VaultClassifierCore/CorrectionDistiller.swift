import Foundation

/// Deterministically condenses local, user-authored corrections into a bounded
/// per-type prompt block. This is deliberately local-only: correction titles
/// and notes never enter the provider-backed research executor.
public enum CorrectionDistiller {
    public static let batchSize = 5
    public static let maximumLearnedRulesCharacters = 2_000
    public static let startMarker = "[Learned preferences"
    public static let endMarker = "[/Learned preferences]"

    public static func distill(
        corrections: [CorrectionExample],
        tree: TagTreeAsset,
        limit requestedLimit: Int = maximumLearnedRulesCharacters
    ) -> String {
        let limit = min(maximumLearnedRulesCharacters, max(0, requestedLimit))
        guard limit > 0 else { return "" }
        let namesByID = Dictionary(uniqueKeysWithValues: tree.nodes.map { ($0.id, $0.name) })
        let ordered = corrections.sorted {
            if $0.createdAtMilliseconds != $1.createdAtMilliseconds {
                return $0.createdAtMilliseconds > $1.createdAtMilliseconds
            }
            return $0.id < $1.id
        }
        var lines: [String] = []
        var length = 0
        for correction in ordered {
            let title = compact(correction.title, limit: 120)
            let tagNames = correction.correctTagIDs.compactMap { namesByID[$0] }
            let decision = tagNames.isEmpty
                ? "apply no tag"
                : "prefer " + tagNames.map { "\"" + compact($0, limit: 80) + "\"" }.joined(separator: ", ")
            let note = correction.note.flatMap { value -> String? in
                let cleaned = compact(value, limit: 120)
                return cleaned.isEmpty ? nil : cleaned
            }
            var line = "- For content like \"" + title + "\", " + decision + "."
            if let note { line += " User note: " + note }
            guard length + line.count + (lines.isEmpty ? 0 : 1) <= limit else { continue }
            lines.append(line)
            length += line.count + (lines.count == 1 ? 0 : 1)
        }
        return lines.joined(separator: "\n")
    }

    public static func combinedHouseRules(
        manualHouseRules: String?,
        learnedRules: String,
        correctionCount: Int
    ) -> String? {
        let manual = manualRules(from: manualHouseRules)
        let learned = learnedRules.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !learned.isEmpty else { return manual.isEmpty ? nil : manual }
        let header = startMarker + "; " + String(max(0, correctionCount)) + " corrections]\n"
        let separator = manual.isEmpty ? "" : "\n\n"
        let available = 4_000 - manual.count - separator.count - header.count - 1 - endMarker.count
        guard available > 0 else { return manual.isEmpty ? nil : manual }
        let boundedLearned = String(learned.prefix(available))
        let block = header + boundedLearned + "\n" + endMarker
        return manual + separator + block
    }

    public static func manualRules(from houseRules: String?) -> String {
        let value = houseRules ?? ""
        guard let start = value.range(of: startMarker) else {
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var retained = String(value[..<start.lowerBound])
        if let end = value.range(of: endMarker, range: start.lowerBound..<value.endIndex) {
            retained += String(value[end.upperBound...])
        }
        return retained.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func distilledCorrectionCount(in houseRules: String?) -> Int {
        guard let value = houseRules,
              let start = value.range(of: startMarker),
              let end = value.range(of: " corrections]", range: start.upperBound..<value.endIndex)
        else { return 0 }
        let countText = value[start.upperBound..<end.lowerBound]
            .trimmingCharacters(in: CharacterSet(charactersIn: "; "))
        return Int(countText) ?? 0
    }

    public static func containsLearnedPreferences(_ houseRules: String?) -> Bool {
        houseRules?.contains(startMarker) == true && houseRules?.contains(endMarker) == true
    }

    private static func compact(_ value: String, limit: Int) -> String {
        String(value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .prefix(limit))
    }
}
