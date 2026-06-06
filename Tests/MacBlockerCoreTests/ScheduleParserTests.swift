import XCTest
@testable import MacBlockerCore

final class ScheduleParserTests: XCTestCase {
    func testParsesColonAndCompactWindows() {
        let windows = ScheduleParser.parseWindows(
            """
            09:00-10:30
            1200-1300
            """
        )

        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows[0].start, TimeOfDay(hour: 9, minute: 0))
        XCTAssertEqual(windows[0].end, TimeOfDay(hour: 10, minute: 30))
        XCTAssertEqual(windows[1].start, TimeOfDay(hour: 12, minute: 0))
        XCTAssertEqual(windows[1].end, TimeOfDay(hour: 13, minute: 0))
    }

    func testRejectsInvalidWindow() {
        XCTAssertNil(ScheduleParser.parseWindow("2500-2600"))
        XCTAssertNil(ScheduleParser.parseWindow("1300-1200"))
        XCTAssertNil(ScheduleParser.parseWindow("bad"))
    }
}
