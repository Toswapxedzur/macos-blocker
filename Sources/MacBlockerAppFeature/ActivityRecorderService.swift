#if os(macOS)
import AppKit
import MacBlockerCore

/// Samples the focused app on a timer and feeds the pure
/// `ActivityUsageAccumulator`, writing `appUsage` records to the store.
/// See ACTIVITY-LOG.md §2/§5. Local-only; reads only the app's bundle id + name
/// (no window titles), so this needs no Accessibility or Screen-Recording grant.
///
/// Inactivity detection is intentionally OFF for now (owner decision
/// 2026-09-19): time accrues while an app is foreground + focused whether or not
/// the user is present. Accrual still stops naturally during system sleep (the
/// timer does not fire and the monotonic clock does not advance), and the
/// per-step cap bounds any gap. The `active` seam in the accumulator and the
/// `idleThresholdSeconds` setting are kept so the feature can return later.
public final class ActivityRecorderService {
    private let store: ActivityStore
    private let accumulator: ActivityUsageAccumulator
    private let tickInterval: TimeInterval

    private var timer: Timer?
    private var settings: ActivitySettings

    public init(store: ActivityStore, tickInterval: TimeInterval = 20) {
        self.store = store
        // A development override keeps the sample loop fast for testing.
        if let override = ProcessInfo.processInfo.environment["ADAMANCIA_VAULT_ACTIVITY_TICK_SECONDS"],
           let seconds = TimeInterval(override), seconds >= 1 {
            self.tickInterval = seconds
        } else {
            self.tickInterval = tickInterval
        }
        self.accumulator = ActivityUsageAccumulator(maxStepSeconds: self.tickInterval * 3)
        self.settings = store.loadSettings()
    }

    public func start() {
        store.prune(settings: settings)
        let timer = Timer(timeInterval: tickInterval, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        flush()
    }

    // MARK: - Sampling

    private func tick() {
        settings = store.loadSettings()
        guard settings.isEnabled(.appUsage) else {
            // Recording off: never accrue. Close any bucket opened before the
            // toggle flipped so nothing is silently lost, then stop.
            emit(accumulator.flush())
            return
        }
        let app = NSWorkspace.shared.frontmostApplication
        let sample = ActivitySample(
            monotonic: ProcessInfo.processInfo.systemUptime,
            wall: Date(),
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
