import Foundation

public protocol PolicyApplying {
    var capabilities: PlatformCapabilities { get }
    func apply(_ decisions: [PolicyDecision]) async throws
}

public enum PolicyApplicationError: Error, Equatable {
    case unauthorizedTarget(String)
    case unsupportedAction(PolicyAction)
    case missingPermission(String)
}

public struct PolicyApplicationLogEntry: Codable, Equatable, Sendable {
    public var date: Date
    public var action: PolicyAction
    public var groupID: String?
    public var message: String

    public init(
        date: Date = Date(),
        action: PolicyAction,
        groupID: String?,
        message: String
    ) {
        self.date = date
        self.action = action
        self.groupID = groupID
        self.message = message
    }
}
