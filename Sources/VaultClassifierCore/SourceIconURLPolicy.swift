import Foundation

/// Accepts only public source-icon URLs issued by a collection platform or
/// that platform's reviewed image delivery hosts. The source may be a creator,
/// account, subreddit, or server. Collection may contain a URL but never raw
/// image bytes, post media, thumbnails, or comment-author images.
public enum SourceIconURLPolicy {
    private static let hostsByPlatform: [String: [String]] = [
        "youtube": ["youtube.com", "yt3.ggpht.com", "yt3.googleusercontent.com", "googleusercontent.com"],
        "tiktok": ["tiktok.com", "tiktokcdn.com", "tiktokcdn-us.com", "muscdn.com", "ibytedtos.com"],
        "facebook": ["facebook.com", "fbcdn.net", "fbsbx.com"],
        "instagram": ["instagram.com", "cdninstagram.com", "fbcdn.net"],
        "twitch": ["twitch.tv", "jtvnw.net"],
        "reddit": ["reddit.com", "redd.it", "redditstatic.com", "redditmedia.com"],
        "discord": ["discord.com", "discordapp.com", "discordapp.net", "discordappcdn.com"],
        "twitter": ["x.com", "twitter.com", "twimg.com"],
        "bilibili": ["bilibili.com", "biliimg.com", "hdslb.com"],
    ]

    public static func isAccepted(platformID: String, value: String) -> Bool {
        isAccepted(value: value, platformID: platformID, hosts: hostsByPlatform)
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
