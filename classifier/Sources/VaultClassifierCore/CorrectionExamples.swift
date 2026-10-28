import Foundation

/// A human-confirmed title and its final tags, used only as an example for
/// future, uncached items in the same group and taxonomy.
public struct CorrectionPromptExample: Codable, Equatable, Sendable {
    public let title: String
    public let tagNames: [String]

    public init(title: String, tagNames: [String]) {
        self.title = title
        self.tagNames = tagNames
    }
}

/// Select a few nearby corrections without an extra model call. Building the
/// index once per batch avoids repeatedly scanning the persisted catalog.
public struct CorrectionExampleSelector: Sendable {
    public static let maximumExamples = 3

    private struct Candidate: Sendable {
        let id: String
        let entryID: String
        let creatorID: String
        let createdAtMilliseconds: Int64
        let example: CorrectionPromptExample
        let words: Set<String>
        let grams: Set<String>
    }

    private let candidates: [Candidate]

    public init(catalog: WorkspaceCatalog, classifierType: ClassifierTypeAsset,
                platformID: String, tree: TagTreeAsset) {
        let activeNames = Dictionary(tree.nodes.filter { !$0.isRetired }.map { ($0.id, $0.name) },
                                     uniquingKeysWith: { first, _ in first })
        let corrected = Dictionary(catalog.videoClassifications
            .filter { $0.classifierTypeID == classifierType.id && $0.platformID == platformID && $0.source == .humanCorrected }
            .map { ($0.entryID, $0) }, uniquingKeysWith: { first, _ in first })
        candidates = catalog.correctionExamples.compactMap { record in
            guard record.classifierTypeID == classifierType.id,
                  record.platformID == platformID,
                  let row = corrected[record.entryID],
                  row.treeID == tree.id, row.treeRevision == tree.revision,
                  Set(row.tags.map(\.tagID)) == Set(record.correctTagIDs),
                  record.correctTagIDs.allSatisfy({ activeNames[$0] != nil }) else { return nil }
            let title = String(record.title.prefix(200))
            let terms = Self.terms(title)
            return Candidate(id: record.id, entryID: record.entryID,
                creatorID: record.creatorID, createdAtMilliseconds: record.createdAtMilliseconds,
                example: .init(title: title, tagNames: record.correctTagIDs.compactMap { activeNames[$0] }),
                words: terms.words, grams: terms.grams)
        }
    }

    public func select(title: String, creatorID: String, excluding entryID: String) -> [CorrectionPromptExample] {
        let query = Self.terms(title)
        let ranked = candidates.compactMap { candidate -> (Int, Candidate)? in
            guard candidate.entryID != entryID else { return nil }
            let words = query.words.intersection(candidate.words).count
            let grams = min(8, query.grams.intersection(candidate.grams).count)
            let sameCreator = !creatorID.isEmpty && candidate.creatorID == creatorID
            let score = words * 100 + grams * 5 + (sameCreator && (words > 0 || grams > 0) ? 20 : 0)
            return score > 0 ? (score, candidate) : nil
        }.sorted {
            if $0.0 != $1.0 { return $0.0 > $1.0 }
            if $0.1.createdAtMilliseconds != $1.1.createdAtMilliseconds {
                return $0.1.createdAtMilliseconds > $1.1.createdAtMilliseconds
            }
            return $0.1.id < $1.1.id
        }
        return ranked.prefix(Self.maximumExamples).map { $0.1.example }
    }

    private static let ignoredWords: Set<String> = [
        "a", "an", "and", "are", "at", "by", "for", "from", "how", "in", "is",
        "it", "of", "on", "or", "the", "this", "to", "video", "what", "with"
    ]

    private static func terms(_ title: String) -> (words: Set<String>, grams: Set<String>) {
        let folded = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let words = folded.split { !$0.isLetter && !$0.isNumber }
            .map(String.init).filter { $0.count > 2 && !ignoredWords.contains($0) }
        var grams = Set<String>()
        for word in words where word.count >= 4 {
            let letters = Array(word)
            for i in 0..<(letters.count - 2) { grams.insert(String(letters[i...i + 2])) }
        }
        return (Set(words), grams)
    }
}
