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
    case custom
    case app
    case category
}

public enum BlockingMode: String, Codable, Sendable {
    case instant
    case afterMinutes = "after-minutes"
    case timer

    public var isTimed: Bool {
        self == .afterMinutes || self == .timer
    }
}

public enum FreezeMode: String, Codable, Sendable {
    case none
    case normal
    case strict
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
    public var allowedMinutes: Int
    public var resetIntervalHours: Int
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
    public var fallbackMessage: String
    public var customRuleSource: String
    public var targets: [BlockTarget]
    public var unsupportedLegacyFeatures: [String]

    public init(
        id: String = UUID().uuidString,
        groupType: BlockGroupType = .site,
        name: String = "Block Group",
        enabled: Bool = true,
        mode: BlockingMode = .instant,
        allowedMinutes: Int = 15,
        resetIntervalHours: Int = 24,
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
        fallbackMessage: String = "",
        customRuleSource: String = "",
        targets: [BlockTarget] = [],
        unsupportedLegacyFeatures: [String] = []
    ) {
        self.id = id
        self.groupType = groupType
        self.name = name
        self.enabled = enabled
        self.mode = mode
        self.allowedMinutes = allowedMinutes
        self.resetIntervalHours = resetIntervalHours
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
        self.fallbackMessage = fallbackMessage
        self.customRuleSource = customRuleSource
        self.targets = targets
        self.unsupportedLegacyFeatures = unsupportedLegacyFeatures
    }
}
