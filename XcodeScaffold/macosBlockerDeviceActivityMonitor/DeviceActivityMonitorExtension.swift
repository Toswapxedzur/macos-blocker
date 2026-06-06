import DeviceActivity
import Foundation
import MacBlockerCore
import MacBlockerScreenTime
import ManagedSettings

/// Runs under a tight memory budget, so it must NOT touch JavaScriptCore.
/// It only reads the precomputed `EnforcementPlan` + token set from the App
/// Group (written by the main app) and applies/clears shields. The activity
/// name equals the owning `BlockGroup.id` (see DeviceActivityRuleScheduler).
final class DeviceActivityMonitorExtension: DeviceActivityMonitor {
    private let enforcer = ScreenTimeEnforcer(storeName: "macosBlocker")
    private let sharedStore = SharedAppGroupStore()
    private let tokenStore = ScreenTimeTokenStore()

    override init() {
        // The extension and app must agree on the App Group identifier.
        AppGroup.identifier = AppGroupIdentifier.value
        super.init()
    }

    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)
        applyShield(forGroupID: activity.rawValue)
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
        // The schedule window closed: stop shielding this group.
        // (A per-store name keeps groups independent in a fuller build.)
        enforcer.clear()
        reapplyStillActiveGroups(excluding: activity.rawValue)
    }

    override func eventDidReachThreshold(
        _ event: DeviceActivityEvent.Name,
        activity: DeviceActivityName
    ) {
        super.eventDidReachThreshold(event, activity: activity)
        // A timed group used up its allowed minutes -> shield now.
        applyShield(forGroupID: activity.rawValue)
    }

    // MARK: Helpers

    private func applyShield(forGroupID groupID: String) {
        guard let plan = sharedStore.loadEnforcementPlan() else {
            return
        }
        // Respect an active snooze the app approved for this group.
        if isSnoozed(groupID: groupID) {
            return
        }
        let tokens = tokenStore.load()
        enforcer.applyShield(forGroupID: groupID, plan: plan, tokens: tokens)
    }

    private func isSnoozed(groupID: String, at date: Date = Date()) -> Bool {
        let usage = sharedStore.loadUsageSnapshot()
        return usage.snoozesByGroup[groupID]?.phase(at: date) == .active
    }

    /// After clearing for the ending activity, re-apply any other groups that
    /// are still active so they stay shielded.
    private func reapplyStillActiveGroups(excluding endingGroupID: String) {
        guard let plan = sharedStore.loadEnforcementPlan() else {
            return
        }
        let tokens = tokenStore.load()
        let now = Date()
        let stillActive = plan.entries.filter { entry in
            entry.groupID != endingGroupID
                && entry.mode == .instant
                && isWithinSchedule(entry, at: now)
                && !isSnoozed(groupID: entry.groupID, at: now)
        }
        for entry in stillActive {
            enforcer.applyShield(entry: entry, tokens: tokens)
        }
    }

    private func isWithinSchedule(_ entry: EnforcementPlanEntry, at date: Date) -> Bool {
        let calendar = Calendar.current
        guard entry.weekdays.contains(Weekday(date: date, calendar: calendar)) else {
            return false
        }
        guard !entry.windows.isEmpty else {
            return true
        }
        return entry.windows.contains { $0.contains(date, calendar: calendar) }
    }
}
