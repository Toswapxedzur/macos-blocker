import Foundation

public struct NamedPolicy: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var includeAnyTagIDs: [String]
    public var includeAllTagIDs: [String]
    public var excludeTagIDs: [String]
    public var feedAction: PresentationAction
    public var pageAction: PresentationAction

    public init(id: String, name: String, includeAnyTagIDs: [String] = [], includeAllTagIDs: [String] = [], excludeTagIDs: [String] = [], feedAction: PresentationAction = .dim, pageAction: PresentationAction = .block) {
        self.id = id
        self.name = name
        self.includeAnyTagIDs = includeAnyTagIDs
        self.includeAllTagIDs = includeAllTagIDs
        self.excludeTagIDs = excludeTagIDs
        self.feedAction = feedAction
        self.pageAction = pageAction == .dim ? .block : pageAction
    }
}

public enum StarterPolicies {
    public static let clashRoyale = NamedPolicy(
        id: "clash-royale-focus",
        name: "Clash Royale focus",
        includeAnyTagIDs: ["content.entities.clash-royale"],
        feedAction: .dim,
        pageAction: .block
    )
}
