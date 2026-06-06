import Foundation

/// A snooze request recorded by the Shield Action extension when the user taps
/// the shield's secondary button. The main app reads and approves these
/// (subject to the group's snooze rules) the next time it runs.
public struct SnoozeRequest: Codable, Equatable, Sendable {
    public enum TargetKind: String, Codable, Sendable {
        case application
        case category
        case webDomain
        case unknown
    }

    public var id: String
    public var groupID: String?
    public var targetKind: TargetKind
    public var requestedAt: Date

    public init(
        id: String = UUID().uuidString,
        groupID: String? = nil,
        targetKind: TargetKind = .unknown,
        requestedAt: Date = Date()
    ) {
        self.id = id
        self.groupID = groupID
        self.targetKind = targetKind
        self.requestedAt = requestedAt
    }
}
