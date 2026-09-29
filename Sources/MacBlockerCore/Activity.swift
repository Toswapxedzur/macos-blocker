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
    /// Days of history to keep; `0` = keep forever; nil (the default) =
    /// follow the global Keep (owner 2026-09-29).
    public var retentionDays: Int?

    public init(enabled: Bool = false, retentionDays: Int? = nil) {
        self.enabled = enabled
        self.retentionDays = retentionDays.map { max(0, $0) }
    }
}

/// The user's Activity-log configuration. Category settings are keyed by raw
/// value so the JSON is a plain object (a `[ActivityCategory: _]` dictionary
/// would encode as an array under JSONEncoder).
public struct ActivitySettings: Codable, Equatable, Sendable {
    private var byCategory: [String: ActivityCategorySettings]
    /// Inactivity threshold in seconds. Reserved: idle detection is disabled for
    /// now (owner decision 2026-09-19), so this is stored but unused. Kept so the
    /// feature can return without a settings migration. Default 60.
    public var idleThresholdSeconds: Int
    /// The global Keep, in days (`0` = forever): every kind that doesn't set
    /// its own follows it, and so do watched videos' saved authors and tags.
    /// Default 180 — the day map shows 180 days (owner 2026-09-29: keep every
    /// detail; it is small).
    public var retentionDays: Int

    public init(
        categories: [ActivityCategory: ActivityCategorySettings] = [:],
        idleThresholdSeconds: Int = 60,
        retentionDays: Int = 180
    ) {
        var map: [String: ActivityCategorySettings] = [:]
        for category in ActivityCategory.allCases {
            map[category.rawValue] = categories[category] ?? ActivityCategorySettings()
        }
        self.byCategory = map
        self.idleThresholdSeconds = max(5, idleThresholdSeconds)
        self.retentionDays = max(0, retentionDays)
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
        if let global = try container.decodeIfPresent(Int.self, forKey: .retentionDays) {
            self.retentionDays = max(0, global)
        } else {
            // Saved before the global Keep: every kind follows it (default).
            self.retentionDays = 180
            for key in map.keys { byCategory[key]?.retentionDays = nil }
        }
    }

    /// The days a kind actually keeps: its own Keep, or the global one.
    public func effectiveRetentionDays(for category: ActivityCategory) -> Int {
        settings(for: category).retentionDays ?? retentionDays
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

/// A watched video's author (see `ActivityStore.watchedFacts`).
public struct ActivityAuthor: Codable, Equatable, Sendable {
    public var name: String
    /// A small image data URI, when one was found.
    public var icon: String?

    public init(name: String, icon: String?) {
        self.name = name
        self.icon = icon
    }
}

/// One of a watched video's tags, as the classifier named and coloured it.
public struct ActivityTag: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    /// "#rrggbb", or "" when the tag has no valid colour.
    public var color: String

    public init(id: String, name: String, color: String) {
        self.id = id
        self.name = name
        self.color = color
    }
}

/// What is saved about a watched video.
public struct ActivityWatchedFacts: Equatable, Sendable {
    public var author: ActivityAuthor?
    /// nil = none saved yet.
    public var tags: [ActivityTag]?
}

/// What a lookup found about one watched video, to save.
public struct ActivityWatchedEntry: Equatable, Sendable {
    public var videoKey: String
    /// The platform's own id for the author (stable across renames).
    public var authorID: String?
    public var authorName: String?
    public var authorIcon: String?
    public var tags: [ActivityTag]?

    public init(videoKey: String, authorID: String? = nil, authorName: String? = nil, authorIcon: String? = nil, tags: [ActivityTag]? = nil) {
        self.videoKey = videoKey
        self.authorID = authorID
        self.authorName = authorName
        self.authorIcon = authorIcon
        self.tags = tags
    }
}
