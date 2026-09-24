import XCTest
@testable import MacBlockerCore

final class UsageBudgetTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func ms(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Double {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
            .timeIntervalSince1970 * 1000
    }

    private func group(hours: Double, midnight: Bool = false, rolling: Bool = false) -> BlockGroup {
        BlockGroup(mode: .afterMinutes, allowedMinutes: 15, resetIntervalHours: hours,
                   resetAtMidnight: midnight, rollingLimit: rolling)
    }

    // MARK: Fixed budget

    func testFixedIntervalDriftsWithoutMidnightReset() {
        let g = group(hours: 2.5)
        let start = UsageBudget.periodStartMs(anchorMs: ms(21, 22, 30), group: g, nowMs: ms(22, 3), calendar: calendar)
        XCTAssertEqual(start, ms(22, 1), "22:30 + 2.5 h = 01:00, carried across the day")
        XCTAssertEqual(UsageBudget.nextResetMs(periodStartMs: start, group: g, nowMs: ms(22, 3), calendar: calendar),
                       ms(22, 3, 30))
    }

    func testFixedIntervalIsUnchangedInsideAPeriod() {
        let g = group(hours: 2.5)
        XCTAssertEqual(UsageBudget.periodStartMs(anchorMs: ms(21, 10), group: g, nowMs: ms(21, 11), calendar: calendar),
                       ms(21, 10))
    }

    /// Owner's example: every 2.5 h re-anchored at midnight -> 00:00, 02:30 ...
    /// 22:30, and the last period of the day is only 1.5 h.
    func testMidnightResetRestartsTheGridAndShortensTheLastPeriod() {
        let g = group(hours: 2.5, midnight: true)
        let late = UsageBudget.periodStartMs(anchorMs: ms(21, 20), group: g, nowMs: ms(21, 23), calendar: calendar)
        XCTAssertEqual(late, ms(21, 22, 30))
        XCTAssertEqual(UsageBudget.nextResetMs(periodStartMs: late, group: g, nowMs: ms(21, 23), calendar: calendar),
                       ms(22, 0), "cut short at midnight (1.5 h)")
        let morning = UsageBudget.periodStartMs(anchorMs: ms(21, 22, 30), group: g, nowMs: ms(22, 3), calendar: calendar)
        XCTAssertEqual(morning, ms(22, 2, 30), "the grid restarts at 00:00, not 01:00")
    }

    func testMidnightResetWithFullDayIntervalResetsAtMidnight() {
        let g = group(hours: 24, midnight: true)
        let start = UsageBudget.periodStartMs(anchorMs: ms(21, 9), group: g, nowMs: ms(21, 15), calendar: calendar)
        XCTAssertEqual(start, ms(21, 0))
        XCTAssertEqual(UsageBudget.nextResetMs(periodStartMs: start, group: g, nowMs: ms(21, 15), calendar: calendar),
                       ms(22, 0))
    }

    // MARK: Rolling limit

    /// 5 min used at 09:00 and 10 min at 20:00 with a 24 h window: at 08:30 the
    /// next day all 15 min still count; by 09:30 the 09:00 minutes have come back.
    func testRollingWindowReturnsTimeGradually() {
        let g = group(hours: 24, rolling: true)
        let buckets: [Double: Double] = [ms(21, 9): 300_000, ms(21, 20): 600_000]

        let early = UsageBudget.pruneBuckets(buckets, group: g, nowMs: ms(22, 8, 30), calendar: calendar)
        XCTAssertEqual(UsageBudget.usedMs(early), 900_000)
        XCTAssertEqual(UsageBudget.nextReturnMs(early, group: g, nowMs: ms(22, 8, 30), calendar: calendar),
                       ms(22, 9, 1), "the 09:00 minute leaves the window at 09:01")

        let later = UsageBudget.pruneBuckets(buckets, group: g, nowMs: ms(22, 9, 30), calendar: calendar)
        XCTAssertEqual(UsageBudget.usedMs(later), 600_000)
    }

    func testRollingWindowIsClearedAtMidnightWhenCombined() {
        let g = group(hours: 24, midnight: true, rolling: true)
        let buckets: [Double: Double] = [ms(21, 20): 600_000]
        XCTAssertEqual(UsageBudget.usedMs(UsageBudget.pruneBuckets(buckets, group: g, nowMs: ms(21, 23), calendar: calendar)),
                       600_000)
        XCTAssertEqual(UsageBudget.nextReturnMs(buckets, group: g, nowMs: ms(21, 23), calendar: calendar),
                       ms(22, 0), "midnight clears before the minute would age out")
        XCTAssertEqual(UsageBudget.usedMs(UsageBudget.pruneBuckets(buckets, group: g, nowMs: ms(22, 1), calendar: calendar)),
                       0)
    }

    func testRollingWindowWithNoUsageHasNoReturnTime() {
        XCTAssertNil(UsageBudget.nextReturnMs([:], group: group(hours: 3, rolling: true), nowMs: ms(21, 9), calendar: calendar))
    }
}
