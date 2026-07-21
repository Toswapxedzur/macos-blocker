import Foundation

/// The only arguments a language model may supply to a platform-data tool.
/// The identifier itself always comes from the already-validated local entry;
/// a model can never turn a tool call into an arbitrary URL or account lookup.
public enum ExternalPlatformToolTarget: String, Codable, Equatable, Sendable, CaseIterable {
    case entry
    case creator
}

/// A credential-free definition exposed to a language model. The profile ID is
/// local routing data; credentials remain in the native Keychain boundary.
public struct ExternalPlatformToolDefinition: Equatable, Sendable, Identifiable {
    public var profileID: String
    public var profileName: String
    public var providerType: APIKeyProviderType
    public var name: String
    public var description: String
    public var supportedTargets: [ExternalPlatformToolTarget]

    public var id: String { profileID }

    public init(
        profileID: String,
        profileName: String,
        providerType: APIKeyProviderType,
        name: String,
        description: String,
        supportedTargets: [ExternalPlatformToolTarget]
    ) {
        self.profileID = profileID
        self.profileName = profileName
        self.providerType = providerType
        self.name = name
        self.description = description
        self.supportedTargets = supportedTargets
    }
}

public struct ExternalPlatformToolCall: Equatable, Sendable {
    public var id: String
    public var name: String
    /// Provider-returned JSON. It is parsed again by the native executor and
    /// must be exactly `{ "target": "entry" | "creator" }`.
    public var arguments: String

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

public struct ExternalPlatformPreparedRequest: Equatable, Sendable {
    public var plan: ProviderRequestPlan
    public var target: ExternalPlatformToolTarget
    public var providerType: APIKeyProviderType
    public var body: Data?

    public init(plan: ProviderRequestPlan, target: ExternalPlatformToolTarget, providerType: APIKeyProviderType, body: Data? = nil) {
        self.plan = plan
        self.target = target
        self.providerType = providerType
        self.body = body
    }
}

public enum ExternalPlatformToolProtocol {
    public static let maximumToolDefinitions = 16
    public static let maximumToolResultCharacters = 12_000
    public static let maximumToolResponseBytes = 64 * 1_024

    /// Whether the reviewed platform protocol has a creator route that can
    /// return the creator-owned image field used by avatar backfill.
    public static func supportsCreatorAvatarLookup(providerType: APIKeyProviderType) -> Bool {
        switch providerType {
        case .youtubeData, .twitch, .reddit, .xPlatform, .instagramGraph, .facebookGraph:
            return true
        default:
            return false
        }
    }

    /// Builds every usable definition from explicitly attached platform
    /// profiles. Incomplete profiles are intentionally omitted: an LLM never
    /// sees a tool that the native layer cannot safely route.
    public static func definitions(
        profiles: [APIKeyProviderProfile],
        entry: EntryEvidence
    ) throws -> [ExternalPlatformToolDefinition] {
        try EntryEvidenceValidator().validate(entry)
        let profiles = Array(profiles.prefix(maximumToolDefinitions))
        return profiles.compactMap { profile in
            let descriptor = ProviderProtocolRegistry.descriptor(for: profile.type)
            guard !descriptor.supportsLLMConfiguration,
                  descriptor.requestFormats.contains(where: { $0.operation == .readPublicContent }),
                  (try? profile.validateForDispatch()) != nil else {
                return nil
            }
            let targets = availableTargets(entry: entry)
            guard !targets.isEmpty else { return nil }
            return .init(
                profileID: profile.id,
                profileName: profile.name,
                providerType: profile.type,
                name: toolName(for: profile),
                description: "Read bounded public \(profile.type.defaultProfileName) data for the existing local \(targets.map(\.rawValue).joined(separator: " or ")). The target must be entry or creator; never supply an ID, URL, query, or instruction.",
                supportedTargets: targets
            )
        }
    }

    public static func toolName(for profile: APIKeyProviderProfile) -> String {
        // Tool naming rules differ between providers, but ASCII letters,
        // digits, and underscores are accepted by every registered adapter.
        "vault_read_\(profile.type.rawValue)_\(stableIdentifier(for: profile.id))"
    }

    /// Prepares a constrained public-content request after a model asks for a
    /// declared tool. It cannot accept a model-provided destination or ID.
    public static func prepare(
        profile: APIKeyProviderProfile,
        entry: EntryEvidence,
        call: ExternalPlatformToolCall
    ) throws -> ExternalPlatformPreparedRequest {
        try EntryEvidenceValidator().validate(entry)
        let descriptor = ProviderProtocolRegistry.descriptor(for: profile.type)
        guard !descriptor.supportsLLMConfiguration,
              descriptor.requestFormats.contains(where: { $0.operation == .readPublicContent }),
              call.name == toolName(for: profile),
              call.id.count > 0, call.id.count <= 256,
              call.arguments.utf8.count <= 1_024 else {
            throw ExternalPlatformToolProtocolError.invalidCall
        }
        try profile.validateForDispatch()
        let target = try parseTarget(call.arguments, available: availableTargets(entry: entry))
        let identifier = try identifier(for: target, entry: entry)
        let baseURL = try baseURL(profile: profile, descriptor: descriptor)
        let route = try requestRoute(profile.type, target: target, identifier: identifier)
        let url = try url(baseURL: baseURL, path: route.path, queryItems: route.queryItems)
        var headers = descriptor.staticHeaders
        headers["Accept"] = "application/json"
        if route.body != nil { headers["Content-Type"] = "application/json" }
        if profile.type == .twitch, let clientID = profile.protocolConfiguration[ProviderConfigurationField.clientID.rawValue] {
            headers["Client-Id"] = clientID
        }
        if profile.type == .reddit, let userAgent = profile.protocolConfiguration[ProviderConfigurationField.userAgent.rawValue] {
            headers["User-Agent"] = userAgent
        }
        let body = try route.body.map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
        let plan = ProviderRequestPlan(
            url: url,
            method: route.method,
            bodyFormat: route.body == nil ? .queryOnly : .customJSON,
            headers: headers,
            authentication: descriptor.authentication,
            authenticationHeader: descriptor.authenticationHeader,
            requiredCredentialFields: descriptor.credentialFields
        )
        return .init(plan: plan, target: target, providerType: profile.type, body: body)
    }

    /// Produces a bounded, credential-free JSON result to return to the LLM.
    /// API error bodies are deliberately not relayed because they may contain
    /// provider-specific diagnostic data unrelated to classification.
    public static func result(
        data: Data,
        statusCode: Int,
        providerType: APIKeyProviderType,
        target: ExternalPlatformToolTarget
    ) -> String {
        guard (200..<300).contains(statusCode) else {
            return failureResult(providerType: providerType, target: target, message: "The platform API returned HTTP \(statusCode).")
        }
        guard data.count <= maximumToolResponseBytes,
              let value = try? JSONSerialization.jsonObject(with: data) else {
            return failureResult(providerType: providerType, target: target, message: "The platform API returned an unreadable or oversized response.")
        }
        let object: [String: Any] = [
            "ok": true,
            "platform": providerType.rawValue,
            "target": target.rawValue,
            "data": sanitized(value, depth: 0),
        ]
        guard let encoded = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: encoded, encoding: .utf8) else {
            return failureResult(providerType: providerType, target: target, message: "The platform response could not be normalized.")
        }
        return String(text.prefix(maximumToolResultCharacters))
    }

    public static func failureResult(
        providerType: APIKeyProviderType,
        target: ExternalPlatformToolTarget,
        message: String
    ) -> String {
        let object: [String: Any] = [
            "ok": false,
            "platform": providerType.rawValue,
            "target": target.rawValue,
            "error": String(message.prefix(512)),
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{\"ok\":false}".utf8)
        return String(data: data, encoding: .utf8) ?? "{\"ok\":false}"
    }

    /// Extracts the creator-owned profile image field from a bounded API
    /// response. The native caller must still apply its platform image-host
    /// allowlist before persisting or downloading the returned URL.
    public static func creatorAvatarURL(data: Data, providerType: APIKeyProviderType) -> String? {
        guard data.count <= maximumToolResponseBytes,
              let root = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        func value(_ object: Any?, path: [String]) -> String? {
            guard let key = path.first,
                  let dictionary = object as? [String: Any],
                  let next = dictionary[key] else {
                return nil
            }
            return path.count == 1 ? next as? String : value(next, path: Array(path.dropFirst()))
        }
        func firstValue(_ object: Any?, path: [String]) -> String? {
            guard let first = (object as? [String: Any])?["data"] as? [[String: Any]] else { return nil }
            return value(first.first, path: path)
        }
        let raw: String?
        switch providerType {
        case .youtubeData:
            guard let item = (root as? [String: Any])?["items"] as? [[String: Any]] else { return nil }
            raw = value(item.first, path: ["snippet", "thumbnails", "high", "url"])
                ?? value(item.first, path: ["snippet", "thumbnails", "medium", "url"])
                ?? value(item.first, path: ["snippet", "thumbnails", "default", "url"])
        case .twitch:
            raw = firstValue(root, path: ["profile_image_url"])
        case .reddit:
            raw = value(root, path: ["data", "icon_img"])
        case .xPlatform:
            raw = value(root, path: ["data", "profile_image_url"])
        case .instagramGraph:
            raw = value(root, path: ["profile_picture_url"])
        case .facebookGraph:
            raw = value(root, path: ["picture", "data", "url"])
        default:
            raw = nil
        }
        let cleaned = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func availableTargets(entry: EntryEvidence) -> [ExternalPlatformToolTarget] {
        var targets: [ExternalPlatformToolTarget] = []
        if entry.entryID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false { targets.append(.entry) }
        if entry.sourceID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false { targets.append(.creator) }
        return targets
    }

    private static func parseTarget(_ arguments: String, available: [ExternalPlatformToolTarget]) throws -> ExternalPlatformToolTarget {
        guard let data = arguments.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set(["target"]),
              let rawTarget = object["target"] as? String,
              let target = ExternalPlatformToolTarget(rawValue: rawTarget),
              available.contains(target) else {
            throw ExternalPlatformToolProtocolError.invalidCall
        }
        return target
    }

    private static func identifier(for target: ExternalPlatformToolTarget, entry: EntryEvidence) throws -> String {
        let identifier = (target == .entry ? entry.entryID : entry.sourceID)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !identifier.isEmpty, identifier.count <= EntryEvidenceValidator.entryIDLimit else {
            throw ExternalPlatformToolProtocolError.invalidCall
        }
        return identifier
    }

    private static func baseURL(profile: APIKeyProviderProfile, descriptor: ProviderProtocolDescriptor) throws -> URL {
        let base = profile.customEndpoint?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? descriptor.defaultBaseURL
        guard let base,
              var components = URLComponents(string: base),
              components.scheme != nil,
              components.host != nil else {
            throw ExternalPlatformToolProtocolError.invalidConfiguration
        }
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { throw ExternalPlatformToolProtocolError.invalidConfiguration }
        return url
    }

    private struct Route {
        var method: String
        var path: [String]
        var queryItems: [URLQueryItem]
        var body: [String: Any]?
    }

    private static func requestRoute(
        _ type: APIKeyProviderType,
        target: ExternalPlatformToolTarget,
        identifier: String
    ) throws -> Route {
        func get(_ path: [String], _ queryItems: [URLQueryItem] = []) -> Route {
            .init(method: "GET", path: path, queryItems: queryItems, body: nil)
        }
        func post(_ path: [String], _ queryItems: [URLQueryItem], _ body: [String: Any]) -> Route {
            .init(method: "POST", path: path, queryItems: queryItems, body: body)
        }
        switch type {
        case .youtubeData:
            return target == .entry
                ? get(["videos"], [.init(name: "part", value: "snippet,contentDetails,statistics"), .init(name: "id", value: identifier)])
                : get(["channels"], [.init(name: "part", value: "snippet,contentDetails,statistics"), .init(name: "id", value: identifier)])
        case .twitch:
            return target == .entry
                ? get(["videos"], [.init(name: "id", value: identifier)])
                : get(["users"], [.init(name: "id", value: identifier)])
        case .reddit:
            if target == .entry {
                let fullname = identifier.hasPrefix("t3_") ? identifier : "t3_\(identifier)"
                return get(["api", "info"], [.init(name: "id", value: fullname), .init(name: "raw_json", value: "1")])
            }
            return get(["user", identifier, "about"], [.init(name: "raw_json", value: "1")])
        case .xPlatform:
            return target == .entry
                ? get(["tweets", identifier], [.init(name: "tweet.fields", value: "author_id,created_at,entities,public_metrics")])
                : get(["users", identifier], [.init(name: "user.fields", value: "created_at,description,profile_image_url,public_metrics")])
        case .tikTok:
            guard target == .entry else { throw ExternalPlatformToolProtocolError.unsupportedTarget }
            // The Display API itself verifies that the requested video belongs
            // to the authorized user. The model still supplies no identifier:
            // this body contains only the already-collected entry ID.
            return post(
                ["video", "query"],
                [.init(name: "fields", value: "id,title,video_description,create_time,like_count,comment_count,share_count,view_count")],
                ["filters": ["video_ids": [identifier]]]
            )
        case .instagramGraph:
            return target == .entry
                ? get([identifier], [.init(name: "fields", value: "id,caption,media_type,permalink,timestamp,username")])
                : get([identifier], [.init(name: "fields", value: "id,username,biography,followers_count,media_count,profile_picture_url")])
        case .facebookGraph:
            return target == .entry
                ? get([identifier], [.init(name: "fields", value: "id,message,story,created_time,from,permalink_url")])
                : get([identifier], [.init(name: "fields", value: "id,name,about,description,fan_count,picture{url}")])
        default:
            throw ExternalPlatformToolProtocolError.invalidConfiguration
        }
    }

    private static func url(baseURL: URL, path: [String], queryItems: [URLQueryItem]) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ExternalPlatformToolProtocolError.invalidConfiguration
        }
        let basePath = components.percentEncodedPath.split(separator: "/").map(String.init)
        let encodedPath = (basePath + path.map(encodedPathComponent)).joined(separator: "/")
        components.percentEncodedPath = "/\(encodedPath)"
        components.queryItems = queryItems
        guard let url = components.url else { throw ExternalPlatformToolProtocolError.invalidConfiguration }
        return url
    }

    private static func encodedPathComponent(_ value: String) -> String {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/%?#"))
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    private static func stableIdentifier(for value: String) -> String {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(hash, radix: 16)
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

public enum ExternalPlatformToolProtocolError: Error, Equatable, LocalizedError, Sendable {
    case invalidCall
    case invalidConfiguration
    case unsupportedTarget

    public var errorDescription: String? {
        switch self {
        case .invalidCall: return "The model requested an invalid external-data tool call."
        case .invalidConfiguration: return "This external-data profile is not ready for a bounded request."
        case .unsupportedTarget: return "This platform API cannot read that local entry or creator identifier."
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
