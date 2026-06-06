import Foundation

public struct SnoozeState: Codable, Equatable, Sendable {
    public var startsAt: Date?
    public var until: Date?
    public var cooldownUntil: Date?
    public var justification: String

    public init(
        startsAt: Date? = nil,
        until: Date? = nil,
        cooldownUntil: Date? = nil,
        justification: String = ""
    ) {
        self.startsAt = startsAt
        self.until = until
        self.cooldownUntil = cooldownUntil
        self.justification = justification
    }

    public func phase(at date: Date) -> SnoozePhase {
        if let startsAt, date < startsAt {
            return .pending
        }
        if let until, date < until {
            return .active
        }
        if let cooldownUntil, date < cooldownUntil {
            return .cooldown
        }
        return .none
    }
}

public enum SnoozePhase: String, Codable, Sendable {
    case none
    case pending
    case active
    case cooldown
}

public struct UsageSnapshot: Codable, Equatable, Sendable {
    public var usageByGroupSeconds: [String: TimeInterval]
    public var resetAtByGroup: [String: Date]
    public var snoozesByGroup: [String: SnoozeState]
    public var totalSnoozedSecondsByGroup: [String: TimeInterval]

    public init(
        usageByGroupSeconds: [String: TimeInterval] = [:],
        resetAtByGroup: [String: Date] = [:],
        snoozesByGroup: [String: SnoozeState] = [:],
        totalSnoozedSecondsByGroup: [String: TimeInterval] = [:]
    ) {
        self.usageByGroupSeconds = usageByGroupSeconds
        self.resetAtByGroup = resetAtByGroup
        self.snoozesByGroup = snoozesByGroup
        self.totalSnoozedSecondsByGroup = totalSnoozedSecondsByGroup
    }
}

public struct ActivityContext: Codable, Equatable, Sendable {
    public var now: Date
    public var target: BlockTarget?
    public var activeTargetIDs: Set<String>
    public var usageByTargetSeconds: [String: TimeInterval]
    public var platform: RuntimePlatform

    public init(
        now: Date = Date(),
        target: BlockTarget? = nil,
        activeTargetIDs: Set<String> = [],
        usageByTargetSeconds: [String: TimeInterval] = [:],
        platform: RuntimePlatform
    ) {
        self.now = now
        self.target = target
        self.activeTargetIDs = activeTargetIDs
        self.usageByTargetSeconds = usageByTargetSeconds
        self.platform = platform
    }
}

public enum RuntimePlatform: String, Codable, Sendable {
    case iOS
    case iPadOS
    case macOS
}
