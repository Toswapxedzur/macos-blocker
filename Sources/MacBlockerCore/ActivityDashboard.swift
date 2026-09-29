import Foundation

/// Render-ready geometry for the Activity dashboard (see docs/ACTIVITY-LOG.md).
/// Built in Swift and unit tested, so the web view only draws rectangles: a
/// ranked **bar graph** of totals per key, and a single **segmented timeline
/// bar** of the exact sessions across the range. `colorIndex` is unique per key
/// across the whole snapshot (apps, then sites, then watched videos — no two
/// items ever share a colour) and ties a key's bar to its timeline segments;
/// the page maps the index to a colour.

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
}

/// One item's time (an app, a website, or all usage) over recent days, for the
/// Activity detail charts: a total per day (the 180-day map) and per hour for
/// the last few days (the hour-by-hour bars). Sessions are split at day and
/// hour boundaries, so a session across midnight counts on both days.
public struct ActivityItemHistory: Codable, Equatable, Sendable {
    /// Local midnight of each day, oldest first, and that day's seconds.
    public var dayStartsMs: [Double]
    public var daySeconds: [Double]
    /// The last few days, oldest first: their midnights and 24 hourly totals each.
    public var hourDayStartsMs: [Double]
    public var hourSeconds: [[Double]]
}

/// A flat, web-friendly view of the settings the dashboard shows and edits.
public struct ActivityDashboardSettings: Codable, Equatable, Sendable {
    public struct Category: Codable, Equatable, Sendable {
        public var enabled: Bool
        public var retentionDays: Int
    }
    public var appUsage: Category
    public var webVisit: Category
    public var contentWatched: Category
}

public enum ActivityDashboard {
    /// Ranked bars (largest first) of total seconds per key. Colours go by rank,
    /// counting on from `firstColor`, so every key gets its own; a key's colour
    /// holds between its bar and its timeline segments.
    public static func bars(from records: [ActivityRecord], firstColor: Int = 0) -> [ActivityBar] {
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
                colorIndex: firstColor + index,
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

    public static func lens(from records: [ActivityRecord], rangeStartMs: Double, rangeEndMs: Double, firstColor: Int = 0) -> ActivityLensView {
        let bars = bars(from: records, firstColor: firstColor)
        var colorByKey: [String: Int] = [:]
        for bar in bars { colorByKey[bar.key] = bar.colorIndex }
        return ActivityLensView(
            totalSeconds: records.reduce(0) { $0 + $1.seconds },
            bars: bars,
            timeline: timeline(from: records, rangeStartMs: rangeStartMs, rangeEndMs: rangeEndMs) { colorByKey[$0] ?? firstColor }
        )
    }

    /// Splits `records` into per-day totals for the `days` days ending today and
    /// per-hour totals for the last `hourDays` of them (local calendar).
    public static func history(
        records: [ActivityRecord],
        days: Int,
        hourDays: Int,
        now: Date,
        calendar: Calendar
    ) -> ActivityItemHistory {
        let dayCount = max(1, days)
        let hourDayCount = max(1, min(hourDays, dayCount))
        let today = calendar.startOfDay(for: now)
        let dayStarts: [Date] = (0..<dayCount).reversed().compactMap {
            calendar.date(byAdding: .day, value: -$0, to: today)
        }
        var dayIndex: [Date: Int] = [:]
        for (index, start) in dayStarts.enumerated() { dayIndex[start] = index }
        var daySeconds = [Double](repeating: 0, count: dayStarts.count)
        let firstHourDay = dayStarts.count - hourDayCount
        var hourSeconds = [[Double]](repeating: [Double](repeating: 0, count: 24), count: hourDayCount)

        for record in records {
            var cursor = record.startedAt
            let end = record.startedAt.addingTimeInterval(record.seconds)
            while cursor < end {
                guard let hour = calendar.dateInterval(of: .hour, for: cursor) else { break }
                let chunkEnd = min(end, hour.end)
                let seconds = chunkEnd.timeIntervalSince(cursor)
                if let index = dayIndex[calendar.startOfDay(for: cursor)] {
                    daySeconds[index] += seconds
                    if index >= firstHourDay {
                        hourSeconds[index - firstHourDay][calendar.component(.hour, from: cursor)] += seconds
                    }
                }
                cursor = chunkEnd
            }
        }
        return ActivityItemHistory(
            dayStartsMs: dayStarts.map { $0.timeIntervalSince1970 * 1000 },
            daySeconds: daySeconds,
            hourDayStartsMs: dayStarts.suffix(hourDayCount).map { $0.timeIntervalSince1970 * 1000 },
            hourSeconds: hourSeconds
        )
    }

    public static func settingsView(_ settings: ActivitySettings) -> ActivityDashboardSettings {
        func category(_ category: ActivityCategory) -> ActivityDashboardSettings.Category {
            let value = settings.settings(for: category)
            return .init(enabled: value.enabled, retentionDays: value.retentionDays)
        }
        return ActivityDashboardSettings(
            appUsage: category(.appUsage),
            webVisit: category(.webVisit),
            contentWatched: category(.contentWatched)
        )
    }
}
