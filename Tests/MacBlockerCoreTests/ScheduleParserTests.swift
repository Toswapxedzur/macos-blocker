import XCTest
@testable import MacBlockerCore

final class ScheduleParserTests: XCTestCase {
    func testParsesTheEditorsWindowFormat() {
        // "09:00-10:30" (owner 2026-09-30), the older "HHMM-HHMM", "H:MM" and
        // an en dash, as the editor reads them.
        let windows = ScheduleParser.parseWindows(
            """
            09:00-10:30
            1200-1300
            9:05 \u{2013} 9:30
            """
        )

        XCTAssertEqual(windows.count, 3)
        XCTAssertEqual(windows[0].start, TimeOfDay(hour: 9, minute: 0))
        XCTAssertEqual(windows[0].end, TimeOfDay(hour: 10, minute: 30))
        XCTAssertEqual(windows[1].start, TimeOfDay(hour: 12, minute: 0))
        XCTAssertEqual(windows[2].start, TimeOfDay(hour: 9, minute: 5))
    }

    func testRejectsInvalidWindow() {
        XCTAssertNil(ScheduleParser.parseWindow("2500-2600"))
        XCTAssertNil(ScheduleParser.parseWindow("1200-1200"), "an empty window is invalid")
        XCTAssertNil(ScheduleParser.parseWindow("bad"))
        XCTAssertNil(ScheduleParser.parseWindow("9-10"), "minutes are required")
        XCTAssertNil(ScheduleParser.parseWindow("12:5-13:00"))
        XCTAssertNil(ScheduleParser.parseWindow("24:00-01:00"))
        XCTAssertNil(ScheduleParser.parseWindow("+1:00-02:00"))
    }

    func testParsesWindowCrossingMidnight() throws {
        let window = try XCTUnwrap(ScheduleParser.parseWindow("2300-0100"))
        XCTAssertTrue(window.crossesMidnight)
        XCTAssertFalse(try XCTUnwrap(ScheduleParser.parseWindow("0900-1000")).crossesMidnight)
    }

    /// Monday 2300-0100 belongs to Monday: it runs into Tuesday 01:00 even though
    /// Tuesday is not an active day, and a Sunday-night spill needs Sunday active.
    func testCrossMidnightWindowBelongsToStartDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        func at(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
        }
        // 2026-09-21 is a Monday.
        let group = BlockGroup(
            activeDays: [.monday],
            timeWindows: [try XCTUnwrap(ScheduleParser.parseWindow("2300-0100"))]
        )
        XCTAssertTrue(group.isActive(at: at(21, 23, 30), calendar: calendar), "Monday evening part")
        XCTAssertTrue(group.isActive(at: at(22, 0, 30), calendar: calendar), "Tuesday 00:30 belongs to Monday")
        XCTAssertFalse(group.isActive(at: at(22, 1, 0), calendar: calendar), "window ends at 01:00")
        XCTAssertFalse(group.isActive(at: at(22, 23, 30), calendar: calendar), "Tuesday is not active")
        XCTAssertFalse(group.isActive(at: at(21, 0, 30), calendar: calendar), "Sunday's spill needs Sunday active")
        XCTAssertFalse(group.isActive(at: at(21, 12, 0), calendar: calendar), "outside the window")
    }
}
