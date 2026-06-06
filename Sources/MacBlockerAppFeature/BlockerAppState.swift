import Foundation
import MacBlockerCore

public struct BlockerAppState: Codable, Equatable, Sendable {
    public var groups: [BlockGroup]
    public var usage: UsageSnapshot
    public var selectedGroupID: String?
    public var selectedTargetID: String?
    public var logEntries: [PolicyApplicationLogEntry]

    public init(
        groups: [BlockGroup] = BlockerAppState.sampleGroups,
        usage: UsageSnapshot = UsageSnapshot(),
        selectedGroupID: String? = nil,
        selectedTargetID: String? = nil,
        logEntries: [PolicyApplicationLogEntry] = []
    ) {
        self.groups = groups
        self.usage = usage
        self.selectedGroupID = selectedGroupID ?? groups.first?.id
        self.selectedTargetID = selectedTargetID ?? groups.first?.targets.first?.id
        self.logEntries = logEntries
    }

    public static let sampleTargets: [BlockTarget] = [
        BlockTarget(
            id: "app.tiktok",
            kind: .application,
            displayName: "TikTok",
            normalizedValue: "com.zhiliaoapp.musically",
            tags: ["social", "shortVideo"]
        ),
        BlockTarget(
            id: "app.youtube",
            kind: .application,
            displayName: "YouTube",
            normalizedValue: "com.google.ios.youtube",
            tags: ["video", "shortVideo"]
        ),
        BlockTarget(
            id: "domain.reddit",
            kind: .webDomain,
            displayName: "reddit.com",
            normalizedValue: "reddit.com",
            tags: ["social"]
        )
    ]

    public static let sampleGroups: [BlockGroup] = [
        BlockGroup(
            id: "group-short-video",
            groupType: .app,
            name: "Short Video Budget",
            mode: .afterMinutes,
            allowedMinutes: 10,
            fallbackMessage: "Daily short-video limit reached.",
            targets: [sampleTargets[0], sampleTargets[1]]
        ),
        BlockGroup(
            id: "group-work-hours",
            groupType: .category,
            name: "Work Hours Social Block",
            mode: .instant,
            timeWindows: [
                TimeWindow(
                    start: TimeOfDay(hour: 9, minute: 0),
                    end: TimeOfDay(hour: 17, minute: 0)
                )
            ],
            fallbackMessage: "Focus time is active.",
            targets: [sampleTargets[0], sampleTargets[2]]
        ),
        BlockGroup(
            id: "group-custom",
            groupType: .custom,
            name: "Custom JS Policy",
            customRuleSource: """
            (event, helpers) => {
              event.registerUsageThresholdReached("custom-limit", (ev, h) => {
                ev.block("Blocked by custom JavaScript rule.");
                ev.setShieldMessage("Custom rule says: go back to work.");
              });

              event.registerScheduleChanged("status", (ev, h) => {
                h.overlay.show({
                  title: "Custom Status",
                  message: "This replaces the old in-page overlay.",
                  timerId: "custom-status"
                });
              });
            }
            """,
            targets: [sampleTargets[0]]
        )
    ]
}
