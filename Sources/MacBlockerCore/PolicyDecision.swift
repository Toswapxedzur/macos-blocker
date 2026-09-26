import Foundation

public enum PolicyAction: String, Codable, Sendable {
    case allow
    case shield
    case unshield
    case showStatus
    case requestSnooze
    case log
    case quarantine
}

public struct OverlayStatus: Codable, Equatable, Sendable {
    public var title: String
    public var message: String
    public var timerGroupID: String?
    public var expiresAt: Date?

    public init(
        title: String,
        message: String,
        timerGroupID: String? = nil,
        expiresAt: Date? = nil
    ) {
        self.title = title
        self.message = message
        self.timerGroupID = timerGroupID
        self.expiresAt = expiresAt
    }
}

public struct PolicyDecision: Codable, Equatable, Sendable {
    public var action: PolicyAction
    public var groupID: String?
    public var targetIDs: Set<String>
    public var reason: String
    public var shieldMessage: String
    public var overlayStatus: OverlayStatus?
    public var metadata: [String: String]

    public init(
        action: PolicyAction,
        groupID: String? = nil,
        targetIDs: Set<String> = [],
        reason: String = "",
        shieldMessage: String = "",
        overlayStatus: OverlayStatus? = nil,
        metadata: [String: String] = [:]
    ) {
        self.action = action
        self.groupID = groupID
        self.targetIDs = targetIDs
        self.reason = reason
        self.shieldMessage = shieldMessage
        self.overlayStatus = overlayStatus
        self.metadata = metadata
    }
}
