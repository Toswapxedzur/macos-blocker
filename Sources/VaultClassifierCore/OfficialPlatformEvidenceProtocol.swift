import Foundation

/// The local app, rather than a model, chooses the bounded official platform
/// requests that supply fresh evidence for a creator classification.
public enum OfficialPlatformEvidenceTarget: String, Codable, Equatable, Sendable {
    case creator
    /// Used only for platforms whose reviewed public API has no creator
    /// lookup. The entry is the representative collected item for its creator.
    case representativeEntry
}

public struct OfficialPlatformEvidencePreparedRequest: Equatable, Sendable {
    public var plan: ProviderRequestPlan
    public var target: OfficialPlatformEvidenceTarget
    public var providerType: APIKeyProviderType
    public var body: Data?

    public init(
        plan: ProviderRequestPlan,
        target: OfficialPlatformEvidenceTarget,
        providerType: APIKeyProviderType,
        body: Data? = nil
    ) {
        self.plan = plan
        self.target = target
        self.providerType = providerType
        self.body = body
    }
}

/// A credential-free health request for one saved official platform API
/// profile. It intentionally includes no collected creator data.
public struct OfficialPlatformConnectionTestRequest: Equatable, Sendable {
    public var plan: ProviderRequestPlan
    public var body: Data?

    public init(plan: ProviderRequestPlan, body: Data? = nil) {
        self.plan = plan
        self.body = body
    }
}

public enum OfficialPlatformEvidenceProtocol {
    public static let maximumEvidenceCharacters = 15_000
    /// Every official adapter receives the same bounded transport allowance.
    /// Prompt compaction below remains the tighter disclosure boundary.
    public static let maximumResponseBytes = 1_024 * 1_024

    /// Prepares the first bounded API request for a creator classification.
    /// The model never controls the target, identifier, URL, query, headers,
    /// request count, or request body.
    public static func prepare(
        profile: APIKeyProviderProfile,
        entry: EntryEvidence,
        maximumResults: Int = LLMAssistConfiguration.defaultOfficialContentEvidenceCount
    ) throws -> OfficialPlatformEvidencePreparedRequest {
        try EntryEvidenceValidator().validate(entry)
        guard maximumResults > 0,
              maximumResults <= LLMAssistConfiguration.maximumOfficialContentEvidenceCount else {
            throw OfficialPlatformEvidenceProtocolError.invalidConfiguration
        }
        let descriptor = ProviderProtocolRegistry.descriptor(for: profile.type)
        guard !descriptor.supportsLLMConfiguration,
              descriptor.requestFormats.contains(where: { $0.operation == .readPublicContent }) else {
            throw OfficialPlatformEvidenceProtocolError.invalidConfiguration
        }
        try profile.validateForDispatch()
        let target = try preferredTarget(for: profile.type, entry: entry)
        let identifier = try normalizedIdentifier(for: profile.type, target: target, entry: entry)
        let identifiers = try normalizedContentIdentifiers(
            for: profile.type,
            target: target,
            entry: entry,
            fallback: identifier,
            maximumResults: maximumResults
        )
        let baseURL = try baseURL(profile: profile, descriptor: descriptor)
        let route = try requestRoute(
            profile: profile,
            target: target,
            identifier: identifier,
            contentIdentifiers: identifiers
        )
        let requestURL = try url(baseURL: baseURL, path: route.path, queryItems: route.queryItems)
        let body = try route.body.map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
        return .init(
            plan: .init(
                url: requestURL,
                method: route.method,
                bodyFormat: route.body == nil ? .queryOnly : .customJSON,
                headers: headers(profile: profile, descriptor: descriptor, hasBody: route.body != nil),
                authentication: descriptor.authentication,
                authenticationHeader: descriptor.authenticationHeader,
                requiredCredentialFields: descriptor.credentialFields
            ),
            target: target,
            providerType: profile.type,
            body: body
        )
    }

    public static func prepareConnectionTest(
        profile: APIKeyProviderProfile
    ) throws -> OfficialPlatformConnectionTestRequest {
        let descriptor = ProviderProtocolRegistry.descriptor(for: profile.type)
        guard !descriptor.supportsLLMConfiguration,
              descriptor.requestFormats.contains(where: { $0.operation == .readPublicContent }) else {
            throw OfficialPlatformEvidenceProtocolError.invalidConfiguration
        }
        try profile.validateForDispatch()
        let baseURL = try baseURL(profile: profile, descriptor: descriptor)
        let route = try connectionTestRoute(profile.type, profile: profile)
        let requestURL = try url(baseURL: baseURL, path: route.path, queryItems: route.queryItems)
        let body = try route.body.map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
        return .init(
            plan: .init(
                url: requestURL,
                method: route.method,
                bodyFormat: route.body == nil ? .queryOnly : .customJSON,
                headers: headers(profile: profile, descriptor: descriptor, hasBody: route.body != nil),
                authentication: descriptor.authentication,
                authenticationHeader: descriptor.authenticationHeader,
                requiredCredentialFields: descriptor.credentialFields
            ),
            body: body
        )
    }

    /// Resolves the channel's official uploads playlist and requests one recent
    /// page. Only video identifiers are needed here; full public records are
    /// fetched in the following bounded `videos.list` request.
    public static func prepareYouTubeUploadsRequest(
        profile: APIKeyProviderProfile,
        channelData: Data,
        maximumResults: Int
    ) throws -> OfficialPlatformEvidencePreparedRequest {
        guard profile.type == .youtubeData,
              maximumResults > 0,
              maximumResults <= LLMAssistConfiguration.maximumOfficialContentEvidenceCount else {
            throw OfficialPlatformEvidenceProtocolError.invalidConfiguration
        }
        let playlistID = try youtubeUploadsPlaylistID(from: channelData)
        return try prepareFollowUpRequest(
            profile: profile,
            route: .init(
                method: "GET",
                path: ["playlistItems"],
                queryItems: [
                    .init(name: "part", value: "contentDetails"),
                    .init(name: "playlistId", value: playlistID),
                    .init(name: "maxResults", value: String(maximumResults)),
                ],
                body: nil
            )
        )
    }

    /// Requests the full public records for the recent upload identifiers in
    /// playlist order. A channel with no visible uploads legitimately returns
    /// no request and contributes its channel record only.
    public static func prepareYouTubeVideoRecordsRequest(
        profile: APIKeyProviderProfile,
        playlistData: Data,
        maximumResults: Int
    ) throws -> OfficialPlatformEvidencePreparedRequest? {
        guard profile.type == .youtubeData,
              maximumResults > 0,
              maximumResults <= LLMAssistConfiguration.maximumOfficialContentEvidenceCount else {
            throw OfficialPlatformEvidenceProtocolError.invalidConfiguration
        }
        let identifiers = try youtubeVideoIdentifiers(
            from: playlistData,
            maximumResults: maximumResults
        )
        guard !identifiers.isEmpty else { return nil }
        let parts = [
            "id", "snippet", "contentDetails", "statistics", "topicDetails",
            "recordingDetails", "liveStreamingDetails", "status",
            "localizations", "paidProductPlacementDetails", "brandPartner",
        ].joined(separator: ",")
        return try prepareFollowUpRequest(
            profile: profile,
            route: .init(
                method: "GET",
                path: ["videos"],
                queryItems: [
                    .init(name: "part", value: parts),
                    .init(name: "id", value: identifiers.joined(separator: ",")),
                ],
                body: nil
            )
        )
    }

    /// Requests the bounded recent public-content feed that a platform exposes
    /// for the creator returned by the first request. YouTube retains its
    /// richer playlist-plus-record flow; TikTok's reviewed API starts from
    /// collected video identifiers and therefore has no creator follow-up.
    public static func prepareCreatorContentRequest(
        profile: APIKeyProviderProfile,
        creatorData: Data,
        maximumResults: Int
    ) throws -> OfficialPlatformEvidencePreparedRequest? {
        guard maximumResults > 0,
              maximumResults <= LLMAssistConfiguration.maximumOfficialContentEvidenceCount else {
            throw OfficialPlatformEvidenceProtocolError.invalidConfiguration
        }
        guard creatorData.count <= maximumResponseBytes else {
            throw OfficialPlatformEvidenceProtocolError.invalidResponse
        }
        let object = try jsonObject(from: creatorData)
        let route: Route
        switch profile.type {
        case .twitch:
            let creatorID = try responseIdentifier(in: object, path: ["data", "0", "id"])
            route = .init(
                method: "GET",
                path: ["videos"],
                queryItems: [
                    .init(name: "user_id", value: creatorID),
                    .init(name: "first", value: String(min(maximumResults, 100))),
                ],
                body: nil
            )
        case .reddit:
            let username = try responseIdentifier(in: object, path: ["data", "name"])
            route = .init(
                method: "GET",
                path: ["user", username, "submitted"],
                queryItems: [
                    .init(name: "limit", value: String(min(maximumResults, 100))),
                    .init(name: "raw_json", value: "1"),
                ],
                body: nil
            )
        case .xPlatform:
            let creatorID = try responseIdentifier(in: object, path: ["data", "id"])
            route = .init(
                method: "GET",
                path: ["users", creatorID, "tweets"],
                queryItems: [
                    .init(name: "max_results", value: String(max(5, min(maximumResults, 100)))),
                    .init(name: "tweet.fields", value: "article,attachments,author_id,card_uri,community_id,context_annotations,conversation_id,created_at,display_text_range,edit_controls,edit_history_tweet_ids,entities,geo,in_reply_to_user_id,lang,note_tweet,possibly_sensitive,public_metrics,referenced_tweets,reply_settings,scopes,source,suggested_source_links,suggested_source_links_with_counts,text,withheld"),
                    .init(name: "expansions", value: "article.cover_media,article.media_entities,attachments.media_keys,attachments.poll_ids,author_id,geo.place_id,in_reply_to_user_id,referenced_tweets.id,referenced_tweets.id.attachments.media_keys,referenced_tweets.id.author_id"),
                    .init(name: "media.fields", value: "alt_text,duration_ms,height,media_key,preview_image_url,public_metrics,type,url,variants,width"),
                    .init(name: "place.fields", value: "contained_within,country,country_code,full_name,geo,id,name,place_type"),
                    .init(name: "poll.fields", value: "duration_minutes,end_datetime,id,options,voting_status"),
                    .init(name: "user.fields", value: "affiliation,created_at,description,entities,id,is_identity_verified,location,most_recent_tweet_id,name,parody,pinned_tweet_id,profile_banner_url,profile_image_url,protected,public_metrics,subscription_type,url,username,verified,verified_followers_count,verified_type,withheld"),
                ],
                body: nil
            )
        case .instagramGraph:
            let creatorID = try responseIdentifier(in: object, path: ["id"])
            route = .init(
                method: "GET",
                path: [try metaAPIVersion(profile), creatorID, "media"],
                queryItems: [
                    .init(name: "limit", value: String(maximumResults)),
                    .init(name: "fields", value: "id,caption,media_type,media_product_type,permalink,timestamp,username,like_count,comments_count"),
                ],
                body: nil
            )
        case .facebookGraph:
            let creatorID = try responseIdentifier(in: object, path: ["id"])
            route = .init(
                method: "GET",
                path: [try metaAPIVersion(profile), creatorID, "published_posts"],
                queryItems: [
                    .init(name: "limit", value: String(maximumResults)),
                    .init(name: "fields", value: "id,message,story,created_time,permalink_url,attachments,shares,reactions.limit(0).summary(true),comments.limit(0).summary(true)"),
                ],
                body: nil
            )
        case .youtubeData, .tikTok:
            return nil
        default:
            throw OfficialPlatformEvidenceProtocolError.invalidConfiguration
        }
        return try prepareFollowUpRequest(profile: profile, route: route)
    }

    /// Builds one compact prompt object from the official channel record and
    /// the requested recent public video records. Every returned video keeps
    /// its ID, title, publication time, and public metrics; larger descriptive
    /// fields are reduced first so a high configured count cannot erase later
    /// records through a raw string prefix.
    public static func boundedYouTubeCreatorEvidence(
        channelData: Data,
        playlistData: Data,
        videoData: Data?,
        maximumVideoCount: Int
    ) throws -> String {
        guard maximumVideoCount > 0,
              maximumVideoCount <= LLMAssistConfiguration.maximumOfficialContentEvidenceCount,
              channelData.count <= maximumResponseBytes,
              playlistData.count <= maximumResponseBytes,
              (videoData?.count ?? 0) <= maximumResponseBytes else {
            throw OfficialPlatformEvidenceProtocolError.invalidResponse
        }
        let channelObject = try jsonObject(from: channelData)
        let videoObject = try videoData.map(jsonObject(from:))
        let orderedIDs = try youtubeVideoIdentifiers(
            from: playlistData,
            maximumResults: maximumVideoCount
        )
        let channel = compactYouTubeChannel(from: channelObject)
        var videos = compactYouTubeVideos(
            from: videoObject,
            orderedIDs: orderedIDs,
            includeDescriptions: true,
            tagLimit: 12
        )
        var evidence: [String: Any] = [
            "officialPlatform": APIKeyProviderType.youtubeData.rawValue,
            "target": OfficialPlatformEvidenceTarget.creator.rawValue,
            "requestedContentCount": maximumVideoCount,
            "returnedContentCount": videos.count,
            "creator": channel,
            "recentContentItems": videos,
        ]
        if let text = encodedEvidence(evidence), text.count <= maximumEvidenceCharacters {
            return text
        }

        videos = compactYouTubeVideos(
            from: videoObject,
            orderedIDs: orderedIDs,
            includeDescriptions: false,
            tagLimit: 4
        )
        evidence["recentContentItems"] = videos
        if let text = encodedEvidence(evidence), text.count <= maximumEvidenceCharacters {
            return text
        }

        evidence["recentContentItems"] = compactYouTubeVideoCores(
            from: videoObject,
            orderedIDs: orderedIDs
        )
        guard let text = encodedEvidence(evidence),
              text.count <= maximumEvidenceCharacters else {
            throw OfficialPlatformEvidenceProtocolError.invalidResponse
        }
        return text
    }

    /// Converts a successful API response to bounded, credential-free JSON
    /// for the classification prompt. It retains only public response data and
    /// strips common secret-bearing fields recursively.
    public static func boundedEvidence(
        data: Data,
        providerType: APIKeyProviderType,
        target: OfficialPlatformEvidenceTarget,
        maximumContentCount: Int = LLMAssistConfiguration.defaultOfficialContentEvidenceCount
    ) throws -> String {
        guard data.count <= maximumResponseBytes,
              maximumContentCount > 0,
              maximumContentCount <= LLMAssistConfiguration.maximumOfficialContentEvidenceCount,
              let value = try? JSONSerialization.jsonObject(with: data) else {
            throw OfficialPlatformEvidenceProtocolError.invalidResponse
        }
        let contentItems = extractedContentItems(from: value, maximumResults: maximumContentCount)
        var object: [String: Any] = [
            "officialPlatform": providerType.rawValue,
            "target": target.rawValue,
            "requestedContentCount": maximumContentCount,
            "returnedContentCount": contentItems.count,
            "recentContentItems": contentItems,
        ]
        if contentItems.isEmpty {
            object["creator"] = sanitized(value, depth: 0)
        }
        if let context = extractedContentContext(from: value) {
            object["contentContext"] = context
        }
        return try boundedEncodedEvidence(object)
    }

    /// Combines the public creator profile and recent official content into the
    /// same platform-neutral prompt shape used by every adapter.
    public static func boundedCreatorEvidence(
        creatorData: Data,
        contentData: Data?,
        providerType: APIKeyProviderType,
        maximumContentCount: Int
    ) throws -> String {
        guard creatorData.count <= maximumResponseBytes,
              (contentData?.count ?? 0) <= maximumResponseBytes,
              maximumContentCount > 0,
              maximumContentCount <= LLMAssistConfiguration.maximumOfficialContentEvidenceCount,
              let creatorValue = try? JSONSerialization.jsonObject(with: creatorData) else {
            throw OfficialPlatformEvidenceProtocolError.invalidResponse
        }
        let contentValue = contentData.flatMap { try? JSONSerialization.jsonObject(with: $0) }
        let items = contentValue.map {
            extractedContentItems(from: $0, maximumResults: maximumContentCount)
        } ?? []
        var object: [String: Any] = [
            "officialPlatform": providerType.rawValue,
            "target": OfficialPlatformEvidenceTarget.creator.rawValue,
            "requestedContentCount": maximumContentCount,
            "returnedContentCount": items.count,
            "creator": sanitized(creatorValue, depth: 0),
            "recentContentItems": items,
        ]
        if let contentValue,
           let context = extractedContentContext(from: contentValue) {
            object["contentContext"] = context
        }
        return try boundedEncodedEvidence(object)
    }

    private static func preferredTarget(
        for providerType: APIKeyProviderType,
        entry: EntryEvidence
    ) throws -> OfficialPlatformEvidenceTarget {
        if providerType == .tikTok {
            guard hasIdentifier(entry.entryID) else { throw OfficialPlatformEvidenceProtocolError.missingIdentifier }
            return .representativeEntry
        }
        guard hasIdentifier(entry.sourceID) else { throw OfficialPlatformEvidenceProtocolError.missingIdentifier }
        return .creator
    }

    private static func normalizedIdentifier(
        for providerType: APIKeyProviderType,
        target: OfficialPlatformEvidenceTarget,
        entry: EntryEvidence
    ) throws -> String {
        let raw = (target == .creator ? entry.sourceID : entry.entryID)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty, raw.count <= EntryEvidenceValidator.entryIDLimit else {
            throw OfficialPlatformEvidenceProtocolError.missingIdentifier
        }
        let platformPrefix: String
        switch providerType {
        case .youtubeData: platformPrefix = "youtube"
        case .tikTok: platformPrefix = "tiktok"
        case .facebookGraph: platformPrefix = "facebook"
        case .instagramGraph: platformPrefix = "instagram"
        case .twitch: platformPrefix = "twitch"
        case .reddit: platformPrefix = "reddit"
        case .xPlatform: platformPrefix = "twitter"
        default: platformPrefix = ""
        }
        var identifier = raw
        if !platformPrefix.isEmpty, identifier.hasPrefix("\(platformPrefix):") {
            identifier.removeFirst(platformPrefix.count + 1)
        }
        for kind in ["channel:", "handle:", "video:", "creator:", "user:", "account:", "subreddit:", "post:", "tweet:"] {
            if identifier.hasPrefix(kind) {
                identifier.removeFirst(kind.count)
                break
            }
        }
        identifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty, identifier.count <= EntryEvidenceValidator.entryIDLimit,
              !identifier.contains("/") || providerType == .reddit else {
            throw OfficialPlatformEvidenceProtocolError.invalidIdentifier
        }
        return identifier
    }

    private static func normalizedContentIdentifiers(
        for providerType: APIKeyProviderType,
        target: OfficialPlatformEvidenceTarget,
        entry: EntryEvidence,
        fallback: String,
        maximumResults: Int
    ) throws -> [String] {
        guard providerType == .tikTok, target == .representativeEntry else {
            return [fallback]
        }
        guard let text = entry.evidence.text,
              let data = text.data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return [fallback]
        }
        var seen = Set<String>()
        let identifiers = try items.compactMap { item -> String? in
            guard let raw = item["entryID"] as? String else { return nil }
            let candidate = EntryEvidence(
                platform: entry.platform,
                entryID: raw,
                sourceID: entry.sourceID,
                surface: entry.surface,
                evidence: .init(title: entry.evidence.title)
            )
            let identifier = try normalizedIdentifier(
                for: providerType,
                target: target,
                entry: candidate
            )
            return seen.insert(identifier).inserted ? identifier : nil
        }
        let bounded = Array(identifiers.prefix(min(maximumResults, 20)))
        return bounded.isEmpty ? [fallback] : bounded
    }

    private static func hasIdentifier(_ value: String?) -> Bool {
        !(value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    private static func baseURL(profile: APIKeyProviderProfile, descriptor: ProviderProtocolDescriptor) throws -> URL {
        let base = profile.customEndpoint?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? descriptor.defaultBaseURL
        guard let base,
              var components = URLComponents(string: base),
              components.scheme != nil,
              components.host != nil else {
            throw OfficialPlatformEvidenceProtocolError.invalidConfiguration
        }
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { throw OfficialPlatformEvidenceProtocolError.invalidConfiguration }
        return url
    }

    private struct Route {
        var method: String
        var path: [String]
        var queryItems: [URLQueryItem]
        var body: [String: Any]?
    }

    private static func prepareFollowUpRequest(
        profile: APIKeyProviderProfile,
        route: Route
    ) throws -> OfficialPlatformEvidencePreparedRequest {
        let descriptor = ProviderProtocolRegistry.descriptor(for: profile.type)
        guard !descriptor.supportsLLMConfiguration,
              descriptor.requestFormats.contains(where: { $0.operation == .readPublicContent }) else {
            throw OfficialPlatformEvidenceProtocolError.invalidConfiguration
        }
        try profile.validateForDispatch()
        let requestURL = try url(
            baseURL: baseURL(profile: profile, descriptor: descriptor),
            path: route.path,
            queryItems: route.queryItems
        )
        return .init(
            plan: .init(
                url: requestURL,
                method: route.method,
                bodyFormat: route.body == nil ? .queryOnly : .customJSON,
                headers: headers(profile: profile, descriptor: descriptor, hasBody: route.body != nil),
                authentication: descriptor.authentication,
                authenticationHeader: descriptor.authenticationHeader,
                requiredCredentialFields: descriptor.credentialFields
            ),
            target: .creator,
            providerType: profile.type,
            body: try route.body.map {
                try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys])
            }
        )
    }

    private static func jsonObject(from data: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OfficialPlatformEvidenceProtocolError.invalidResponse
        }
        return object
    }

    private static func responseIdentifier(
        in object: [String: Any],
        path: [String]
    ) throws -> String {
        var current: Any = object
        for component in path {
            if let dictionary = current as? [String: Any],
               let next = dictionary[component] {
                current = next
            } else if let array = current as? [Any],
                      let index = Int(component),
                      array.indices.contains(index) {
                current = array[index]
            } else {
                throw OfficialPlatformEvidenceProtocolError.invalidResponse
            }
        }
        guard let identifier = current as? String,
              !identifier.isEmpty,
              identifier.count <= EntryEvidenceValidator.entryIDLimit else {
            throw OfficialPlatformEvidenceProtocolError.invalidResponse
        }
        return identifier
    }

    private static func youtubeUploadsPlaylistID(from channelData: Data) throws -> String {
        guard channelData.count <= maximumResponseBytes else {
            throw OfficialPlatformEvidenceProtocolError.invalidResponse
        }
        let object = try jsonObject(from: channelData)
        guard let channel = (object["items"] as? [[String: Any]])?.first,
              let contentDetails = channel["contentDetails"] as? [String: Any],
              let relatedPlaylists = contentDetails["relatedPlaylists"] as? [String: Any],
              let playlistID = relatedPlaylists["uploads"] as? String,
              validYouTubeIdentifier(playlistID) else {
            throw OfficialPlatformEvidenceProtocolError.invalidResponse
        }
        return playlistID
    }

    private static func youtubeVideoIdentifiers(
        from playlistData: Data,
        maximumResults: Int
    ) throws -> [String] {
        guard playlistData.count <= maximumResponseBytes else {
            throw OfficialPlatformEvidenceProtocolError.invalidResponse
        }
        let object = try jsonObject(from: playlistData)
        guard let items = object["items"] as? [[String: Any]] else {
            throw OfficialPlatformEvidenceProtocolError.invalidResponse
        }
        var seen = Set<String>()
        return items.prefix(maximumResults).compactMap { item in
            guard let details = item["contentDetails"] as? [String: Any],
                  let identifier = details["videoId"] as? String,
                  validYouTubeIdentifier(identifier),
                  seen.insert(identifier).inserted else {
                return nil
            }
            return identifier
        }
    }

    private static func validYouTubeIdentifier(_ value: String) -> Bool {
        !value.isEmpty &&
            value.count <= 128 &&
            value.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
            }
    }

    private static func compactYouTubeChannel(from object: [String: Any]) -> [String: Any] {
        guard let channel = (object["items"] as? [[String: Any]])?.first else { return [:] }
        var compact: [String: Any] = [:]
        copyString("id", from: channel, to: &compact)
        if let snippet = channel["snippet"] as? [String: Any] {
            var compactSnippet: [String: Any] = [:]
            for key in ["title", "customUrl", "publishedAt", "country"] {
                copyString(key, from: snippet, to: &compactSnippet)
            }
            copyTrimmedString("description", maximum: 1_200, from: snippet, to: &compactSnippet)
            compact["snippet"] = compactSnippet
        }
        for key in [
            "brandingSettings", "contentDetails", "localizations",
            "statistics", "status", "topicDetails",
        ] {
            copyDictionary(key, from: channel, to: &compact)
        }
        return compact
    }

    private static func compactYouTubeVideos(
        from object: [String: Any]?,
        orderedIDs: [String],
        includeDescriptions: Bool,
        tagLimit: Int
    ) -> [[String: Any]] {
        let items = object?["items"] as? [[String: Any]] ?? []
        var byID = [String: [String: Any]]()
        for item in items {
            guard let identifier = item["id"] as? String,
                  validYouTubeIdentifier(identifier),
                  byID[identifier] == nil else {
                continue
            }
            byID[identifier] = item
        }
        return orderedIDs.compactMap { identifier -> [String: Any]? in
            guard let item = byID[identifier] else { return nil }
            var compact: [String: Any] = ["id": identifier]
            if let snippet = item["snippet"] as? [String: Any] {
                var compactSnippet: [String: Any] = [:]
                for key in [
                    "channelId", "channelTitle", "title", "publishedAt",
                    "categoryId", "defaultLanguage", "defaultAudioLanguage",
                    "liveBroadcastContent",
                ] {
                    copyString(key, from: snippet, to: &compactSnippet)
                }
                if includeDescriptions {
                    copyTrimmedString("description", maximum: 480, from: snippet, to: &compactSnippet)
                }
                if let tags = snippet["tags"] as? [String] {
                    compactSnippet["tags"] = tags.prefix(tagLimit).map { String($0.prefix(96)) }
                }
                compact["snippet"] = compactSnippet
            }
            for key in [
                "contentDetails", "statistics", "topicDetails",
                "recordingDetails", "liveStreamingDetails", "status",
                "paidProductPlacementDetails", "brandPartner",
            ] {
                copyDictionary(key, from: item, to: &compact)
            }
            if includeDescriptions,
               let localizations = item["localizations"] as? [String: Any] {
                let compactLocalizations: [String: [String: Any]] = Dictionary(
                    uniqueKeysWithValues: localizations.keys.sorted().prefix(4).compactMap { language -> (String, [String: Any])? in
                        guard let localization = localizations[language] as? [String: Any] else { return nil }
                        var value: [String: Any] = [:]
                        copyString("title", from: localization, to: &value)
                        copyTrimmedString("description", maximum: 240, from: localization, to: &value)
                        return (String(language.prefix(32)), value)
                    }
                )
                compact["localizations"] = compactLocalizations
            }
            return compact
        }
    }

    private static func compactYouTubeVideoCores(
        from object: [String: Any]?,
        orderedIDs: [String]
    ) -> [[String: Any]] {
        let items = object?["items"] as? [[String: Any]] ?? []
        var byID = [String: [String: Any]]()
        for item in items {
            guard let identifier = item["id"] as? String,
                  validYouTubeIdentifier(identifier),
                  byID[identifier] == nil else {
                continue
            }
            byID[identifier] = item
        }
        return orderedIDs.compactMap { identifier -> [String: Any]? in
            guard let item = byID[identifier] else { return nil }
            var compact: [String: Any] = ["id": identifier]
            if let snippet = item["snippet"] as? [String: Any] {
                for key in ["title", "publishedAt"] {
                    copyString(key, from: snippet, to: &compact)
                }
            }
            if let contentDetails = item["contentDetails"] as? [String: Any] {
                copyString("duration", from: contentDetails, to: &compact)
            }
            if let statistics = item["statistics"] as? [String: Any] {
                var compactStatistics: [String: Any] = [:]
                for key in ["viewCount", "likeCount", "commentCount"] {
                    copyString(key, from: statistics, to: &compactStatistics)
                }
                if !compactStatistics.isEmpty {
                    compact["statistics"] = compactStatistics
                }
            }
            return compact
        }
    }

    private static func copyString(
        _ key: String,
        from source: [String: Any],
        to destination: inout [String: Any]
    ) {
        if let value = source[key] as? String {
            destination[key] = String(value.prefix(1_024))
        }
    }

    private static func copyTrimmedString(
        _ key: String,
        maximum: Int,
        from source: [String: Any],
        to destination: inout [String: Any]
    ) {
        if let value = source[key] as? String {
            destination[key] = String(value.prefix(maximum))
        }
    }

    private static func copyDictionary(
        _ key: String,
        from source: [String: Any],
        to destination: inout [String: Any]
    ) {
        if let value = source[key] as? [String: Any] {
            destination[key] = sanitized(value, depth: 0)
        }
    }

    private static func encodedEvidence(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func extractedContentItems(
        from value: Any,
        maximumResults: Int
    ) -> [Any] {
        let rawItems: [Any]
        if let object = value as? [String: Any],
           let data = object["data"] {
            if let array = data as? [Any] {
                rawItems = array
            } else if let listing = data as? [String: Any],
                      let nestedItems = (listing["videos"] as? [Any])
                        ?? (listing["items"] as? [Any])
                        ?? (listing["children"] as? [Any]) {
                rawItems = nestedItems
            } else {
                rawItems = [data]
            }
        } else if let object = value as? [String: Any],
                  let items = object["items"] as? [Any] {
            rawItems = items
        } else if let array = value as? [Any] {
            rawItems = array
        } else {
            rawItems = [value]
        }
        return rawItems.prefix(maximumResults).map { sanitized($0, depth: 0) }
    }

    private static func extractedContentContext(from value: Any) -> Any? {
        guard var object = value as? [String: Any] else { return nil }
        object.removeValue(forKey: "data")
        object.removeValue(forKey: "items")
        guard !object.isEmpty else { return nil }
        return sanitized(object, depth: 0)
    }

    private static func boundedEncodedEvidence(_ initialObject: [String: Any]) throws -> String {
        var candidates = [(text: String, count: Int)]()
        if let fitted = fittedEvidence(initialObject) {
            candidates.append(fitted)
        }

        var compact = initialObject
        if let creator = compact["creator"] {
            compact["creator"] = sanitized(
                creator,
                depth: 0,
                maximumStringLength: 320,
                maximumArrayCount: 16,
                maximumDictionaryCount: 24,
                maximumDepth: 4
            )
        }
        if let context = compact["contentContext"] {
            compact["contentContext"] = sanitized(
                context,
                depth: 0,
                maximumStringLength: 320,
                maximumArrayCount: 16,
                maximumDictionaryCount: 24,
                maximumDepth: 4
            )
        }
        if let items = compact["recentContentItems"] as? [Any] {
            compact["recentContentItems"] = items.map {
                sanitized(
                    $0,
                    depth: 0,
                    maximumStringLength: 320,
                    maximumArrayCount: 16,
                    maximumDictionaryCount: 24,
                    maximumDepth: 4
                )
            }
        }
        if let fitted = fittedEvidence(compact) {
            candidates.append(fitted)
        }

        var core = compact
        for key in ["creator", "contentContext"] {
            if let value = core[key] {
                core[key] = sanitized(
                    value,
                    depth: 0,
                    maximumStringLength: 160,
                    maximumArrayCount: 8,
                    maximumDictionaryCount: 16,
                    maximumDepth: 3
                )
            }
        }
        if let items = core["recentContentItems"] as? [Any] {
            core["recentContentItems"] = items.map {
                sanitized(
                    $0,
                    depth: 0,
                    maximumStringLength: 160,
                    maximumArrayCount: 8,
                    maximumDictionaryCount: 16,
                    maximumDepth: 3
                )
            }
        }
        if let fitted = fittedEvidence(core) {
            candidates.append(fitted)
        }
        core.removeValue(forKey: "contentContext")
        if let fitted = fittedEvidence(core) {
            candidates.append(fitted)
        }

        guard var best = candidates.first else {
            throw OfficialPlatformEvidenceProtocolError.invalidResponse
        }
        for candidate in candidates.dropFirst() where candidate.count > best.count {
            best = candidate
        }
        return best.text
    }

    private static func fittedEvidence(_ initialObject: [String: Any]) -> (text: String, count: Int)? {
        var object = initialObject
        var items = object["recentContentItems"] as? [Any] ?? []
        while true {
            object["recentContentItems"] = items
            object["returnedContentCount"] = items.count
            if let text = encodedEvidence(object), text.count <= maximumEvidenceCharacters {
                return (text, items.count)
            }
            guard !items.isEmpty else { return nil }
            items.removeLast()
        }
    }

    private static func requestRoute(
        profile: APIKeyProviderProfile,
        target: OfficialPlatformEvidenceTarget,
        identifier: String,
        contentIdentifiers: [String]
    ) throws -> Route {
        func get(_ path: [String], _ queryItems: [URLQueryItem] = []) -> Route {
            .init(method: "GET", path: path, queryItems: queryItems, body: nil)
        }
        func post(_ path: [String], _ queryItems: [URLQueryItem], _ body: [String: Any]) -> Route {
            .init(method: "POST", path: path, queryItems: queryItems, body: body)
        }
        switch profile.type {
        case .youtubeData:
            if target == .representativeEntry {
                return get(["videos"], [.init(name: "part", value: "snippet,contentDetails,statistics"), .init(name: "id", value: identifier)])
            }
            let filter = identifier.hasPrefix("@")
                ? URLQueryItem(name: "forHandle", value: identifier)
                : URLQueryItem(name: "id", value: identifier)
            return get(
                ["channels"],
                [
                    .init(name: "part", value: "brandingSettings,contentDetails,localizations,snippet,statistics,status,topicDetails"),
                    filter,
                ]
            )
        case .twitch:
            return target == .representativeEntry
                ? get(["videos"], [.init(name: "id", value: identifier)])
                : get(["users"], [.init(name: "login", value: identifier)])
        case .reddit:
            if target == .representativeEntry {
                let fullname = identifier.hasPrefix("t3_") ? identifier : "t3_\(identifier)"
                return get(["api", "info"], [.init(name: "id", value: fullname), .init(name: "raw_json", value: "1")])
            }
            return get(["user", identifier, "about"], [.init(name: "raw_json", value: "1")])
        case .xPlatform:
            return target == .representativeEntry
                ? get(["tweets", identifier], [.init(name: "tweet.fields", value: "author_id,created_at,entities,public_metrics")])
                : get(
                    ["users", "by", "username", identifier],
                    [
                        .init(name: "user.fields", value: "affiliation,created_at,description,entities,id,is_identity_verified,location,most_recent_tweet_id,name,parody,pinned_tweet_id,profile_banner_url,profile_image_url,protected,public_metrics,subscription_type,url,username,verified,verified_followers_count,verified_type,withheld"),
                    ]
                )
        case .tikTok:
            guard target == .representativeEntry else { throw OfficialPlatformEvidenceProtocolError.unsupportedTarget }
            return post(
                ["video", "query"],
                [.init(name: "fields", value: "id,title,video_description,create_time,cover_image_url,share_url,duration,height,width,embed_link,like_count,comment_count,share_count,view_count")],
                ["filters": ["video_ids": contentIdentifiers]]
            )
        case .instagramGraph:
            let version = try metaAPIVersion(profile)
            return target == .representativeEntry
                ? get([version, identifier], [.init(name: "fields", value: "id,caption,media_type,permalink,timestamp,username")])
                : get([version, identifier], [.init(name: "fields", value: "id,username,biography,followers_count,media_count")])
        case .facebookGraph:
            let version = try metaAPIVersion(profile)
            return target == .representativeEntry
                ? get([version, identifier], [.init(name: "fields", value: "id,message,story,created_time,from,permalink_url")])
                : get([version, identifier], [.init(name: "fields", value: "id,name,about,description,fan_count")])
        default:
            throw OfficialPlatformEvidenceProtocolError.invalidConfiguration
        }
    }

    private static func connectionTestRoute(_ type: APIKeyProviderType, profile: APIKeyProviderProfile) throws -> Route {
        func get(_ path: [String], _ queryItems: [URLQueryItem] = []) -> Route {
            .init(method: "GET", path: path, queryItems: queryItems, body: nil)
        }
        func post(_ path: [String], _ queryItems: [URLQueryItem] = [], _ body: [String: Any]) -> Route {
            .init(method: "POST", path: path, queryItems: queryItems, body: body)
        }
        switch type {
        case .youtubeData:
            return get(["videos"], [.init(name: "part", value: "snippet"), .init(name: "id", value: "dQw4w9WgXcQ")])
        case .twitch:
            return get(["users"], [.init(name: "login", value: "twitch")])
        case .reddit:
            return get(["r", "all", "hot"], [.init(name: "limit", value: "1"), .init(name: "raw_json", value: "1")])
        case .xPlatform:
            return get(["users", "by", "username", "XDevelopers"])
        case .tikTok:
            return post(["video", "list"], [.init(name: "fields", value: "id")], ["max_count": 1])
        case .instagramGraph, .facebookGraph:
            let version = try metaAPIVersion(profile)
            return get([version, "me"], [.init(name: "fields", value: "id")])
        default:
            throw OfficialPlatformEvidenceProtocolError.invalidConfiguration
        }
    }

    private static func headers(profile: APIKeyProviderProfile, descriptor: ProviderProtocolDescriptor, hasBody: Bool) -> [String: String] {
        var headers = descriptor.staticHeaders
        headers["Accept"] = "application/json"
        if hasBody { headers["Content-Type"] = "application/json" }
        if profile.type == .twitch,
           let clientID = profile.protocolConfiguration[ProviderConfigurationField.clientID.rawValue] {
            headers["Client-Id"] = clientID
        }
        if profile.type == .reddit,
           let userAgent = profile.protocolConfiguration[ProviderConfigurationField.userAgent.rawValue] {
            headers["User-Agent"] = userAgent
        }
        return headers
    }

    private static func metaAPIVersion(_ profile: APIKeyProviderProfile) throws -> String {
        let version = profile.protocolConfiguration[ProviderConfigurationField.apiVersion.rawValue]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !version.isEmpty else { throw OfficialPlatformEvidenceProtocolError.invalidConfiguration }
        return version
    }

    private static func url(baseURL: URL, path: [String], queryItems: [URLQueryItem]) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw OfficialPlatformEvidenceProtocolError.invalidConfiguration
        }
        let basePath = components.percentEncodedPath.split(separator: "/").map(String.init)
        let encodedPath = (basePath + path.map(encodedPathComponent)).joined(separator: "/")
        components.percentEncodedPath = "/\(encodedPath)"
        components.queryItems = queryItems
        guard let url = components.url else { throw OfficialPlatformEvidenceProtocolError.invalidConfiguration }
        return url
    }

    private static func encodedPathComponent(_ value: String) -> String {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/%?#"))
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    private static func sanitized(
        _ value: Any,
        depth: Int,
        maximumStringLength: Int = 1_024,
        maximumArrayCount: Int = 64,
        maximumDictionaryCount: Int = 32,
        maximumDepth: Int = 5
    ) -> Any {
        guard depth < maximumDepth else { return "[truncated]" }
        if let dictionary = value as? [String: Any] {
            let secretNames = Set([
                "accesstoken", "refreshtoken", "token", "apikey",
                "clientsecret", "secret", "password", "authorization",
                "cookie", "setcookie",
            ])
            var sanitizedDictionary: [String: Any] = [:]
            for key in dictionary.keys.sorted().prefix(maximumDictionaryCount) {
                let normalizedKey = key.lowercased().filter(\.isLetter)
                guard !secretNames.contains(normalizedKey),
                      let value = dictionary[key] else {
                    continue
                }
                sanitizedDictionary[String(key.prefix(96))] = sanitized(
                    value,
                    depth: depth + 1,
                    maximumStringLength: maximumStringLength,
                    maximumArrayCount: maximumArrayCount,
                    maximumDictionaryCount: maximumDictionaryCount,
                    maximumDepth: maximumDepth
                )
            }
            return sanitizedDictionary
        }
        if let array = value as? [Any] {
            return array.prefix(maximumArrayCount).map {
                sanitized(
                    $0,
                    depth: depth + 1,
                    maximumStringLength: maximumStringLength,
                    maximumArrayCount: maximumArrayCount,
                    maximumDictionaryCount: maximumDictionaryCount,
                    maximumDepth: maximumDepth
                )
            }
        }
        if let text = value as? String { return String(text.prefix(maximumStringLength)) }
        if value is NSNull || value is NSNumber { return value }
        return String(describing: value).prefix(maximumStringLength).description
    }
}

public enum OfficialPlatformEvidenceProtocolError: Error, Equatable, LocalizedError, Sendable {
    case invalidConfiguration
    case missingIdentifier
    case invalidIdentifier
    case unsupportedTarget
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "This official platform API connection is not ready for creator evidence."
        case .missingIdentifier: return "The collected creator has no identifier for its official platform API evidence."
        case .invalidIdentifier: return "The collected creator identifier cannot be used with its official platform API."
        case .unsupportedTarget: return "This official platform API cannot retrieve the required creator evidence."
        case .invalidResponse: return "The official platform API returned an unreadable or oversized evidence response."
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
