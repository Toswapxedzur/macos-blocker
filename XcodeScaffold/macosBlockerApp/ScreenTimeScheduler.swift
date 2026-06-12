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
            let schedules = makeSchedules(for: entry)

            for (windowIndex, schedule) in schedules.enumerated() {
                let suffix = schedules.count > 1 ? ".\(windowIndex)" : ""
                let activity = DeviceActivityName("\(entry.groupID)\(suffix)")

                do {
                    if let threshold = entry.thresholdMinutes, threshold > 0 {
                        let eventName = DeviceActivityEvent.Name("\(entry.groupID).threshold\(suffix)")
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
                    continue
                }
            }
        }
    }

    private static func makeSchedules(for entry: EnforcementPlanEntry) -> [DeviceActivitySchedule] {
        guard !entry.windows.isEmpty else {
            return [DeviceActivitySchedule(
                intervalStart: DateComponents(hour: 0, minute: 0),
                intervalEnd: DateComponents(hour: 23, minute: 59),
                repeats: true
            )]
        }
        return entry.windows.map { window in
            DeviceActivitySchedule(
                intervalStart: DateComponents(hour: window.start.hour, minute: window.start.minute),
                intervalEnd: DateComponents(hour: window.end.hour, minute: window.end.minute),
                repeats: true
            )
        }
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
