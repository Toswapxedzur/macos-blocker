import Foundation
import MacBlockerCore

public struct DeviceActivityScheduleRequest: Codable, Equatable, Sendable {
    public var groupID: String
    public var name: String
    public var weekdays: Set<Weekday>
    public var windows: [TimeWindow]
    public var thresholdMinutes: Int?

    public init(
        groupID: String,
        name: String,
        weekdays: Set<Weekday>,
        windows: [TimeWindow],
        thresholdMinutes: Int?
    ) {
        self.groupID = groupID
        self.name = name
        self.weekdays = weekdays
        self.windows = windows
        self.thresholdMinutes = thresholdMinutes
    }
}

public enum DeviceActivityRuleScheduler {
    public static func requests(for groups: [BlockGroup]) -> [DeviceActivityScheduleRequest] {
        groups
            .filter { $0.enabled }
            .filter { $0.groupType != .custom }
            .map {
                DeviceActivityScheduleRequest(
                    groupID: $0.id,
                    name: $0.name,
                    weekdays: $0.activeDays,
                    windows: $0.timeWindows,
                    thresholdMinutes: $0.mode.isTimed ? $0.allowedMinutes : nil
                )
            }
    }
}
