import Foundation

/// Mac Vault tells a rule group (custom) from a list group; what a list
/// group names is its Apps line.
public enum BlockGroupType: String, Codable, CaseIterable, Sendable {
    case site
    case custom
}

public enum BlockingMode: String, Codable, Sendable {
    case instant
    case afterMinutes = "after-minutes"

    public var isTimed: Bool {
        self == .afterMinutes
    }

    /// Reads a stored mode. Crash guard: the count-up "timer" mode was removed
    /// on 2026-09-25 (Activity tracks usage by itself); a group stored with it
    /// carries on as a normal timed group. Anything unknown is instant.
    public static func reconcile(_ raw: String?) -> BlockingMode {
        if let raw, let mode = BlockingMode(rawValue: raw) { return mode }
        return raw == "timer" ? .afterMinutes : .instant
    }
}

public struct BlockTarget: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case application
    }

    public var id: String
    public var kind: Kind
    public var displayName: String
    public var normalizedValue: String
    public var tags: Set<String>

    public init(
        id: String = UUID().uuidString,
        kind: Kind,
        displayName: String,
        normalizedValue: String,
        tags: Set<String> = []
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.normalizedValue = normalizedValue
        self.tags = tags
    }
}

public struct BlockGroup: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var groupType: BlockGroupType
    public var name: String
    public var enabled: Bool
    public var mode: BlockingMode
    public var allowedMinutes: Double
    /// Budget reset interval (fractional hours allowed, e.g. 2.5). Also the
    /// window length when `rollingLimit` is on.
    public var resetIntervalHours: Double
    /// Re-anchor the budget periods at local midnight every day (the last
    /// period of the day is cut short). With `rollingLimit`, midnight also
    /// clears the rolling window.
    public var resetAtMidnight: Bool
    /// Genuine sliding-window limit: used time counts until it is
    /// `resetIntervalHours` old, then comes back gradually.
    public var rollingLimit: Bool
    public var activeDays: Set<Weekday>
    public var timeWindows: [TimeWindow]
    public var customRuleSource: String
    public var targets: [BlockTarget]
    /// "Block every application except these": the group's application targets
    /// are the allowed ones; every other (non-protected, non-browser) app is
    /// blocked while the group blocks. Mirrors the website list's allowlist.
    public var applicationAllowlist: Bool

    public init(
        id: String = UUID().uuidString,
        groupType: BlockGroupType = .site,
        name: String = "Block Group",
        enabled: Bool = true,
        mode: BlockingMode = .instant,
        allowedMinutes: Double = 15,
        resetIntervalHours: Double = 24,
        resetAtMidnight: Bool = false,
        rollingLimit: Bool = false,
        activeDays: Set<Weekday> = Set(Weekday.allCases),
        timeWindows: [TimeWindow] = [],
        customRuleSource: String = "",
        targets: [BlockTarget] = [],
        applicationAllowlist: Bool = false
    ) {
        self.id = id
        self.groupType = groupType
        self.name = name
        self.enabled = enabled
        self.mode = mode
        self.allowedMinutes = allowedMinutes
        self.resetIntervalHours = resetIntervalHours
        self.resetAtMidnight = resetAtMidnight
        self.rollingLimit = rollingLimit
        self.activeDays = activeDays
        self.timeWindows = timeWindows
        self.customRuleSource = customRuleSource
        self.targets = targets
        self.applicationAllowlist = applicationAllowlist
    }
}

extension BlockGroup {
    /// The application ids on the Apps entry: the blocked ones, or with
    /// `applicationAllowlist` the allowed ones.
    public var applicationIDs: Set<String> {
        Set(targets.filter { $0.kind == .application }.map(\.id))
    }

    /// Whether an app list names `bundleID`: a listed app or one of its
    /// helpers (`<id>.…`), case-insensitively — the rule blocking matches by
    /// (GuardTarget), for counting time and for rules too.
    public static func lists(_ listed: Set<String>, _ bundleID: String) -> Bool {
        let id = bundleID.lowercased()
        return listed.contains { entry in
            let listed = entry.lowercased()
            return id == listed || id.hasPrefix(listed + ".")
        }
    }

    /// Whether time in the frontmost app counts toward this group's budget
    /// (and shows its timer). A blocklist counts its listed apps; "everything
    /// except" counts every app it would block, like the extension counts the
    /// sites outside a website allowlist. `exempt` marks an app no group can
    /// block (Apple, browsers, Vault itself); the caller knows those.
    public func countsApplication(_ bundleID: String, exempt: Bool) -> Bool {
        if applicationAllowlist {
            return !exempt && !Self.lists(applicationIDs, bundleID)
        }
        return Self.lists(applicationIDs, bundleID)
    }
}

public extension BlockGroup {
    /// On, inside its schedule and not snoozed: its rule runs and its time
    /// counts right now. The one "enforcing now" test for the Mac. A budget
    /// snooze keeps the group in effect (it raises the allowance instead).
    func isEnforcing(snoozes: [String: SnoozeState], at now: Date, calendar: Calendar = .current) -> Bool {
        isActive(at: now, calendar: calendar) && snoozes[id]?.exempts(at: now) != true
    }

    /// Allowance left in seconds, a running budget snooze's extra included;
    /// nil for an instant group.
    func remainingSeconds(usedSeconds: TimeInterval, extraSeconds: TimeInterval = 0) -> TimeInterval? {
        guard mode.isTimed else { return nil }
        return max(0, TimeInterval(max(0, allowedMinutes) * 60) + max(0, extraSeconds) - usedSeconds)
    }

    /// Enforcing, and instant or out of allowance: its lines block right now.
    func blocksNow(usage: UsageSnapshot, at now: Date, calendar: Calendar = .current) -> Bool {
        isEnforcing(snoozes: usage.snoozesByGroup, at: now, calendar: calendar)
            && (remainingSeconds(usedSeconds: usage.usageByGroupSeconds[id] ?? 0,
                                 extraSeconds: usage.snoozesByGroup[id]?.extraSeconds(at: now) ?? 0) ?? 0) <= 0
    }
}
