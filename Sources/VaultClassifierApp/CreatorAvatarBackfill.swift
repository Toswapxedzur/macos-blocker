import Foundation
import VaultClassifierCore

/// Resolves a missing creator avatar only after the user explicitly requests
/// it. The request starts from a saved, platform-owned creator page and retains
/// just an allowlisted image URL; no page HTML or other metadata is persisted.
enum CreatorAvatarBackfill {
    static let maximumCandidates = 512
    private static let maximumHTMLBytes = 1_024 * 1_024
    private static let metadataSearchInterval = 32 * 1_024

    enum Source: Sendable {
        case cachedAvatarURL(String)
        case creatorPageURL(String)
        /// The caller may use a separately enabled, matching platform API
        /// after public-page discovery has no URL to start from.
        case unavailableCreatorPage
    }

    struct Candidate: Sendable {
        let platformID: String
        let creatorID: String
        let source: Source
    }

    static func candidates(
        entries: [CollectedPlatformEntry],
        allowedPlatformIDs: Set<String>,
        includeUnavailableCreatorPages: Bool = false
    ) -> [Candidate] {
        var candidatesByCreator = [String: Candidate]()
        let orderedEntries = entries.sorted { lhs, rhs in
            if lhs.lastObservedAtMilliseconds == rhs.lastObservedAtMilliseconds { return lhs.id < rhs.id }
            return lhs.lastObservedAtMilliseconds > rhs.lastObservedAtMilliseconds
        }

        for entry in orderedEntries {
            guard allowedPlatformIDs.contains(entry.platformID) else { continue }
            let key = "\(entry.platformID)\u{1F}\(entry.creatorID)"
            if case .cachedAvatarURL? = candidatesByCreator[key]?.source { continue }

            if let avatarURL = entry.attributes["creatorAvatarURL"],
               CreatorAvatarURLPolicy.isAccepted(platformID: entry.platformID, value: avatarURL) {
                candidatesByCreator[key] = Candidate(
                    platformID: entry.platformID,
                    creatorID: entry.creatorID,
                    source: .cachedAvatarURL(avatarURL)
                )
                continue
            }
            if let creatorPageURL = entry.attributes["creatorURL"],
               CreatorAvatarURLPolicy.isAcceptedCreatorPageURL(platformID: entry.platformID, value: creatorPageURL) {
                switch candidatesByCreator[key]?.source {
                case nil, .some(.unavailableCreatorPage):
                    candidatesByCreator[key] = Candidate(
                        platformID: entry.platformID,
                        creatorID: entry.creatorID,
                        source: .creatorPageURL(creatorPageURL)
                    )
                default:
                    break
                }
            } else if includeUnavailableCreatorPages, candidatesByCreator[key] == nil {
                candidatesByCreator[key] = Candidate(
                    platformID: entry.platformID,
                    creatorID: entry.creatorID,
                    source: .unavailableCreatorPage
                )
            }
        }

        return candidatesByCreator.values
            .sorted { lhs, rhs in
                if lhs.platformID == rhs.platformID { return lhs.creatorID < rhs.creatorID }
                return lhs.platformID < rhs.platformID
            }
            .prefix(maximumCandidates)
            .map { $0 }
    }

    static func resolveAvatarURL(for candidate: Candidate) async -> String? {
        switch candidate.source {
        case .cachedAvatarURL(let avatarURL):
            return avatarURL
        case .creatorPageURL(let creatorPageURL):
            return await discoverAvatarURL(
                creatorPageURL: creatorPageURL,
                platformID: candidate.platformID
            )
        case .unavailableCreatorPage:
            return nil
        }
    }

    static func avatarURL(
        in html: String,
        creatorPageURL: URL,
        platformID: String
    ) -> String? {
        let tagExpression = try? NSRegularExpression(pattern: #"<meta\b[^>]*>"#, options: [.caseInsensitive])
        let range = NSRange(html.startIndex..., in: html)
        for tagMatch in tagExpression?.matches(in: html, range: range) ?? [] {
            guard let tagRange = Range(tagMatch.range, in: html) else { continue }
            let attributes = htmlAttributes(in: String(html[tagRange]))
            let imageKind = (attributes["property"] ?? attributes["name"] ?? attributes["itemprop"] ?? "").lowercased()
            guard ["og:image", "twitter:image", "thumbnailurl"].contains(imageKind),
                  let content = attributes["content"],
                  let avatarURL = URL(string: unescapeHTML(content), relativeTo: creatorPageURL)?.absoluteURL.absoluteString,
                  CreatorAvatarURLPolicy.isAccepted(platformID: platformID, value: avatarURL) else {
                continue
            }
            return avatarURL
        }
        return nil
    }

    private static func discoverAvatarURL(creatorPageURL: String, platformID: String) async -> String? {
        guard CreatorAvatarURLPolicy.isAcceptedCreatorPageURL(platformID: platformID, value: creatorPageURL),
              let pageURL = URL(string: creatorPageURL) else {
            return nil
        }
        var request = URLRequest(url: pageURL)
        request.timeoutInterval = 12
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let redirectGuard = CreatorPageRedirectGuard(platformID: platformID)
        let session = URLSession(configuration: configuration, delegate: redirectGuard, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let finalURL = response.url,
                  CreatorAvatarURLPolicy.isAcceptedCreatorPageURL(platformID: platformID, value: finalURL.absoluteString),
                  http.value(forHTTPHeaderField: "Content-Type")?.lowercased().hasPrefix("text/html") == true else {
                return nil
            }
            var page = Data()
            var nextSearchLength = metadataSearchInterval
            for try await byte in bytes {
                page.append(byte)
                if page.count > maximumHTMLBytes { return nil }
                guard page.count >= nextSearchLength else { continue }
                nextSearchLength += metadataSearchInterval
                if let html = String(data: page, encoding: .utf8),
                   let avatarURL = avatarURL(in: html, creatorPageURL: finalURL, platformID: platformID) {
                    return avatarURL
                }
            }
            guard let html = String(data: page, encoding: .utf8) else { return nil }
            return avatarURL(in: html, creatorPageURL: finalURL, platformID: platformID)
        } catch {
            return nil
        }
    }

    private static func htmlAttributes(in tag: String) -> [String: String] {
        let expression = try? NSRegularExpression(
            pattern: #"\b([A-Za-z_:][-A-Za-z0-9_:.]*)\s*=\s*(?:\"([^\"]*)\"|'([^']*)'|([^\s\"'=<>`]+))"#,
            options: [.caseInsensitive]
        )
        var attributes = [String: String]()
        let range = NSRange(tag.startIndex..., in: tag)
        for match in expression?.matches(in: tag, range: range) ?? [] {
            guard let nameRange = Range(match.range(at: 1), in: tag) else { continue }
            let value = [2, 3, 4].compactMap { index -> String? in
                guard match.range(at: index).location != NSNotFound,
                      let valueRange = Range(match.range(at: index), in: tag) else {
                    return nil
                }
                return String(tag[valueRange])
            }.first
            if let value { attributes[String(tag[nameRange]).lowercased()] = value }
        }
        return attributes
    }

    private static func unescapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }
}

private final class CreatorPageRedirectGuard: NSObject, URLSessionTaskDelegate {
    private let platformID: String

    init(platformID: String) {
        self.platformID = platformID
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let redirectURL = request.url,
              CreatorAvatarURLPolicy.isAcceptedCreatorPageURL(platformID: platformID, value: redirectURL.absoluteString) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
