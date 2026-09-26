#if os(macOS)
import AppKit
import MacBlockerCore

/// Feeds the pure `ActivityUsageAccumulator` from the engine's own tick (the
/// same front app, the same second as the budgets count), writing `appUsage`
/// records to the store. See ACTIVITY-LOG.md §2/§5. Local-only; reads only the
/// app's bundle id + name (no window titles), so this needs no Accessibility or
/// Screen-Recording grant.
///
/// Inactivity detection is intentionally OFF for now (owner decision
/// 2026-09-19): time accrues while an app is foreground + focused whether or not
/// the user is present. Accrual still stops naturally during system sleep (no
/// tick fires and the monotonic clock does not advance), and the per-step cap
/// bounds any gap. The `active` seam in the accumulator and the
/// `idleThresholdSeconds` setting are kept so the feature can return later.
public final class ActivityRecorderService {
    private let store: ActivityStore
    private let accumulator: ActivityUsageAccumulator
    private var settings: ActivitySettings

    /// `maxStepSeconds` caps one gap between samples, as the engine caps its own.
    public init(store: ActivityStore, maxStepSeconds: TimeInterval) {
        self.store = store
        self.accumulator = ActivityUsageAccumulator(maxStepSeconds: maxStepSeconds)
        self.settings = store.loadSettings()
        store.prune(settings: settings)
    }

    public func stop() {
        flush()
    }

    // MARK: - Sampling

    /// One engine tick: credits the time since the last one to the front app.
    public func sample(frontmost app: NSRunningApplication?, now: Date) {
        settings = store.loadSettings()
        guard settings.isEnabled(.appUsage) else {
            // Recording off: never accrue. Close any bucket opened before the
            // toggle flipped so nothing is silently lost, then stop.
            emit(accumulator.flush())
            return
        }
        let sample = ActivitySample(
            monotonic: ProcessInfo.processInfo.systemUptime,
            wall: now,
            appKey: app?.bundleIdentifier,
            appLabel: app?.localizedName ?? app?.bundleIdentifier ?? "Unknown",
            active: true
        )
        emit(accumulator.sample(sample))
    }

    private func emit(_ record: ActivityRecord?) {
        guard let record else { return }
        store.record(record, settings: settings)
    }

    private func flush() { emit(accumulator.flush()) }
}
#endif
