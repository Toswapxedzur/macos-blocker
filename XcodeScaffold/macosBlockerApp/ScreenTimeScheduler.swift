import DeviceActivity
import Foundation
import MacBlockerCore

/// Registers DeviceActivity monitoring for each enabled group so the system
/// calls the DeviceActivityMonitor extension at the right times. The activity
/// name equals the group ID, which is how the extension knows which group's
/// targets to shield.
enum ScreenTimeScheduler {
    private static let center = DeviceActivityCenter()

    static func sync(with plan: EnforcementPlan) {
        // Replace all existing monitoring with the current plan.
        center.stopMonitoring()

        for entry in plan.entries where !entry.allTargetIDs.isEmpty {
            let activity = DeviceActivityName(entry.groupID)
            let schedule = makeSchedule(for: entry)

            do {
                if let threshold = entry.thresholdMinutes, threshold > 0 {
                    let eventName = DeviceActivityEvent.Name("\(entry.groupID).threshold")
                    let event = makeThresholdEvent(for: entry, minutes: threshold)
                    try center.startMonitoring(
                        activity,
                        during: schedule,
                        events: [eventName: event]
                    )
                } else {
                    try center.startMonitoring(activity, during: schedule)
                }
            } catch {
                // A malformed window or unauthorized target should not abort
                // the rest of the schedule sync.
                continue
            }
        }
    }

    private static func makeSchedule(for entry: EnforcementPlanEntry) -> DeviceActivitySchedule {
        // Use the first window when present; otherwise monitor all day. A fuller
        // build would create one activity per window.
        if let window = entry.windows.first {
            return DeviceActivitySchedule(
                intervalStart: DateComponents(hour: window.start.hour, minute: window.start.minute),
                intervalEnd: DateComponents(hour: window.end.hour, minute: window.end.minute),
                repeats: true
            )
        }
        return DeviceActivitySchedule(
            intervalStart: DateComponents(hour: 0, minute: 0),
            intervalEnd: DateComponents(hour: 23, minute: 59),
            repeats: true
        )
    }

    private static func makeThresholdEvent(
        for entry: EnforcementPlanEntry,
        minutes: Int
    ) -> DeviceActivityEvent {
        // Threshold events require tokens; the app passes them via the token
        // store. Here we leave the token sets empty and rely on the monitor
        // extension to shield from the plan. Populate these with the real
        // FamilyControls tokens for accurate per-app usage thresholds.
        DeviceActivityEvent(threshold: DateComponents(minute: minutes))
    }
}
