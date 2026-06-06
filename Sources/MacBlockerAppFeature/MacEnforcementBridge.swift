import Foundation
import MacBlockerCore
import MacBlockerWebUI
#if os(macOS)
import AppKit
import MacBlockerMacControl
#endif

/// Connects the web editor's saved groups to live macOS enforcement and the
/// floating timer HUD.
///
/// On a short repeating tick it:
///   1. samples the frontmost application and accrues "time spent" into timed
///      groups that target it (the macOS analogue of the extension's per-page
///      heartbeat), persisting usage to the shared store;
///   2. re-evaluates the groups against schedule + usage and enforces only what
///      should be blocked right now (so timer groups block exactly when their
///      budget runs out, never before);
///   3. renders the remaining time of any active timer in an always-on-top
///      overlay panel that floats over every app, including full-screen ones —
///      the native equivalent of the extension's on-page timer overlay.
///
/// Off macOS it is an inert holder for the shared `BlockerWebStore`.
@MainActor
public final class MacEnforcementBridge: ObservableObject {
    /// Shared store the editor persists into and we read groups back out of.
    public let webStore: BlockerWebStore

    #if os(macOS)
    private let adapter: EndpointSecurityPolicyAdapter
    private let sharedStore: SharedAppGroupStore
    private let evaluator = PolicyEvaluator()
    private let overlay = TimerOverlayPanelController()
    private var timer: Timer?
    private let tickInterval: TimeInterval
    private var lastSampleAt: Date?
    #endif

    public init(webStore: BlockerWebStore = BlockerWebStore(), sweepInterval: TimeInterval = 1.0) {
        self.webStore = webStore
        #if os(macOS)
        // The panel itself is the enforcer in this configuration, so the sweep
        // is enabled (unlike the editor's policy-publish-only adapter).
        self.adapter = EndpointSecurityPolicyAdapter(runTerminationSweep: true)
        self.sharedStore = SharedAppGroupStore()
        self.tickInterval = sweepInterval
        #endif
    }

    /// Re-evaluates immediately (e.g. right after an editor save).
    public func refresh() {
        #if os(macOS)
        tick()
        #endif
    }

    /// Begins enforcement: an initial evaluation plus a repeating tick that
    /// accrues usage, re-evaluates, enforces, and refreshes the timer HUD.
    public func start() {
        #if os(macOS)
        guard timer == nil else { return }
        lastSampleAt = Date()
        tick()
        let timer = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
        self.timer = timer
        #endif
    }

    public func stop() {
        #if os(macOS)
        timer?.invalidate()
        timer = nil
        lastSampleAt = nil
        overlay.hide()
        #endif
    }

    #if os(macOS)
    private func tick() {
        let now = Date()
        let groups = webStore.importedGroups()?.groups ?? []
        var usage = sharedStore.loadUsageSnapshot()
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        // 1. Accrue time spent in the frontmost app into the timed groups that
        //    target it (only while active + not snoozed). This is what makes a
        //    timer actually count down.
        let elapsed = elapsedSinceLastSample(now: now)
        lastSampleAt = now
        if let frontmost, elapsed > 0,
           accrueUsage(&usage, groups: groups, frontmost: frontmost, elapsed: elapsed, now: now) {
            sharedStore.saveUsageSnapshot(usage)
        }

        // 2. Enforce: block exactly the apps whose group says "blocked now".
        Task { [adapter] in
            try? await adapter.applyGroups(groups, usage: usage, now: now)
        }

        // 3. Render the HUD for any timer whose app is currently frontmost,
        //    matching the extension's scope-based overlay.
        let activeTargetIDs = matchingTargetIDs(groups: groups, frontmost: frontmost)
        let context = ActivityContext(
            now: now,
            target: nil,
            activeTargetIDs: activeTargetIDs,
            platform: .macOS
        )
        let result = evaluator.evaluate(groups: groups, usage: usage, context: context)
        let rows = result.visibleTimerItems.map {
            TimerOverlayRow(id: $0.groupID, name: $0.name, remainingSeconds: $0.remainingSeconds)
        }
        overlay.update(rows: rows)
    }

    private func elapsedSinceLastSample(now: Date) -> TimeInterval {
        guard let lastSampleAt else { return 0 }
        // Clamp so a sleep/suspend gap doesn't dump a huge chunk of "usage".
        return min(max(0, now.timeIntervalSince(lastSampleAt)), tickInterval * 4)
    }

    /// Returns true if any group's usage changed.
    private func accrueUsage(
        _ usage: inout UsageSnapshot,
        groups: [BlockGroup],
        frontmost: String,
        elapsed: TimeInterval,
        now: Date
    ) -> Bool {
        var changed = false
        for group in groups where group.enabled {
            guard group.mode == .timer || group.mode == .afterMinutes else { continue }
            guard group.isActive(at: now) else { continue }
            if usage.snoozesByGroup[group.id]?.phase(at: now) == .active { continue }
            let targetsFrontmost = group.targets.contains {
                $0.kind == .application && $0.id == frontmost
            }
            guard targetsFrontmost else { continue }
            usage.usageByGroupSeconds[group.id, default: 0] += elapsed
            changed = true
        }
        return changed
    }

    private func matchingTargetIDs(groups: [BlockGroup], frontmost: String?) -> Set<String> {
        guard let frontmost else { return [] }
        var ids: Set<String> = []
        for group in groups {
            for target in group.targets where target.kind == .application && target.id == frontmost {
                ids.insert(target.id)
            }
        }
        return ids
    }
    #endif
}
