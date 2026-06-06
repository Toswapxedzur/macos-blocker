import Foundation
import MacBlockerCore
import MacBlockerScreenTime

/// Foreground refresh: approves pending shield snooze requests, re-syncs
/// DeviceActivity monitoring, and applies shields for currently-active,
/// non-snoozed groups. Call from the app's `.task`/scene-active handler.
enum ScreenTimeRefresher {
    static func refresh(now: Date = Date()) {
        let store = SharedAppGroupStore()
        processSnoozeRequests(store: store, now: now)

        guard let plan = store.loadEnforcementPlan() else { return }
        ScreenTimeScheduler.sync(with: plan)
        applyActiveShields(plan: plan, store: store, now: now)
    }

    private static func processSnoozeRequests(store: SharedAppGroupStore, now: Date) {
        let requests = store.loadSnoozeRequests()
        guard !requests.isEmpty else { return }

        let groups = importedGroups(store: store)
        let usage = store.loadUsageSnapshot()
        let processed = SnoozeApprovalService.process(
            requests: requests,
            groups: groups,
            usage: usage,
            now: now
        )
        store.saveUsageSnapshot(processed.usage)
        store.clearSnoozeRequests()
    }

    private static func applyActiveShields(
        plan: EnforcementPlan,
        store: SharedAppGroupStore,
        now: Date
    ) {
        let usage = store.loadUsageSnapshot()
        let tokens = ScreenTimeTokenStore().load()
        let calendar = Calendar.current

        let activeEntries = plan.entries.filter { entry in
            entry.mode == .instant
                && isWithinSchedule(entry, at: now, calendar: calendar)
                && usage.snoozesByGroup[entry.groupID]?.phase(at: now) != .active
        }

        ScreenTimeEnforcer().applyAll(
            plan: EnforcementPlan(generatedAt: now, entries: activeEntries),
            tokens: tokens
        )
    }

    private static func importedGroups(store: SharedAppGroupStore) -> [BlockGroup] {
        guard let data = store.readData(SharedAppGroupStore.webStoreFileName) else {
            return []
        }
        return (try? ChromeExtensionImporter.importGroups(from: data))?.groups ?? []
    }

    private static func isWithinSchedule(
        _ entry: EnforcementPlanEntry,
        at date: Date,
        calendar: Calendar
    ) -> Bool {
        guard entry.weekdays.contains(Weekday(date: date, calendar: calendar)) else {
            return false
        }
        guard !entry.windows.isEmpty else {
            return true
        }
        return entry.windows.contains { $0.contains(date, calendar: calendar) }
    }
}
