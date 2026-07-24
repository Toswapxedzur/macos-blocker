import Foundation

/// The local app, rather than a model, chooses the one official platform API
/// request that supplies fresh evidence for a creator classification.
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
    public static let maximumEvidenceCharacters = 12_000
    public static let maximumResponseBytes = 64 * 1_024

    /// Prepares the required, bounded API request for a creator
    /// classification. The model never controls the target, identifier, URL,
    /// query, headers, or request body.
    public static func prepare(
        profile: APIKeyProviderProfile,
        entry: EntryEvidence
    ) throws -> OfficialPlatformEvidencePreparedRequest {
        try EntryEvidenceValidator().validate(entry)
        let descriptor = ProviderProtocolRegistry.descriptor(for: profile.type)
        guard !descriptor.supportsLLMConfiguration,
              descriptor.requestFormats.contains(where: { $0.operation == .readPublicContent }) else {
            throw OfficialPlatformEvidenceProtocolError.invalidConfiguration
        }
        try profile.validateForDispatch()
        let target = try preferredTarget(for: profile.type, entry: entry)
        let identifier = try normalizedIdentifier(for: profile.type, target: target, entry: entry)
        let baseURL = try baseURL(profile: profile, descriptor: descriptor)
        let route = try requestRoute(profile: profile, target: target, identifier: identifier)
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

    /// Converts a successful API response to bounded, credential-free JSON
    /// for the classification prompt. It retains only public response data and
    /// strips common secret-bearing fields recursively.
    public static func boundedEvidence(
        data: Data,
        providerType: APIKeyProviderType,
        target: OfficialPlatformEvidenceTarget
    ) throws -> String {
        guard data.count <= maximumResponseBytes,
              let value = try? JSONSerialization.jsonObject(with: data) else {
            throw OfficialPlatformEvidenceProtocolError.invalidResponse
        }
        let object: [String: Any] = [
            "officialPlatform": providerType.rawValue,
            "target": target.rawValue,
            "data": sanitized(value, depth: 0),
        ]
        guard let encoded = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: encoded, encoding: .utf8) else {
            throw OfficialPlatformEvidenceProtocolError.invalidResponse
        }
        return String(text.prefix(maximumEvidenceCharacters))
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

    private static func requestRoute(
        profile: APIKeyProviderProfile,
        target: OfficialPlatformEvidenceTarget,
        identifier: String
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
            return get(["channels"], [.init(name: "part", value: "snippet,contentDetails,statistics"), filter])
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
                : get(["users", "by", "username", identifier], [.init(name: "user.fields", value: "created_at,description,public_metrics")])
        case .tikTok:
            guard target == .representativeEntry else { throw OfficialPlatformEvidenceProtocolError.unsupportedTarget }
            return post(
                ["video", "query"],
                [.init(name: "fields", value: "id,title,video_description,create_time,like_count,comment_count,share_count,view_count")],
                ["filters": ["video_ids": [identifier]]]
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

    private static func sanitized(_ value: Any, depth: Int) -> Any {
        guard depth < 5 else { return "[truncated]" }
        if let dictionary = value as? [String: Any] {
            let secretNames = Set(["access_token", "refresh_token", "token", "api_key", "client_secret", "secret", "password", "authorization", "cookie", "set-cookie"])
            var sanitizedDictionary: [String: Any] = [:]
            for key in dictionary.keys.sorted().prefix(32) where !secretNames.contains(key.lowercased()) {
                sanitizedDictionary[String(key.prefix(96))] = sanitized(dictionary[key] as Any, depth: depth + 1)
            }
            return sanitizedDictionary
        }
        if let array = value as? [Any] {
            return array.prefix(16).map { sanitized($0, depth: depth + 1) }
        }
        if let text = value as? String { return String(text.prefix(1_024)) }
        if value is NSNull || value is NSNumber { return value }
        return String(describing: value).prefix(1_024).description
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
