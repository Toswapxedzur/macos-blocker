import Foundation

/// Render-ready geometry for the Activity dashboard (see docs/ACTIVITY-LOG.md).
/// Built in Swift and unit tested, so the web view only draws rectangles: a
/// ranked **bar graph** of totals per key, and a single **segmented timeline
/// bar** of the exact sessions across the range. `colorIndex` comes from the
/// store's permanent colour registry (owner rule 2026-09-29: every app and
/// website has one unique colour everywhere) and ties a key's bar to its
/// timeline segments; the page maps the index to a colour.

public struct ActivityBar: Codable, Equatable, Sendable {
    public var key: String
    public var label: String
    public var seconds: Double
    /// 0…1 of the largest bar, for the drawn length.
    public var fraction: Double
    public var colorIndex: Int
    public var platform: String?
}

public struct ActivitySegment: Codable, Equatable, Sendable {
    public var key: String
    public var label: String
    public var colorIndex: Int
    /// Position/width as 0…1 of the range span (the time axis).
    public var startFraction: Double
    public var widthFraction: Double
    public var startedAtMs: Double
    public var seconds: Double
}

/// One lens (app usage, or site usage): its total, the ranked bars, and the
/// chronological timeline segments.
public struct ActivityLensView: Codable, Equatable, Sendable {
    public var totalSeconds: Double
    public var bars: [ActivityBar]
    public var timeline: [ActivitySegment]
}

public struct ActivityDashboardSnapshot: Codable, Equatable, Sendable {
    public var rangeStartMs: Double
    public var rangeEndMs: Double
    public var app: ActivityLensView
    public var web: ActivityLensView
    /// Watched content as ranked bars (time per video), plus its title/platform.
    public var watched: [ActivityBar]
    public var settings: ActivityDashboardSettings
    /// The user's groups with their colours (a merge group stands in for its
    /// members on the page).
    public var groups: [ActivityGroupView]
}

/// One item's time (an app, a website, or all usage) per day, for the
/// 180-day map. Sessions are split at midnight, so a session across midnight
/// counts on both days.
public struct ActivityItemHistory: Codable, Equatable, Sendable {
    /// Local midnight of each day, oldest first, and that day's seconds.
    public var dayStartsMs: [Double]
    public var daySeconds: [Double]
}

/// One day of all usage for the day bars: its app and website sessions as
/// fractions of the day (a session across midnight is clipped into each day).
/// Segments carry the registry's colours, like the list.
public struct ActivityDayUsage: Codable, Equatable, Sendable {
    public var dayStartMs: Double
    public var app: [ActivitySegment]
    public var web: [ActivitySegment]
}

/// What the Activity Details panel asks for: the picked item's 180-day map and
/// the last few days of all usage.
public struct ActivityDetail: Codable, Equatable, Sendable {
    public var map: ActivityItemHistory
    public var days: [ActivityDayUsage]
}

/// A flat, web-friendly view of the settings the dashboard shows and edits.
public struct ActivityDashboardSettings: Codable, Equatable, Sendable {
    public struct Category: Codable, Equatable, Sendable {
        public var enabled: Bool
        /// Its own Keep; nil = follows the global one.
        public var retentionDays: Int?
    }
    public var appUsage: Category
    public var webVisit: Category
    public var contentWatched: Category
    /// The global Keep (days, 0 = forever).
    public var retentionDays: Int
}

public enum ActivityDashboard {
    /// Ranked bars (largest first) of total seconds per key; `colorFor` gives a
    /// key's colour (its rank is passed for items outside the registry).
    public static func bars(from records: [ActivityRecord], colorFor: (_ key: String, _ rank: Int) -> Int) -> [ActivityBar] {
        var totals: [String: (label: String, seconds: Double, platform: String?)] = [:]
        for record in records {
            let existing = totals[record.key]
            totals[record.key] = (record.label, (existing?.seconds ?? 0) + record.seconds, record.platform ?? existing?.platform)
        }
        let ranked = totals
            .map { (key: $0.key, label: $0.value.label, seconds: $0.value.seconds, platform: $0.value.platform) }
            .sorted { $0.seconds > $1.seconds }
        let maxSeconds = ranked.first?.seconds ?? 0
        return ranked.enumerated().map { index, item in
            ActivityBar(
                key: item.key,
                label: item.label,
                seconds: item.seconds,
                fraction: maxSeconds > 0 ? item.seconds / maxSeconds : 0,
                colorIndex: colorFor(item.key, index),
                platform: item.platform
            )
        }
    }

    /// Chronological timeline segments positioned within the range. Each record
    /// is one contiguous session (the recorder already merged samples), so a
    /// record maps to one segment. Fractions are clamped to the range. Segment
    /// colours come from `colorForKey` so they match the bar graph.
    public static func timeline(
        from records: [ActivityRecord],
        rangeStartMs: Double,
        rangeEndMs: Double,
        colorForKey: (String) -> Int
    ) -> [ActivitySegment] {
        let span = rangeEndMs - rangeStartMs
        guard span > 0 else { return [] }
        return records
            .sorted { $0.startedAt < $1.startedAt }
            .compactMap { record in
                let startMs = record.startedAt.timeIntervalSince1970 * 1000
                let widthMs = record.seconds * 1000
                let start = max(0, min(1, (startMs - rangeStartMs) / span))
                let end = max(0, min(1, (startMs + widthMs - rangeStartMs) / span))
                guard end > start else { return nil }
                return ActivitySegment(
                    key: record.key,
                    label: record.label,
                    colorIndex: colorForKey(record.key),
                    startFraction: start,
                    widthFraction: end - start,
                    startedAtMs: startMs,
                    seconds: record.seconds
                )
            }
    }

    public static func lens(from records: [ActivityRecord], rangeStartMs: Double, rangeEndMs: Double, colorFor: (String) -> Int) -> ActivityLensView {
        let bars = bars(from: records) { key, _ in colorFor(key) }
        var colorByKey: [String: Int] = [:]
        for bar in bars { colorByKey[bar.key] = bar.colorIndex }
        return ActivityLensView(
            totalSeconds: records.reduce(0) { $0 + $1.seconds },
            bars: bars,
            timeline: timeline(from: records, rangeStartMs: rangeStartMs, rangeEndMs: rangeEndMs) { colorByKey[$0] ?? colorFor($0) }
        )
    }

    /// The local midnights of the `days` days ending today, oldest first.
    public static func dayStarts(days: Int, now: Date, calendar: Calendar) -> [Date] {
        let today = calendar.startOfDay(for: now)
        return (0..<max(1, days)).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
    }

    /// The time `records` cover, overlaps counted once: one record per stretch
    /// (a group's app and a site inside it, or two members open at once, are
    /// one stretch of the group's time).
    public static func union(_ records: [ActivityRecord]) -> [ActivityRecord] {
        var stretches: [(start: Date, end: Date)] = []
        for record in records.sorted(by: { $0.startedAt < $1.startedAt }) {
            let end = record.startedAt.addingTimeInterval(record.seconds)
            if let last = stretches.last, record.startedAt <= last.end {
                stretches[stretches.count - 1].end = max(last.end, end)
            } else {
                stretches.append((record.startedAt, end))
            }
        }
        return stretches.enumerated().map { index, stretch in
            ActivityRecord(id: "union-\(index)", category: .appUsage, startedAt: stretch.start,
                           seconds: stretch.end.timeIntervalSince(stretch.start), key: "union", label: "union")
        }
    }

    /// Per-day totals of `records` for the `days` days ending today (local
    /// calendar), each session split at midnight.
    public static func history(records: [ActivityRecord], days: Int, now: Date, calendar: Calendar) -> ActivityItemHistory {
        let starts = dayStarts(days: days, now: now, calendar: calendar)
        var dayIndex: [Date: Int] = [:]
        for (index, start) in starts.enumerated() { dayIndex[start] = index }
        var daySeconds = [Double](repeating: 0, count: starts.count)
        for record in records {
            var cursor = record.startedAt
            let end = record.startedAt.addingTimeInterval(record.seconds)
            while cursor < end {
                let dayStart = calendar.startOfDay(for: cursor)
                guard let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) else { break }
                let chunkEnd = min(end, nextDay)
                if let index = dayIndex[dayStart] { daySeconds[index] += chunkEnd.timeIntervalSince(cursor) }
                cursor = chunkEnd
            }
        }
        return ActivityItemHistory(dayStartsMs: starts.map { $0.timeIntervalSince1970 * 1000 }, daySeconds: daySeconds)
    }

    /// The `days` days ending today, each with its app and website sessions
    /// placed within that day (see `timeline`).
    public static func dayUsage(
        app: [ActivityRecord],
        web: [ActivityRecord],
        days: Int,
        now: Date,
        calendar: Calendar,
        appColor: (String) -> Int,
        webColor: (String) -> Int
    ) -> [ActivityDayUsage] {
        dayStarts(days: days, now: now, calendar: calendar).map { start in
            let startMs = start.timeIntervalSince1970 * 1000
            let endMs = (calendar.date(byAdding: .day, value: 1, to: start) ?? start).timeIntervalSince1970 * 1000
            return ActivityDayUsage(
                dayStartMs: startMs,
                app: timeline(from: app, rangeStartMs: startMs, rangeEndMs: endMs, colorForKey: appColor),
                web: timeline(from: web, rangeStartMs: startMs, rangeEndMs: endMs, colorForKey: webColor)
            )
        }
    }

    public static func settingsView(_ settings: ActivitySettings) -> ActivityDashboardSettings {
        func category(_ category: ActivityCategory) -> ActivityDashboardSettings.Category {
            let value = settings.settings(for: category)
            return .init(enabled: value.enabled, retentionDays: value.retentionDays)
        }
        return ActivityDashboardSettings(
            appUsage: category(.appUsage),
            webVisit: category(.webVisit),
            contentWatched: category(.contentWatched),
            retentionDays: settings.retentionDays
        )
    }
}
