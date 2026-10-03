import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public enum CreatorDictionaryMode: String, Codable, Sendable { case cache, full }

public struct DictionarySettings: Codable, Equatable, Sendable {
    public var creatorMode: CreatorDictionaryMode = .cache
    public var creatorCacheSize: Int = 10_000
    public var contributionEnabled: Bool = true
    public var contributionChoiceMade: Bool = false
    public init() {}
    public mutating func reconcile() { creatorCacheSize = min(100_000, max(1, creatorCacheSize)) }
    private enum CodingKeys: String, CodingKey { case creatorMode, creatorCacheSize, contributionEnabled, contributionChoiceMade }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        creatorMode = (try? c.decode(CreatorDictionaryMode.self, forKey: .creatorMode)) ?? .cache
        creatorCacheSize = (try? c.decode(Int.self, forKey: .creatorCacheSize)) ?? 10_000
        contributionEnabled = (try? c.decode(Bool.self, forKey: .contributionEnabled)) ?? true
        contributionChoiceMade = (try? c.decode(Bool.self, forKey: .contributionChoiceMade)) ?? false
        reconcile()
    }
}

public struct OfficialDictionaryEntry: Codable, Equatable, Sendable {
    public var id: String
    public var kind: KnowledgeEntryKind
    public var subject: String
    public var meaning: String
    public var aliases: [String]
    public var updatedAtMilliseconds: Int64
    public func validate() throws {
        guard id == KnowledgeEntry.key(kind: kind, subject: subject), !subject.isEmpty, subject.count <= 512,
              !meaning.isEmpty, meaning.count <= KnowledgeEntry.maximumMeaningLength, aliases.count <= 16,
              aliases.allSatisfy({ !$0.isEmpty && $0.count <= (kind == .term ? 120 : 512) }),
              updatedAtMilliseconds >= 0 else { throw DictionaryError.invalidPack }
        if kind == .creator {
            guard ([subject] + aliases).allSatisfy(DictionaryKeys.isPublicCreatorID) else { throw DictionaryError.invalidPack }
        } else {
            guard subject.count <= 120, KnowledgeEntry.isSpecificTermSubject(subject),
                  aliases.allSatisfy(KnowledgeEntry.isSpecificTermSubject) else { throw DictionaryError.invalidPack }
        }
    }
    public func knowledge(subject matchedSubject: String? = nil) -> KnowledgeEntry {
        var result = KnowledgeEntry(kind: kind, subject: matchedSubject ?? subject, meaning: meaning,
                                    createdAtMilliseconds: updatedAtMilliseconds, updatedAtMilliseconds: updatedAtMilliseconds)
        result.id = id
        return result
    }
}

public enum DictionaryError: Error, LocalizedError {
    case invalidPack, unavailable, invalidPersonalPack, tooLarge, personalCapacityExceeded
    public var errorDescription: String? {
        switch self {
        case .invalidPack: return "The dictionary format or checksum is invalid."
        case .unavailable: return "The dictionary server is unavailable. Your local knowledge remains usable."
        case .invalidPersonalPack: return "Use a schemaVersion 1 personal dictionary with valid entries."
        case .tooLarge: return "This dictionary file exceeds the supported size."
        case .personalCapacityExceeded: return "Import would exceed 20,000 personal entries per kind. Your existing definitions were kept."
        }
    }
}

public enum DictionaryKeys {
    public static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public static func bucket(_ key: String) -> String { String(digest(Data(key.utf8)).prefix(2)) }
    public static func isPublicCreatorID(_ id: String) -> Bool {
        guard id.count <= 512 else { return false }
        return id.range(of: #"^(youtube:(?:channel:[A-Za-z0-9_-]+|handle:@[\p{L}\p{N}_.-]+)|bilibili:creator:space:[0-9]+|reddit:subreddit:[\p{L}\p{N}_-]+|twitter:account:[\p{L}\p{N}_]+)$"#, options: .regularExpression) != nil
    }
    public static func termKey(_ alias: String) -> String {
        let lower = alias.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if String(lower.prefix(1)).range(of: #"[\u3040-\u30ff\u3400-\u9fff\uac00-\ud7af]"#, options: .regularExpression) != nil { return String(lower.prefix(2)) }
        return lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).first.map(String.init) ?? lower
    }
    public static func titleKeys(_ title: String) -> Set<String> {
        let text = String(title.prefix(4096)).lowercased()
        var keys = Set(text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        let chars = Array(text)
        if chars.count > 1 {
            for i in 0..<(chars.count - 1) where String(chars[i]).range(of: #"[\u3040-\u30ff\u3400-\u9fff\uac00-\ud7af]"#, options: .regularExpression) != nil {
                keys.insert(String(chars[i...i+1]))
            }
        }
        return keys
    }
    /// Public displayed counts are sometimes rounded (1.2M); preserve missing as nil.
    public static func subscriberCount(_ attributes: [String: String]) -> Int64? {
        guard let raw = attributes["subscriberCount"] ?? attributes["followerCount"], raw.count <= 64 else { return nil }
        let value = raw.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: " ", with: "")
        guard let range = value.range(of: #"^[0-9]+(?:\.[0-9]+)?"#, options: .regularExpression),
              let base = Double(value[range]), base.isFinite else { return nil }
        let suffix = value[range.upperBound...].uppercased()
        let multiplier: Double = suffix.hasPrefix("K") ? 1_000 : suffix.hasPrefix("M") || suffix.hasPrefix("百万") ? 1_000_000 : suffix.hasPrefix("B") ? 1_000_000_000 : suffix.hasPrefix("万") ? 10_000 : suffix.hasPrefix("亿") ? 100_000_000 : 1
        let count = base * multiplier
        return (0...1_000_000_000_000).contains(count) ? Int64(count) : nil
    }
}

public struct DictionaryEvidence: Sendable {
    public var terms: [KnowledgeEntry] = []
    public var creator: KnowledgeEntry?
    public init(terms: [KnowledgeEntry] = [], creator: KnowledgeEntry? = nil) { self.terms = terms; self.creator = creator }
    public func overlay(on catalog: WorkspaceCatalog, title: String, creatorID: String) -> WorkspaceCatalog {
        var result = catalog
        for entry in terms {
            if let personal = catalog.knowledgeEntries.first(where: { $0.id == entry.id }) {
                // An alias may match where the personal canonical subject doesn't.
                var alias = personal; alias.subject = entry.subject
                result.knowledgeEntries.removeAll { $0.id == personal.id }; result.knowledgeEntries.append(alias)
            } else { result.knowledgeEntries.append(entry) }
        }
        if let creator, catalog.creatorKnowledgeEntry(for: creatorID) == nil {
            // Resolve official aliases onto the collected creator ID. A personal
            // definition of the canonical creator also wins for its aliases.
            var resolved = catalog.creatorKnowledge.first(where: { $0.id == creator.id }) ?? creator
            resolved.id = KnowledgeEntry.key(kind: .creator, subject: creatorID)
            resolved.subject = creatorID
            result.creatorKnowledge.append(resolved)
        }
        return result
    }
    public static func fingerprint(title: String, creatorID: String, catalog: WorkspaceCatalog, settings: ResearchSettings, limit: Int? = nil, ttlDays: Int? = nil) -> String {
        let entries = catalog.matchedKnowledge(title: title, creatorID: creatorID, limit: limit ?? settings.maxKnowledgePerVideo, ttlDays: ttlDays ?? settings.knowledgeTTLDays)
            + (catalog.creatorKnowledgeEntry(for: creatorID).map { [$0] } ?? [])
        let rows = entries.map { [$0.id, $0.subject, $0.meaning] }.sorted { $0[0] < $1[0] }
        return DictionaryKeys.digest((try? JSONEncoder().encode(rows)) ?? Data())
    }
}

public protocol DictionaryEvidenceProviding: Sendable {
    func localEvidence(title: String, creatorID: String) -> DictionaryEvidence
    func evidence(title: String, creatorID: String, subscriberCount: Int64?) async -> DictionaryEvidence
}

public struct PersonalDictionaryPack: Codable, Sendable {
    public struct Entry: Codable, Sendable { public var kind: KnowledgeEntryKind; public var subject: String; public var meaning: String }
    public var schemaVersion: Int
    public var entries: [Entry]
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 8 * 1024 * 1024 else { throw DictionaryError.tooLarge }
        let pack = try JSONDecoder().decode(Self.self, from: data)
        guard pack.schemaVersion == 1, pack.entries.count <= 20_000 else { throw DictionaryError.invalidPersonalPack }
        for e in pack.entries {
            guard !e.meaning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  e.meaning.count <= KnowledgeEntry.maximumMeaningLength,
                  e.subject.count <= (e.kind == .term ? 120 : 512),
                  e.kind == .term ? KnowledgeEntry.isSpecificTermSubject(e.subject) : DictionaryKeys.isPublicCreatorID(e.subject) else { throw DictionaryError.invalidPersonalPack }
        }
        return pack
    }
}
