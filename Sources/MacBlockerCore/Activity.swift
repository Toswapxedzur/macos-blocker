import Foundation

/// The three overlapping lenses the Activity log records (see ACTIVITY-LOG.md).
/// Overlap is intended: watching a video in a browser produces one record in
/// each category at the same time, never deduplicated.
public enum ActivityCategory: String, Codable, CaseIterable, Sendable {
    /// Foreground + focused native app time (native feeder).
    case appUsage = "app-usage"
    /// Foreground + focused browser-tab time on a site, domain-level (extension).
    case webVisit = "web-visit"
    /// A piece of content actually watched on a supported platform (extension).
    case contentWatched = "content-watched"
}

/// One accrued interval or watched item. `seconds` is measured by the feeder on
/// a monotonic clock (never a wall-clock delta) and attributed to the local day
/// of `startedAt`. `id` is feeder-assigned so a replayed flush is idempotent.
public struct ActivityRecord: Codable, Equatable, Sendable {
    public var id: String
    public var category: ActivityCategory
    public var startedAt: Date
    public var seconds: Double
    /// The pie-slice dimension: app bundle id, domain, or `platform:contentID`.
    public var key: String
    /// Human label: app name, domain, or content title.
    public var label: String
    /// Only for `contentWatched`.
    public var platform: String?
    public var creator: String?

    public init(
        id: String,
        category: ActivityCategory,
        startedAt: Date,
        seconds: Double,
        key: String,
        label: String,
        platform: String? = nil,
        creator: String? = nil
    ) {
        self.id = id
        self.category = category
        self.startedAt = startedAt
        self.seconds = max(0, seconds)
        self.key = key
        self.label = label
        self.platform = platform
        self.creator = creator
    }
}

/// Per-category recording switch and retention window.
public struct ActivityCategorySettings: Codable, Equatable, Sendable {
    /// Default OFF — recording is opt-in (see ACTIVITY-LOG.md §3).
    public var enabled: Bool
    /// Days of history to keep; `0` = keep forever. Default 30.
    public var retentionDays: Int

    public init(enabled: Bool = false, retentionDays: Int = 30) {
        self.enabled = enabled
        self.retentionDays = max(0, retentionDays)
    }
}

/// The user's Activity-log configuration. Category settings are keyed by raw
/// value so the JSON is a plain object (a `[ActivityCategory: _]` dictionary
/// would encode as an array under JSONEncoder).
public struct ActivitySettings: Codable, Equatable, Sendable {
    private var byCategory: [String: ActivityCategorySettings]
    /// Inactivity threshold in seconds; below this much idle time, accrual runs.
    /// User-configurable. Default 60.
    public var idleThresholdSeconds: Int

    public init(
        categories: [ActivityCategory: ActivityCategorySettings] = [:],
        idleThresholdSeconds: Int = 60
    ) {
        var map: [String: ActivityCategorySettings] = [:]
        for category in ActivityCategory.allCases {
            map[category.rawValue] = categories[category] ?? ActivityCategorySettings()
        }
        self.byCategory = map
        self.idleThresholdSeconds = max(5, idleThresholdSeconds)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let stored = try container.decodeIfPresent([String: ActivityCategorySettings].self, forKey: .byCategory) ?? [:]
        var map: [String: ActivityCategorySettings] = [:]
        for category in ActivityCategory.allCases {
            map[category.rawValue] = stored[category.rawValue] ?? ActivityCategorySettings()
        }
        self.byCategory = map
        let idle = try container.decodeIfPresent(Int.self, forKey: .idleThresholdSeconds) ?? 60
        self.idleThresholdSeconds = max(5, idle)
    }

    public func settings(for category: ActivityCategory) -> ActivityCategorySettings {
        byCategory[category.rawValue] ?? ActivityCategorySettings()
    }

    public func isEnabled(_ category: ActivityCategory) -> Bool {
        settings(for: category).enabled
    }

    public mutating func set(_ value: ActivityCategorySettings, for category: ActivityCategory) {
        byCategory[category.rawValue] = value
    }

    public mutating func setEnabled(_ enabled: Bool, for category: ActivityCategory) {
        var value = settings(for: category)
        value.enabled = enabled
        byCategory[category.rawValue] = value
    }
}

/// An aggregated pie slice: total seconds against one key over a range.
public struct ActivityAggregate: Codable, Equatable, Sendable {
    public var key: String
    public var label: String
    public var seconds: Double

    public init(key: String, label: String, seconds: Double) {
        self.key = key
        self.label = label
        self.seconds = seconds
    }
}
