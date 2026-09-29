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

    func testColorsAreDistinctByRankAndMatchTimeline() {
        // Ranked colours: top items get distinct indices (the dot is a legend);
        // a key's bar and its timeline segment share the colour.
        let lens = ActivityDashboard.lens(
            from: [rec("code", at: 0, seconds: 300), rec("chrome", at: 1000, seconds: 100)],
            rangeStartMs: 0, rangeEndMs: 10000
        )
        XCTAssertEqual(lens.bars.map(\.colorIndex), [0, 1], "distinct colours by rank")
        let barColor = Dictionary(uniqueKeysWithValues: lens.bars.map { ($0.key, $0.colorIndex) })
        for segment in lens.timeline {
            XCTAssertEqual(segment.colorIndex, barColor[segment.key])
        }
    }

    func testColorsNeverRepeatPastTheBasePalette() {
        // 30 keys → 30 different colours (no wrap-around at 12).
        let records = (0..<30).map { rec("app\($0)", at: Double($0) * 10, seconds: Double(100 - $0)) }
        let bars = ActivityDashboard.bars(from: records)
        XCTAssertEqual(Set(bars.map(\.colorIndex)).count, 30)
    }

    func testSnapshotColoursAreUniqueAcrossAppsSitesAndWatched() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ActivityStore(directory: directory)
        var settings = store.loadSettings()
        for category in ActivityCategory.allCases {
            var value = settings.settings(for: category)
            value.enabled = true
            settings.set(value, for: category)
        }
        store.saveSettings(settings)
        let now = Date()
        func record(_ category: ActivityCategory, _ key: String) -> ActivityRecord {
            ActivityRecord(id: UUID().uuidString, category: category, startedAt: now.addingTimeInterval(-600), seconds: 60, key: key, label: key)
        }
        for item in [
            record(.appUsage, "com.google.Chrome"), record(.appUsage, "com.microsoft.VSCode"),
            record(.webVisit, "youtube.com"), record(.webVisit, "reddit.com"),
            record(.contentWatched, "youtube:abc"),
        ] {
            XCTAssertTrue(store.record(item))
        }
        let snapshot = store.dashboardSnapshot(from: now.addingTimeInterval(-3600), to: now)
        let all = snapshot.app.bars + snapshot.web.bars + snapshot.watched
        XCTAssertEqual(all.count, 5)
        XCTAssertEqual(Set(all.map(\.colorIndex)).count, 5, "no two items share a colour")
    }

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func iso(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    func testHistorySplitsSessionsAtMidnightAndHours() {
        // 23:30 → 00:45 next day: 30 min on the 28th (hour 23), 45 min on the 29th (hour 0).
        let session = ActivityRecord(id: "a", category: .appUsage, startedAt: iso("2026-09-28T23:30:00Z"), seconds: 75 * 60, key: "k", label: "k")
        let history = ActivityDashboard.history(records: [session], days: 3, hourDays: 2, now: iso("2026-09-29T12:00:00Z"), calendar: utc)
        XCTAssertEqual(history.dayStartsMs.count, 3)
        XCTAssertEqual(history.dayStartsMs.last, iso("2026-09-29T00:00:00Z").timeIntervalSince1970 * 1000)
        XCTAssertEqual(history.daySeconds, [0, 1800, 2700])
        XCTAssertEqual(history.hourDayStartsMs.count, 2)
        XCTAssertEqual(history.hourSeconds[0][23], 30 * 60)
        XCTAssertEqual(history.hourSeconds[1][0], 45 * 60)
        XCTAssertEqual(history.hourSeconds.flatMap { $0 }.reduce(0, +), 75 * 60)
    }

    func testHistoryIgnoresTimeBeforeItsDays() {
        let old = ActivityRecord(id: "a", category: .appUsage, startedAt: iso("2026-01-01T10:00:00Z"), seconds: 600, key: "k", label: "k")
        let history = ActivityDashboard.history(records: [old], days: 180, hourDays: 3, now: iso("2026-09-29T12:00:00Z"), calendar: utc)
        XCTAssertEqual(history.daySeconds.count, 180)
        XCTAssertEqual(history.daySeconds.reduce(0, +), 0)
    }

    func testStoreHistoryFollowsThePickedKey() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = iso("2026-09-29T12:00:00Z")
        let store = ActivityStore(directory: directory, now: { now }, calendar: utc)
        store.updateSettings { $0.setEnabled(true, for: .appUsage) }
        for (key, minutes) in [("chrome", 10.0), ("code", 20.0)] {
            XCTAssertTrue(store.record(ActivityRecord(id: key, category: .appUsage, startedAt: iso("2026-09-29T09:00:00Z"), seconds: minutes * 60, key: key, label: key)))
        }
        XCTAssertEqual(store.itemHistory(category: .appUsage, key: "code", days: 7, hourDays: 1).daySeconds.last, 20 * 60)
        XCTAssertEqual(store.itemHistory(category: .appUsage, key: nil, days: 7, hourDays: 1).daySeconds.last, 30 * 60)
        XCTAssertEqual(store.itemHistory(category: .appUsage, key: nil, days: 7, hourDays: 1).hourSeconds[0][9], 30 * 60)
    }

    func testTimelinePositionsSegmentsWithinRange() {
        // range [1000, 11000] ms (10s span). A 2s session starting at +4s →
        // start 0.4, width 0.2.
        let line = ActivityDashboard.timeline(from: [rec("a", at: 5000, seconds: 2)], rangeStartMs: 1000, rangeEndMs: 11000) { _ in 0 }
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
        ) { _ in 0 }
        XCTAssertEqual(line.map(\.key), ["in"])
        XCTAssertEqual(line[0].startFraction, 0.8, accuracy: 1e-9)
        XCTAssertEqual(line[0].startFraction + line[0].widthFraction, 1.0, accuracy: 1e-9, "clamped to the range end")
    }

    func testTimelineIsChronological() {
        let line = ActivityDashboard.timeline(
            from: [rec("b", at: 8000, seconds: 1), rec("a", at: 2000, seconds: 1)],
            rangeStartMs: 0, rangeEndMs: 10000
        ) { _ in 0 }
        XCTAssertEqual(line.map(\.key), ["a", "b"])
    }

    func testLensTotalIsSumOfSeconds() {
        let lens = ActivityDashboard.lens(from: [rec("a", at: 0, seconds: 30), rec("b", at: 1000, seconds: 70)], rangeStartMs: 0, rangeEndMs: 10000)
        XCTAssertEqual(lens.totalSeconds, 100)
        XCTAssertEqual(lens.bars.count, 2)
        XCTAssertEqual(lens.timeline.count, 2)
    }

    func testEmptyRangeYieldsNoGeometry() {
        XCTAssertTrue(ActivityDashboard.timeline(from: [rec("a", at: 0, seconds: 5)], rangeStartMs: 5000, rangeEndMs: 5000) { _ in 0 }.isEmpty)
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
