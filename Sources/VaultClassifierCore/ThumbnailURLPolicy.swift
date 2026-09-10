import Foundation

/// Accepts only a public thumbnail/cover image URL served by a collection
/// platform's reviewed image delivery hosts. The URL is the entry's OWN cover
/// (a video thumbnail, a Bilibili cover) supplied so the app can run on-device
/// OCR for classification evidence — never post media, galleries, comment
/// images, or user avatars, and never image bytes. Platforms whose thumbnail
/// URL is derivable from the entry id (YouTube) need not supply one.
public enum ThumbnailURLPolicy {
    public static let maximumLength = 512

    private static let hostsByPlatform: [String: [String]] = [
        "youtube": ["ytimg.com", "youtube.com"],
        "bilibili": ["hdslb.com", "biliimg.com", "bilibili.com"],
        // Reddit is listed for completeness of the host inventory; the Reddit
        // collector deliberately does not read post media (see its header).
        "reddit": ["redd.it", "redditmedia.com", "redditstatic.com"],
    ]

    public static func isAccepted(platformID: String, value: String) -> Bool {
        guard value.utf8.count <= maximumLength,
              let url = URL(string: value),
              url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              let host = url.host?.lowercased() else {
            return false
        }
        return (hostsByPlatform[platformID] ?? []).contains { suffix in
            host == suffix || host.hasSuffix(".\(suffix)")
        }
    }

    /// The URL to OCR for an entry: YouTube's deterministic hqdefault, else the
    /// collector-supplied cover when the platform's policy accepts it.
    public static func resolve(platformID: String, entryID: String, provided: String?) -> URL? {
        if platformID == "youtube" {
            let parts = entryID.split(separator: ":", omittingEmptySubsequences: false)
            if parts.count == 3, parts[1] == "video" {
                let id = String(parts[2])
                if !id.isEmpty, id.count <= 20, id.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil {
                    return URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg")
                }
            }
        }
        guard let provided, isAccepted(platformID: platformID, value: provided) else { return nil }
        return URL(string: provided)
    }
}
