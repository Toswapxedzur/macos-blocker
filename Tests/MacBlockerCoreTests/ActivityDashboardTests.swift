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
        ]) { _, rank in rank }
        XCTAssertEqual(bars.map(\.key), ["code", "chrome"])
        XCTAssertEqual(bars[0].seconds, 300)
        XCTAssertEqual(bars[0].fraction, 1, accuracy: 1e-9)
        XCTAssertEqual(bars[1].seconds, 150)
        XCTAssertEqual(bars[1].fraction, 0.5, accuracy: 1e-9)
    }

    func testBarAndTimelineTakeTheKeysColour() {
        // A key's bar and its timeline segments share the colour it is given.
        let lens = ActivityDashboard.lens(
            from: [rec("code", at: 0, seconds: 300), rec("chrome", at: 1000, seconds: 100)],
            rangeStartMs: 0, rangeEndMs: 10000,
            colorFor: { ["code": 7, "chrome": 3][$0] ?? -1 }
        )
        XCTAssertEqual(lens.bars.map(\.colorIndex), [7, 3])
        let barColor = Dictionary(uniqueKeysWithValues: lens.bars.map { ($0.key, $0.colorIndex) })
        for segment in lens.timeline {
            XCTAssertEqual(segment.colorIndex, barColor[segment.key])
        }
    }

    func testRegistryGivesEachAppAndSiteOnePermanentColour() {
        // Owner rule 2026-09-29: unique, and stable across rankings and deletion.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ActivityStore(directory: directory)
        let first = store.colorIndices(for: (0..<30).map { "app|app\($0)" })
        XCTAssertEqual(Set(first.values).count, 30, "30 items, 30 colours — no wrap at 12")
        let later = store.colorIndices(for: ["web|youtube.com", "app|app29", "app|app0"])
        XCTAssertEqual(later["app|app29"], first["app|app29"], "a known item keeps its colour")
        XCTAssertEqual(later["app|app0"], first["app|app0"])
        XCTAssertEqual(later["web|youtube.com"], 30, "a new item gets the next unused colour")
        store.deleteAllRecords()
        XCTAssertEqual(store.colorIndices(for: [])["app|app5"], first["app|app5"], "deleting history keeps the colours")
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

    func testHistorySplitsSessionsAtMidnight() {
        // 23:30 → 00:45 next day: 30 min on the 28th, 45 min on the 29th.
        let session = ActivityRecord(id: "a", category: .appUsage, startedAt: iso("2026-09-28T23:30:00Z"), seconds: 75 * 60, key: "k", label: "k")
        let history = ActivityDashboard.history(records: [session], days: 3, now: iso("2026-09-29T12:00:00Z"), calendar: utc)
        XCTAssertEqual(history.dayStartsMs.count, 3)
        XCTAssertEqual(history.dayStartsMs.last, iso("2026-09-29T00:00:00Z").timeIntervalSince1970 * 1000)
        XCTAssertEqual(history.daySeconds, [0, 1800, 2700])
    }

    func testHistoryIgnoresTimeBeforeItsDays() {
        let old = ActivityRecord(id: "a", category: .appUsage, startedAt: iso("2026-01-01T10:00:00Z"), seconds: 600, key: "k", label: "k")
        let history = ActivityDashboard.history(records: [old], days: 180, now: iso("2026-09-29T12:00:00Z"), calendar: utc)
        XCTAssertEqual(history.daySeconds.count, 180)
        XCTAssertEqual(history.daySeconds.reduce(0, +), 0)
    }

    func testDayUsageClipsSessionsIntoEachDay() {
        let late = ActivityRecord(id: "a", category: .appUsage, startedAt: iso("2026-09-28T18:00:00Z"), seconds: 8 * 3600, key: "code", label: "Code")
        let site = ActivityRecord(id: "b", category: .webVisit, startedAt: iso("2026-09-29T06:00:00Z"), seconds: 3600, key: "youtube.com", label: "youtube.com")
        let days = ActivityDashboard.dayUsage(app: [late], web: [site], days: 2, now: iso("2026-09-29T12:00:00Z"), calendar: utc,
                                              appColor: { _ in 1 }, webColor: { _ in 2 })
        XCTAssertEqual(days[0].app.first?.colorIndex, 1)
        XCTAssertEqual(days.count, 2)
        // 18:00-24:00 on the 28th (0.75-1.0), 00:00-02:00 on the 29th (0-1/12).
        XCTAssertEqual(days[0].app.count, 1)
        XCTAssertEqual(days[0].app[0].startFraction, 0.75, accuracy: 1e-9)
        XCTAssertEqual(days[0].app[0].widthFraction, 0.25, accuracy: 1e-9)
        XCTAssertEqual(days[1].app[0].startFraction, 0, accuracy: 1e-9)
        XCTAssertEqual(days[1].app[0].widthFraction, 2.0 / 24, accuracy: 1e-9)
        XCTAssertTrue(days[0].web.isEmpty)
        XCTAssertEqual(days[1].web[0].startFraction, 0.25, accuracy: 1e-9)
    }

    func testStoreDetailFollowsThePickedKeyAndShowsAllUsage() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = iso("2026-09-29T12:00:00Z")
        let store = ActivityStore(directory: directory, now: { now }, calendar: utc)
        store.updateSettings { $0.setEnabled(true, for: .appUsage) }
        for (key, minutes) in [("chrome", 10.0), ("code", 20.0)] {
            XCTAssertTrue(store.record(ActivityRecord(id: key, category: .appUsage, startedAt: iso("2026-09-29T09:00:00Z"), seconds: minutes * 60, key: key, label: key)))
        }
        let picked = store.detail(pick: .item(.appUsage, "code"), mapDays: 7, barDays: 2)
        XCTAssertEqual(picked.map.daySeconds.last, 20 * 60)
        XCTAssertEqual(picked.days.count, 2)
        XCTAssertEqual(Set(picked.days[1].app.map(\.key)), ["chrome", "code"], "the day bars show all usage")
        XCTAssertEqual(store.detail(pick: .all, mapDays: 7, barDays: 1).map.daySeconds.last, 30 * 60)
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
        let lens = ActivityDashboard.lens(from: [rec("a", at: 0, seconds: 30), rec("b", at: 1000, seconds: 70)], rangeStartMs: 0, rangeEndMs: 10000) { _ in 0 }
        XCTAssertEqual(lens.totalSeconds, 100)
        XCTAssertEqual(lens.bars.count, 2)
        XCTAssertEqual(lens.timeline.count, 2)
    }

    func testEmptyRangeYieldsNoGeometry() {
        XCTAssertTrue(ActivityDashboard.timeline(from: [rec("a", at: 0, seconds: 5)], rangeStartMs: 5000, rangeEndMs: 5000) { _ in 0 }.isEmpty)
        XCTAssertTrue(ActivityDashboard.bars(from: []) { _, rank in rank }.isEmpty)
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
