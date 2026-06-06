import Foundation

public enum Weekday: String, Codable, CaseIterable, Sendable {
    case monday
    case tuesday
    case wednesday
    case thursday
    case friday
    case saturday
    case sunday

    public init(date: Date, calendar: Calendar = .current) {
        let weekday = calendar.component(.weekday, from: date)
        switch weekday {
        case 1: self = .sunday
        case 2: self = .monday
        case 3: self = .tuesday
        case 4: self = .wednesday
        case 5: self = .thursday
        case 6: self = .friday
        default: self = .saturday
        }
    }
}

public struct TimeOfDay: Codable, Equatable, Comparable, Sendable {
    public var hour: Int
    public var minute: Int

    public init(hour: Int, minute: Int) {
        self.hour = max(0, min(23, hour))
        self.minute = max(0, min(59, minute))
    }

    public var minutesSinceMidnight: Int {
        hour * 60 + minute
    }

    public static func < (lhs: TimeOfDay, rhs: TimeOfDay) -> Bool {
        lhs.minutesSinceMidnight < rhs.minutesSinceMidnight
    }
}

public struct TimeWindow: Codable, Equatable, Sendable {
    public var start: TimeOfDay
    public var end: TimeOfDay

    public init(start: TimeOfDay, end: TimeOfDay) {
        self.start = start
        self.end = end
    }

    public func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        let current = TimeOfDay(hour: hour, minute: minute).minutesSinceMidnight
        return current >= start.minutesSinceMidnight && current < end.minutesSinceMidnight
    }
}

public enum ScheduleParser {
    public static func parseWindows(_ text: String) -> [TimeWindow] {
        text
            .split(whereSeparator: \.isNewline)
            .compactMap { parseWindow(String($0)) }
    }

    public static func parseWindow(_ text: String) -> TimeWindow? {
        let cleaned = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ":", with: "")
        let parts = cleaned.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let start = parseTime(String(parts[0])),
              let end = parseTime(String(parts[1])),
              start < end
        else {
            return nil
        }
        return TimeWindow(start: start, end: end)
    }

    public static func parseTime(_ text: String) -> TimeOfDay? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count == 4,
              let hour = Int(value.prefix(2)),
              let minute = Int(value.suffix(2)),
              (0...23).contains(hour),
              (0...59).contains(minute)
        else {
            return nil
        }
        return TimeOfDay(hour: hour, minute: minute)
    }
}

public extension BlockGroup {
    func isActive(at date: Date, calendar: Calendar = .current) -> Bool {
        if groupType == .custom {
            return enabled
        }
        guard enabled else {
            return false
        }
        guard activeDays.contains(Weekday(date: date, calendar: calendar)) else {
            return false
        }
        guard !timeWindows.isEmpty else {
            return true
        }
        return timeWindows.contains { $0.contains(date, calendar: calendar) }
    }
}
