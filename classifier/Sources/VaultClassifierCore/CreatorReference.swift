import Foundation

/// A creator the user names in Knowledge → "Add a creator" (owner 2026-09-30):
/// a link, an @handle, `r/name`, a Bilibili space link — or the name of a
/// creator the classifier has already collected. Resolves to the creator id the
/// collectors store (`youtube:handle:@name`, `youtube:channel:UC…`,
/// `bilibili:creator:space:<mid>`, `reddit:subreddit:<name>`,
/// `twitter:account:<handle>`), so knowledge keyed by it reaches that creator.
public enum CreatorReference {
    /// The platforms creator knowledge covers, in the order the page lists them.
    public static let platforms = ["youtube", "bilibili", "reddit", "twitter"]

    public static func creatorID(platformID: String, input rawInput: String, known: [CollectedPlatformEntry]) -> String? {
        let input = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, input.count <= 512 else { return nil }
        if let parsed = parse(platformID: platformID, input: input) { return parsed }
        // A name the classifier has seen on this platform.
        let wanted = input.lowercased()
        return known.first { $0.platformID == platformID && $0.creatorName.lowercased() == wanted }?.creatorID
    }

    static func parse(platformID: String, input: String) -> String? {
        switch platformID {
        case "youtube":
            if let channel = firstMatch(#"/channel/(UC[0-9A-Za-z_-]{22})"#, in: input) { return "youtube:channel:\(channel)" }
            if let handle = firstMatch(#"(?:^|/)@([^/?#\s]+)"#, in: input) { return "youtube:handle:@\(handle.lowercased())" }
        case "bilibili":
            if let mid = firstMatch(#"space\.bilibili\.com/(\d+)"#, in: input) ?? firstMatch(#"^(\d+)$"#, in: input) {
                return "bilibili:creator:space:\(mid)"
            }
        case "reddit":
            if let name = firstMatch(#"(?:^|/)r/([A-Za-z0-9_]{2,21})(?:[/?#]|$)"#, in: input) { return "reddit:subreddit:\(name.lowercased())" }
        case "twitter":
            if let handle = firstMatch(#"(?:x|twitter)\.com/([A-Za-z0-9_]{1,15})(?:[/?#]|$)"#, in: input)
                ?? firstMatch(#"^@([A-Za-z0-9_]{1,15})$"#, in: input) {
                return "twitter:account:\(handle.lowercased())"
            }
        default:
            break
        }
        return nil
    }

    /// The platform part of a creator id ("youtube:handle:@x" → "youtube").
    public static func platformID(of creatorID: String) -> String {
        String(creatorID.prefix { $0 != ":" })
    }

    /// A readable name from the id alone, for a creator the classifier no
    /// longer holds collected entries of.
    public static func fallbackName(of creatorID: String) -> String {
        let parts = creatorID.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count == 3 else { return creatorID }
        switch (parts[0], parts[1]) {
        case ("reddit", "subreddit"): return "r/\(parts[2])"
        case ("twitter", "account"): return "@\(parts[2])"
        case ("bilibili", _): return parts[2].replacingOccurrences(of: "space:", with: "UID ")
        default: return parts[2]
        }
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
