import Foundation

public struct RawWebSearchResult: Equatable, Sendable {
    public var title: String
    public var url: String
    public var snippet: String

    public init(title: String, url: String, snippet: String) {
        self.title = title
        self.url = url
        self.snippet = snippet
    }
}

/// Builds and parses only the fixed health request used to test a raw-search
/// provider profile. It never incorporates collected content.
public enum RawWebSearchProtocol {
    public static let maximumResults = 5
    public static let maximumQueryCharacters = 512
    public static let connectionTestQuery = "Example Domain site:example.com"

    public static func prepareConnectionTest(
        profile: APIKeyProviderProfile
    ) throws -> ProviderTestPreparedRequest {
        try prepare(profile: profile, query: connectionTestQuery, resultCount: 1)
    }

    public static func parseResults(
        _ data: Data,
        format: ProviderRequestBodyFormat
    ) throws -> [RawWebSearchResult] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RawWebSearchProtocolError.invalidResponse
        }
        let rawResults: [[String: Any]]
        switch format {
        case .serperSearch:
            rawResults = root["organic"] as? [[String: Any]] ?? []
        case .youSearch:
            let results = root["results"] as? [String: Any]
            let web = results?["web"] as? [[String: Any]] ?? []
            let news = results?["news"] as? [[String: Any]] ?? []
            rawResults = web + news
        default:
            throw RawWebSearchProtocolError.unsupportedProvider
        }

        let results = rawResults.compactMap { raw -> RawWebSearchResult? in
            let urlKey = format == .serperSearch ? "link" : "url"
            guard let title = boundedText(raw["title"], limit: 300),
                  let url = boundedPublicURL(raw[urlKey]) else {
                return nil
            }
            let snippet: String
            if format == .youSearch {
                let snippets = (raw["snippets"] as? [String] ?? [])
                    .compactMap { boundedText($0, limit: 1_000) }
                snippet = boundedText(snippets.joined(separator: " "), limit: 1_500)
                    ?? boundedText(raw["description"], limit: 1_500)
                    ?? ""
            } else {
                snippet = boundedText(raw["snippet"], limit: 1_500) ?? ""
            }
            return .init(title: title, url: url, snippet: snippet)
        }

        guard !results.isEmpty else { throw RawWebSearchProtocolError.noResults }
        return Array(results.prefix(maximumResults))
    }

    private static func prepare(
        profile: APIKeyProviderProfile,
        query: String,
        resultCount: Int = maximumResults
    ) throws -> ProviderTestPreparedRequest {
        let cleanedQuery = normalizedText(query)
        guard profile.type.supportsRawWebSearch,
              !cleanedQuery.isEmpty,
              cleanedQuery.count <= maximumQueryCharacters,
              resultCount > 0,
              resultCount <= maximumResults else {
            throw RawWebSearchProtocolError.unsupportedProvider
        }
        let descriptor = ProviderProtocolRegistry.descriptor(for: profile.type)
        let plan = try DescriptorBackedProviderProtocol(descriptor: descriptor).requestPlan(
            for: profile,
            operation: .searchWeb,
            modelIdentifier: nil
        )
        let body: Data
        switch plan.bodyFormat {
        case .serperSearch:
            body = try JSONSerialization.data(
                withJSONObject: ["q": cleanedQuery, "num": resultCount],
                options: [.sortedKeys]
            )
        case .youSearch:
            body = try JSONSerialization.data(
                withJSONObject: [
                    "query": cleanedQuery,
                    "count": resultCount,
                    "safesearch": "moderate",
                ],
                options: [.sortedKeys]
            )
        default:
            throw RawWebSearchProtocolError.unsupportedProvider
        }
        return .init(plan: plan, operation: .searchWeb, prompt: cleanedQuery, body: body)
    }

    private static func boundedText(_ value: Any?, limit: Int) -> String? {
        guard let value = value as? String else { return nil }
        let cleaned = normalizedText(value)
        return cleaned.isEmpty ? nil : String(cleaned.prefix(limit))
    }

    private static func boundedPublicURL(_ value: Any?) -> String? {
        guard let text = boundedText(value, limit: 2_048),
              var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false else {
            return nil
        }
        components.user = nil
        components.password = nil
        components.fragment = nil
        return components.url?.absoluteString
    }

    private static func normalizedText(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

public enum RawWebSearchProtocolError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedProvider
    case invalidResponse
    case noResults

    public var errorDescription: String? {
        switch self {
        case .unsupportedProvider:
            return "The selected connection does not support raw web search."
        case .invalidResponse:
            return "The web search provider returned an invalid response."
        case .noResults:
            return "The web search provider returned no usable results."
        }
    }
}
