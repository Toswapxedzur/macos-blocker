import XCTest
@testable import MacBlockerCore

final class ActivityDashboardTests: XCTestCase {
    private func rec(_ key: String, at ms: Double, seconds: Double, label: String? = nil, platform: String? = nil) -> ActivityRecord {
        ActivityRecord(id: UUID().uuidString, category: .appUsage, startedAt: Date(timeIntervalSince1970: ms / 1000), seconds: seconds, key: key, label: label ?? key, platform: platform)
    }

    func testBarsAreRankedWithFractionOfLargest() {
        let bars = ActivityDashboard.bars(from: [
            rec("chrome", at: 0, seconds: 100), rec("chrome", at: 10, seconds: 50),
            rec("code", at: 0, seconds: 300),
        ])
        XCTAssertEqual(bars.map(\.key), ["code", "chrome"])
        XCTAssertEqual(bars[0].seconds, 300)
        XCTAssertEqual(bars[0].fraction, 1, accuracy: 1e-9)
        XCTAssertEqual(bars[1].seconds, 150)
        XCTAssertEqual(bars[1].fraction, 0.5, accuracy: 1e-9)
    }

    func testColorIndexIsStableAndDeterministicPerKey() {
        // Same key → same index across calls; ties a bar to its timeline segments.
        XCTAssertEqual(ActivityDashboard.colorIndex(for: "youtube.com"), ActivityDashboard.colorIndex(for: "youtube.com"))
        let bars = ActivityDashboard.bars(from: [rec("youtube.com", at: 0, seconds: 5)])
        let line = ActivityDashboard.timeline(from: [rec("youtube.com", at: 0, seconds: 5)], rangeStartMs: 0, rangeEndMs: 10000)
        XCTAssertEqual(bars[0].colorIndex, line[0].colorIndex)
        for i in 0..<ActivityDashboard.paletteSize {
            let idx = ActivityDashboard.colorIndex(for: "k\(i)")
            XCTAssertTrue((0..<ActivityDashboard.paletteSize).contains(idx))
        }
    }

    func testTimelinePositionsSegmentsWithinRange() {
        // range [1000, 11000] ms (10s span). A 2s session starting at +4s →
        // start 0.4, width 0.2.
        let line = ActivityDashboard.timeline(from: [rec("a", at: 5000, seconds: 2)], rangeStartMs: 1000, rangeEndMs: 11000)
        XCTAssertEqual(line.count, 1)
        XCTAssertEqual(line[0].startFraction, 0.4, accuracy: 1e-9)
        XCTAssertEqual(line[0].widthFraction, 0.2, accuracy: 1e-9)
        XCTAssertEqual(line[0].seconds, 2)
    }

    func testTimelineClampsToRangeAndDropsOutsideOrZero() {
        // one session straddling the end (clamped), one entirely before (dropped)
        let line = ActivityDashboard.timeline(
            from: [rec("in", at: 9000, seconds: 5), rec("before", at: 0, seconds: 1)],
            rangeStartMs: 1000, rangeEndMs: 11000
        )
        XCTAssertEqual(line.map(\.key), ["in"])
        XCTAssertEqual(line[0].startFraction, 0.8, accuracy: 1e-9)
        XCTAssertEqual(line[0].startFraction + line[0].widthFraction, 1.0, accuracy: 1e-9, "clamped to the range end")
    }

    func testTimelineIsChronological() {
        let line = ActivityDashboard.timeline(
            from: [rec("b", at: 8000, seconds: 1), rec("a", at: 2000, seconds: 1)],
            rangeStartMs: 0, rangeEndMs: 10000
        )
        XCTAssertEqual(line.map(\.key), ["a", "b"])
    }

    func testLensTotalIsSumOfSeconds() {
        let lens = ActivityDashboard.lens(from: [rec("a", at: 0, seconds: 30), rec("b", at: 1000, seconds: 70)], rangeStartMs: 0, rangeEndMs: 10000)
        XCTAssertEqual(lens.totalSeconds, 100)
        XCTAssertEqual(lens.bars.count, 2)
        XCTAssertEqual(lens.timeline.count, 2)
    }

    func testEmptyRangeYieldsNoGeometry() {
        XCTAssertTrue(ActivityDashboard.timeline(from: [rec("a", at: 0, seconds: 5)], rangeStartMs: 5000, rangeEndMs: 5000).isEmpty)
        XCTAssertTrue(ActivityDashboard.bars(from: []).isEmpty)
    }

    func testSnapshotSettingsViewMirrorsSettings() {
        var settings = ActivitySettings()
        settings.set(ActivityCategorySettings(enabled: true, retentionDays: 90), for: .webVisit)
        let view = ActivityDashboard.settingsView(settings)
        XCTAssertTrue(view.webVisit.enabled)
        XCTAssertEqual(view.webVisit.retentionDays, 90)
        XCTAssertFalse(view.appUsage.enabled)
    }
}
