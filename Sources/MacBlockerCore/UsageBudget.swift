import Foundation

/// Budget-reset and rolling-window math for timed groups. Pure and
/// calendar-aware, shared by enforcement and display so they always agree
/// with each other and with the extension's copy of the same rules.
///
/// - Fixed budget: usage resets every `resetIntervalHours`, counted from the
///   group's anchor. With `resetAtMidnight`, the periods restart at local
///   00:00 each day instead (00:00, then every N hours; the last period of the
///   day ends early at midnight).
/// - Rolling limit: usage is kept per minute and counts until it is N hours
///   old; with `resetAtMidnight` the window never reaches before today's 00:00.
public enum UsageBudget {
    public static let bucketMs: Double = 60_000

    public static func intervalMs(_ group: BlockGroup) -> Double {
        max(0, group.resetIntervalHours) * 3_600_000
    }

    static func startOfDayMs(_ nowMs: Double, calendar: Calendar) -> Double {
        let now = Date(timeIntervalSince1970: nowMs / 1000)
        return calendar.startOfDay(for: now).timeIntervalSince1970 * 1000
    }

    static func nextMidnightMs(_ nowMs: Double, calendar: Calendar) -> Double {
        let start = calendar.startOfDay(for: Date(timeIntervalSince1970: nowMs / 1000))
        let next = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return next.timeIntervalSince1970 * 1000
    }

    // MARK: Fixed budget periods

    /// The start of the budget period containing `nowMs`. `anchorMs` is the
    /// stored period start; it only matters when midnight re-anchoring is off.
    public static func periodStartMs(anchorMs: Double, group: BlockGroup, nowMs: Double,
                                     calendar: Calendar = .current) -> Double {
        let interval = intervalMs(group)
        if group.resetAtMidnight {
            let dayStart = startOfDayMs(nowMs, calendar: calendar)
            guard interval > 0 else { return dayStart }
            return dayStart + floor((nowMs - dayStart) / interval) * interval
        }
        guard interval > 0, nowMs - anchorMs >= interval else { return anchorMs }
        return anchorMs + floor((nowMs - anchorMs) / interval) * interval
    }

    /// When the current fixed budget next resets, or nil when it never does.
    public static func nextResetMs(periodStartMs: Double, group: BlockGroup, nowMs: Double,
                                   calendar: Calendar = .current) -> Double? {
        let interval = intervalMs(group)
        if group.resetAtMidnight {
            let midnight = nextMidnightMs(nowMs, calendar: calendar)
            return interval > 0 ? min(periodStartMs + interval, midnight) : midnight
        }
        return interval > 0 ? periodStartMs + interval : nil
    }

    // MARK: Rolling window

    public static func bucketStartMs(_ nowMs: Double) -> Double {
        floor(nowMs / bucketMs) * bucketMs
    }

    /// Earliest instant still inside the rolling window.
    public static func windowStartMs(group: BlockGroup, nowMs: Double,
                                     calendar: Calendar = .current) -> Double {
        var start = nowMs - intervalMs(group)
        if group.resetAtMidnight {
            start = max(start, startOfDayMs(nowMs, calendar: calendar))
        }
        return start
    }

    /// Minute buckets still inside the window. A bucket counts until its whole
    /// minute has aged out.
    public static func pruneBuckets(_ buckets: [Double: Double], group: BlockGroup, nowMs: Double,
                                    calendar: Calendar = .current) -> [Double: Double] {
        let start = windowStartMs(group: group, nowMs: nowMs, calendar: calendar)
        return buckets.filter { $0.key + bucketMs > start && $0.value > 0 }
    }

    public static func usedMs(_ buckets: [Double: Double]) -> Double {
        buckets.values.reduce(0, +)
    }

    /// When the oldest counted minute leaves the window (or midnight clears
    /// it), i.e. when rolling time starts coming back. Nil with no usage.
    public static func nextReturnMs(_ buckets: [Double: Double], group: BlockGroup, nowMs: Double,
                                    calendar: Calendar = .current) -> Double? {
        guard let oldest = buckets.keys.min() else { return nil }
        var next = oldest + bucketMs + intervalMs(group)
        if group.resetAtMidnight {
            next = min(next, nextMidnightMs(nowMs, calendar: calendar))
        }
        return next
    }
}
