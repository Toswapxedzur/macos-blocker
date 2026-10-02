import Foundation

/// One periodic sample of "what is focused, and is the user active" — the input
/// the native app-usage feeder feeds the accumulator. `monotonic` is a
/// monotonic clock reading (e.g. `ProcessInfo.systemUptime`), never wall time.
public struct ActivitySample: Sendable {
    public var monotonic: Double
    public var wall: Date
    /// The focused app's stable key (bundle id), or nil when nothing is focused.
    public var appKey: String?
    public var appLabel: String
    /// True only when the user is active (not idle) and the screen is not
    /// locked/asleep. When false, no time accrues.
    public var active: Bool

    public init(monotonic: Double, wall: Date, appKey: String?, appLabel: String, active: Bool) {
        self.monotonic = monotonic
        self.wall = wall
        self.appKey = appKey
        self.appLabel = appLabel
        self.active = active
    }
}

/// Pure state machine that turns a stream of samples into `appUsage`
/// `ActivityRecord`s (see ACTIVITY-LOG.md §2). Kept AppKit-free so it is unit
/// testable; the AppKit sampling lives in `ActivityRecorderService`.
///
/// Time is credited to whichever app was focused during the interval between two
/// samples. Each between-sample step is capped (`maxStepSeconds`) so a gap from
/// system sleep or a suspended timer never dumps a huge bogus interval. When the
/// user goes inactive, the trailing partial interval is dropped rather than
/// guessed — a deliberate slight under-count, never an over-count.
public final class ActivityUsageAccumulator {
    private let maxStepSeconds: Double
    private let makeID: () -> String

    private var lastMonotonic: Double?
    private var bucketKey: String?
    private var bucketLabel: String = ""
    private var bucketSeconds: Double = 0
    private var bucketStartWall: Date = .distantPast

    public init(maxStepSeconds: Double = 60, makeID: @escaping () -> String = { UUID().uuidString }) {
        self.maxStepSeconds = maxStepSeconds
        self.makeID = makeID
    }

    /// Feed a sample; returns a completed record when a bucket closes (an app
    /// switch or a transition to inactive), otherwise nil.
    public func sample(_ sample: ActivitySample) -> ActivityRecord? {
        let elapsed = lastMonotonic.map { min(max(0, sample.monotonic - $0), maxStepSeconds) } ?? 0
        lastMonotonic = sample.monotonic

        guard sample.active, let key = sample.appKey else {
            return closeBucket()
        }

        if bucketKey == nil {
            openBucket(key: key, label: sample.appLabel, wall: sample.wall)
            return nil
        }

        // Credit the just-elapsed interval to the app that was focused during it.
        bucketSeconds += elapsed
        if key == bucketKey {
            bucketLabel = sample.appLabel
            return nil
        }
        let finished = closeBucket()
        openBucket(key: key, label: sample.appLabel, wall: sample.wall)
        return finished
    }

    /// Close and emit any open bucket (call on quit, lock, or sleep).
    public func flush() -> ActivityRecord? {
        closeBucket()
    }

    private func openBucket(key: String, label: String, wall: Date) {
        bucketKey = key
        bucketLabel = label
        bucketSeconds = 0
        bucketStartWall = wall
    }

    private func closeBucket() -> ActivityRecord? {
        defer {
            bucketKey = nil
            bucketSeconds = 0
        }
        guard let key = bucketKey, bucketSeconds > 0 else { return nil }
        return ActivityRecord(
            id: makeID(),
            category: .appUsage,
            startedAt: bucketStartWall,
            seconds: bucketSeconds,
            key: key,
            label: bucketLabel
        )
    }
}
