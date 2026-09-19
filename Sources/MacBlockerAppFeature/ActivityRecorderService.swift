#if os(macOS)
import AppKit
import CoreGraphics
import MacBlockerCore

/// Samples the focused app and the user's activity on a timer and feeds the
/// pure `ActivityUsageAccumulator`, writing `appUsage` records to the store.
/// See ACTIVITY-LOG.md §2/§5. Local-only; no window titles are read (only the
/// app's bundle id + name), so this needs no Accessibility or Screen-Recording
/// grant.
public final class ActivityRecorderService {
    private let store: ActivityStore
    private let accumulator: ActivityUsageAccumulator
    private let tickInterval: TimeInterval

    private var timer: Timer?
    private var settings: ActivitySettings
    private var isLocked = false
    private var isAsleep = false
    private var observers: [NSObjectProtocol] = []

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
        installObservers()
        let timer = Timer(timeInterval: tickInterval, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        for observer in observers { removeObserver(observer) }
        observers.removeAll()
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
        let idle = Self.systemIdleSeconds()
        let active = !isLocked && !isAsleep && idle < Double(settings.idleThresholdSeconds)
        let app = NSWorkspace.shared.frontmostApplication
        let sample = ActivitySample(
            monotonic: ProcessInfo.processInfo.systemUptime,
            wall: Date(),
            appKey: app?.bundleIdentifier,
            appLabel: app?.localizedName ?? app?.bundleIdentifier ?? "Unknown",
            active: active
        )
        emit(accumulator.sample(sample))
    }

    private func emit(_ record: ActivityRecord?) {
        guard let record else { return }
        store.record(record, settings: settings)
    }

    private func flush() { emit(accumulator.flush()) }

    /// Seconds since the last user input, system-wide. Needs no special
    /// permission and does not read what the user typed.
    private static func systemIdleSeconds() -> Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~UInt32(0))!)
    }

    // MARK: - Lock / sleep observers (accrual pauses; see ACTIVITY-LOG.md §2)

    private func installObservers() {
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.isAsleep = true; self?.flush()
        })
        observers.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.isAsleep = false
        })
        let dnc = DistributedNotificationCenter.default()
        observers.append(dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.isLocked = true; self?.flush()
        })
        observers.append(dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.isLocked = false
        })
    }

    private func removeObserver(_ observer: NSObjectProtocol) {
        NSWorkspace.shared.notificationCenter.removeObserver(observer)
        DistributedNotificationCenter.default().removeObserver(observer)
    }
}
#endif
