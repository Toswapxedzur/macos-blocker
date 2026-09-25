import Foundation

public enum BlockGroupType: String, Codable, CaseIterable, Sendable {
    case site
    case youtube
    case tiktok
    case facebook
    case instagram
    case twitch
    case reddit
    case discord
    case twitter
    case custom
    case app
    case category
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

public enum FreezeMode: String, Codable, Sendable {
    case none
    case normal
    case strict
    case parental
}

public struct BlockTarget: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case application
        case category
        case webDomain
        case urlPattern
        case legacyPlatform
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
    public var allowSnooze: Bool
    public var snoozeMinutes: Int
    public var snoozeActivationDelayMinutes: Int
    public var snoozeCooldownMinutes: Int
    public var snoozeConfirmations: Int
    public var activeDays: Set<Weekday>
    public var timeWindows: [TimeWindow]
    public var freezeMode: FreezeMode
    public var strictFreezeHours: Int
    public var frozenAt: Date?
    public var parentalPasswordHash: String?
    public var parentalPasswordSalt: String?
    public var fallbackMessage: String
    public var customRuleSource: String
    public var targets: [BlockTarget]
    /// "Block every application except these": the group's application targets
    /// are the allowed ones; every other (non-protected, non-browser) app is
    /// blocked while the group blocks. Mirrors the website list's allowlist.
    public var applicationAllowlist: Bool
    public var unsupportedLegacyFeatures: [String]

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
        allowSnooze: Bool = true,
        snoozeMinutes: Int = 30,
        snoozeActivationDelayMinutes: Int = 0,
        snoozeCooldownMinutes: Int = 0,
        snoozeConfirmations: Int = 0,
        activeDays: Set<Weekday> = Set(Weekday.allCases),
        timeWindows: [TimeWindow] = [],
        freezeMode: FreezeMode = .none,
        strictFreezeHours: Int = 24,
        frozenAt: Date? = nil,
        parentalPasswordHash: String? = nil,
        parentalPasswordSalt: String? = nil,
        fallbackMessage: String = "",
        customRuleSource: String = "",
        targets: [BlockTarget] = [],
        applicationAllowlist: Bool = false,
        unsupportedLegacyFeatures: [String] = []
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
        self.allowSnooze = allowSnooze
        self.snoozeMinutes = snoozeMinutes
        self.snoozeActivationDelayMinutes = snoozeActivationDelayMinutes
        self.snoozeCooldownMinutes = snoozeCooldownMinutes
        self.snoozeConfirmations = snoozeConfirmations
        self.activeDays = activeDays
        self.timeWindows = timeWindows
        self.freezeMode = freezeMode
        self.strictFreezeHours = strictFreezeHours
        self.frozenAt = frozenAt
        self.parentalPasswordHash = parentalPasswordHash
        self.parentalPasswordSalt = parentalPasswordSalt
        self.fallbackMessage = fallbackMessage
        self.customRuleSource = customRuleSource
        self.targets = targets
        self.applicationAllowlist = applicationAllowlist
        self.unsupportedLegacyFeatures = unsupportedLegacyFeatures
    }
}

extension BlockGroup {
    /// The application ids on the Apps entry: the blocked ones, or with
    /// `applicationAllowlist` the allowed ones.
    public var applicationIDs: Set<String> {
        Set(targets.filter { $0.kind == .application }.map(\.id))
    }

    /// Whether an "everything except" list allows `bundleID`: a listed app or
    /// one of its helpers (`<id>.…`), case-insensitively.
    public static func allowlist(_ allowed: Set<String>, allows bundleID: String) -> Bool {
        let id = bundleID.lowercased()
        return allowed.contains { entry in
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
            return !exempt && !Self.allowlist(applicationIDs, allows: bundleID)
        }
        return applicationIDs.contains(bundleID)
    }
}
