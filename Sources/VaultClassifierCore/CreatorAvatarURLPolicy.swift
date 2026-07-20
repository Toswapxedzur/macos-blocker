import Foundation

/// Accepts only public avatar URLs issued by a collection platform or that
/// platform's reviewed image delivery hosts. Collection may contain a URL but
/// never raw image bytes; the app cache is therefore unable to fetch an
/// arbitrary page-provided address.
public enum CreatorAvatarURLPolicy {
    private static let hostsByPlatform: [String: [String]] = [
        "youtube": ["youtube.com", "yt3.ggpht.com", "yt3.googleusercontent.com", "googleusercontent.com"],
        "tiktok": ["tiktok.com", "tiktokcdn.com", "tiktokcdn-us.com", "muscdn.com", "ibytedtos.com"],
        "facebook": ["facebook.com", "fbcdn.net", "fbsbx.com"],
        "instagram": ["instagram.com", "cdninstagram.com", "fbcdn.net"],
        "twitch": ["twitch.tv", "jtvnw.net"],
        "reddit": ["reddit.com", "redd.it", "redditstatic.com", "redditmedia.com"],
        "twitter": ["x.com", "twitter.com", "twimg.com"],
        "bilibili": ["bilibili.com", "biliimg.com", "hdslb.com"],
    ]

    /// Public creator pages may be revisited only after an explicit user
    /// request to fill missing profile images. Keep this narrower than image
    /// delivery hosts so a stored creator URL cannot become an arbitrary
    /// network request.
    private static let creatorPageHostsByPlatform: [String: [String]] = [
        "youtube": ["youtube.com"],
        "tiktok": ["tiktok.com"],
        "facebook": ["facebook.com"],
        "instagram": ["instagram.com"],
        "twitch": ["twitch.tv"],
        "reddit": ["reddit.com"],
        "twitter": ["x.com", "twitter.com"],
        "bilibili": ["bilibili.com"],
    ]

    public static func isAccepted(platformID: String, value: String) -> Bool {
        isAccepted(value: value, platformID: platformID, hosts: hostsByPlatform)
    }

    public static func isAcceptedCreatorPageURL(platformID: String, value: String) -> Bool {
        isAccepted(value: value, platformID: platformID, hosts: creatorPageHostsByPlatform)
    }

    private static func isAccepted(
        value: String,
        platformID: String,
        hosts: [String: [String]]
    ) -> Bool {
        guard value.utf8.count <= CollectedPlatformEntry.maximumAttributeValueLength,
              let url = URL(string: value),
              url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              let host = url.host?.lowercased() else {
            return false
        }
        return (hosts[platformID] ?? []).contains { suffix in
            host == suffix || host.hasSuffix(".\(suffix)")
        }
    }
}
