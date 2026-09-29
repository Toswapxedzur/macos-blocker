import Foundation

public struct SnoozeState: Codable, Equatable, Sendable {
    public var startsAt: Date?
    public var until: Date?
    public var cooldownUntil: Date?
    public var justification: String
    /// A budget snooze (group-actions.js, owner 2026-09-29): the seconds it
    /// adds to a time-limit group's allowance while it runs. Nil for a time
    /// snooze, which exempts the group instead.
    public var budgetExtra: TimeInterval?

    public init(
        startsAt: Date? = nil,
        until: Date? = nil,
        cooldownUntil: Date? = nil,
        justification: String = "",
        budgetExtra: TimeInterval? = nil
    ) {
        self.startsAt = startsAt
        self.until = until
        self.cooldownUntil = cooldownUntil
        self.justification = justification
        self.budgetExtra = budgetExtra
    }

    /// Whether it exempts its group right now: a running time snooze.
    public func exempts(at date: Date) -> Bool {
        budgetExtra == nil && phase(at: date) == .active
    }

    /// The allowance it adds right now: a running budget snooze's extra.
    public func extraSeconds(at date: Date) -> TimeInterval {
        guard let budgetExtra, phase(at: date) == .active else { return 0 }
        return max(0, budgetExtra)
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
    public var snoozesByGroup: [String: SnoozeState]

    public init(
        usageByGroupSeconds: [String: TimeInterval] = [:],
        snoozesByGroup: [String: SnoozeState] = [:]
    ) {
        self.usageByGroupSeconds = usageByGroupSeconds
        self.snoozesByGroup = snoozesByGroup
    }
}

