import Foundation

/// A credential-free health request for one saved official platform API
/// profile. It intentionally includes no collected content or creator data.
public struct OfficialPlatformConnectionTestRequest: Equatable, Sendable {
    public var plan: ProviderRequestPlan
    public var body: Data?

    public init(plan: ProviderRequestPlan, body: Data? = nil) {
        self.plan = plan
        self.body = body
    }
}

/// Builds only the fixed health requests used by the API-key workspace. The
/// retired creator-classification evidence fetchers are deliberately absent.
public enum OfficialPlatformConnectionTestProtocol {
    public static func prepare(
        profile: APIKeyProviderProfile
    ) throws -> OfficialPlatformConnectionTestRequest {
        let descriptor = ProviderProtocolRegistry.descriptor(for: profile.type)
        guard !descriptor.supportsLLMConfiguration,
              descriptor.requestFormats.contains(where: { $0.operation == .readPublicContent }) else {
            throw OfficialPlatformConnectionTestProtocolError.invalidConfiguration
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

    private struct Route {
        var method: String
        var path: [String]
        var queryItems: [URLQueryItem]
        var body: [String: Any]?
    }

    private static func connectionTestRoute(
        _ type: APIKeyProviderType,
        profile: APIKeyProviderProfile
    ) throws -> Route {
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
            throw OfficialPlatformConnectionTestProtocolError.invalidConfiguration
        }
    }

    private static func baseURL(
        profile: APIKeyProviderProfile,
        descriptor: ProviderProtocolDescriptor
    ) throws -> URL {
        let custom = profile.customEndpoint?.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = custom?.isEmpty == false ? custom : descriptor.defaultBaseURL
        guard let base,
              var components = URLComponents(string: base),
              components.scheme != nil,
              components.host != nil else {
            throw OfficialPlatformConnectionTestProtocolError.invalidConfiguration
        }
        components.query = nil
        components.fragment = nil
        guard let url = components.url else {
            throw OfficialPlatformConnectionTestProtocolError.invalidConfiguration
        }
        return url
    }

    private static func headers(
        profile: APIKeyProviderProfile,
        descriptor: ProviderProtocolDescriptor,
        hasBody: Bool
    ) -> [String: String] {
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
        guard !version.isEmpty else {
            throw OfficialPlatformConnectionTestProtocolError.invalidConfiguration
        }
        return version
    }

    private static func url(
        baseURL: URL,
        path: [String],
        queryItems: [URLQueryItem]
    ) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw OfficialPlatformConnectionTestProtocolError.invalidConfiguration
        }
        let basePath = components.percentEncodedPath.split(separator: "/").map(String.init)
        components.percentEncodedPath = "/\((basePath + path.map(encodedPathComponent)).joined(separator: "/"))"
        components.queryItems = queryItems
        guard let url = components.url else {
            throw OfficialPlatformConnectionTestProtocolError.invalidConfiguration
        }
        return url
    }

    private static func encodedPathComponent(_ value: String) -> String {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/%?#"))
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}

public enum OfficialPlatformConnectionTestProtocolError: Error, Equatable, LocalizedError, Sendable {
    case invalidConfiguration

    public var errorDescription: String? {
        "This official platform API connection is not ready for a health check."
    }
}
