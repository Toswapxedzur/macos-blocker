import XCTest
@testable import MacBlockerCore

final class ActivityStoreTests: XCTestCase {
    private var root: URL!
    private var calendar: Calendar!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("activity-\(UUID().uuidString)", isDirectory: true)
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func store(now: Date) -> ActivityStore {
        ActivityStore(directory: root, now: { now }, calendar: calendar)
    }

    private func day(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        return f.date(from: iso)!
    }

    private func record(_ id: String, _ category: ActivityCategory, at date: Date, seconds: Double, key: String = "k", label: String = "L") -> ActivityRecord {
        ActivityRecord(id: id, category: category, startedAt: date, seconds: seconds, key: key, label: label)
    }

    private func allEnabled(idle: Int = 60) -> ActivitySettings {
        var s = ActivitySettings(idleThresholdSeconds: idle)
        for c in ActivityCategory.allCases { s.setEnabled(true, for: c) }
        return s
    }

    // MARK: privacy invariant

    func testDisabledCategoryWritesNothing() throws {
        let s = store(now: day("2026-09-19T12:00:00Z"))
        // default settings = all categories OFF
        XCTAssertFalse(s.record(record("a", .appUsage, at: day("2026-09-19T09:00:00Z"), seconds: 100)))
        XCTAssertTrue(s.aggregate(category: .appUsage, from: day("2026-09-19T00:00:00Z"), to: day("2026-09-19T23:59:59Z")).isEmpty)
    }

    func testEnabledCategoryRecordsAndDisablingStopsMidStream() throws {
        let s = store(now: day("2026-09-19T12:00:00Z"))
        var settings = allEnabled()
        XCTAssertTrue(s.record(record("a", .webVisit, at: day("2026-09-19T09:00:00Z"), seconds: 30, key: "youtube.com"), settings: settings))
        settings.setEnabled(false, for: .webVisit)
        XCTAssertFalse(s.record(record("b", .webVisit, at: day("2026-09-19T09:05:00Z"), seconds: 30, key: "youtube.com"), settings: settings))
        let agg = s.aggregate(category: .webVisit, from: day("2026-09-19T00:00:00Z"), to: day("2026-09-19T23:59:59Z"))
        XCTAssertEqual(agg.map(\.seconds), [30])
    }

    func testNonPositiveSecondsIgnored() throws {
        let s = store(now: day("2026-09-19T12:00:00Z"))
        XCTAssertFalse(s.record(record("a", .appUsage, at: day("2026-09-19T09:00:00Z"), seconds: 0), settings: allEnabled()))
    }

    // MARK: idempotent replay

    func testReplayOfSameIdIsIdempotent() throws {
        let s = store(now: day("2026-09-19T12:00:00Z"))
        let r = record("dup", .contentWatched, at: day("2026-09-19T09:00:00Z"), seconds: 200, key: "youtube:abc")
        XCTAssertTrue(s.record(r, settings: allEnabled()))
        XCTAssertFalse(s.record(r, settings: allEnabled()), "same id must not double-count")
        let agg = s.aggregate(category: .contentWatched, from: day("2026-09-19T00:00:00Z"), to: day("2026-09-19T23:59:59Z"))
        XCTAssertEqual(agg.map(\.seconds), [200])
    }

    // MARK: aggregation

    func testAggregateSumsByKeyLargestFirst() throws {
        let s = store(now: day("2026-09-20T12:00:00Z"))
        let settings = allEnabled()
        s.record(record("1", .appUsage, at: day("2026-09-19T09:00:00Z"), seconds: 100, key: "com.chrome", label: "Chrome"), settings: settings)
        s.record(record("2", .appUsage, at: day("2026-09-19T10:00:00Z"), seconds: 50, key: "com.chrome", label: "Chrome"), settings: settings)
        s.record(record("3", .appUsage, at: day("2026-09-20T10:00:00Z"), seconds: 300, key: "com.code", label: "Code"), settings: settings)
        let agg = s.aggregate(category: .appUsage, from: day("2026-09-19T00:00:00Z"), to: day("2026-09-20T23:59:59Z"))
        XCTAssertEqual(agg.map(\.key), ["com.code", "com.chrome"])
        XCTAssertEqual(agg.first?.seconds, 300)
        XCTAssertEqual(agg.last?.seconds, 150)
    }

    func testAggregateRespectsRangeBoundaries() throws {
        let s = store(now: day("2026-09-20T12:00:00Z"))
        let settings = allEnabled()
        s.record(record("in", .appUsage, at: day("2026-09-19T09:00:00Z"), seconds: 100), settings: settings)
        s.record(record("out", .appUsage, at: day("2026-09-17T09:00:00Z"), seconds: 999), settings: settings)
        let agg = s.aggregate(category: .appUsage, from: day("2026-09-18T00:00:00Z"), to: day("2026-09-20T00:00:00Z"))
        XCTAssertEqual(agg.map(\.seconds), [100])
    }

    // MARK: reaper

    func testPruneDeletesBeyondRetentionKeepsWithin() throws {
        let s = store(now: day("2026-09-19T12:00:00Z"))
        var settings = allEnabled()
        settings.set(ActivityCategorySettings(enabled: true, retentionDays: 7), for: .appUsage)
        s.record(record("old", .appUsage, at: day("2026-09-01T09:00:00Z"), seconds: 100), settings: settings)
        s.record(record("new", .appUsage, at: day("2026-09-18T09:00:00Z"), seconds: 100), settings: settings)
        s.prune(settings: settings)
        let agg = s.aggregate(category: .appUsage, from: day("2026-08-01T00:00:00Z"), to: day("2026-09-19T23:59:59Z"))
        XCTAssertEqual(agg.map(\.seconds), [100])
        XCTAssertEqual(s.records(category: .appUsage, from: day("2026-08-01T00:00:00Z"), to: day("2026-09-19T23:59:59Z")).map(\.id), ["new"])
    }

    func testRetentionZeroKeepsEverything() throws {
        let s = store(now: day("2026-12-31T12:00:00Z"))
        var settings = allEnabled()
        settings.set(ActivityCategorySettings(enabled: true, retentionDays: 0), for: .appUsage)
        s.record(record("ancient", .appUsage, at: day("2020-01-01T09:00:00Z"), seconds: 100), settings: settings)
        s.prune(settings: settings)
        XCTAssertEqual(s.records(category: .appUsage, from: day("2019-01-01T00:00:00Z"), to: day("2026-12-31T23:59:59Z")).map(\.id), ["ancient"])
    }

    // MARK: deletion

    func testDeleteRangeFiltersBoundaryDays() throws {
        let s = store(now: day("2026-09-20T12:00:00Z"))
        let settings = allEnabled()
        s.record(record("keepEarly", .webVisit, at: day("2026-09-19T08:00:00Z"), seconds: 10, key: "a"), settings: settings)
        s.record(record("dropMid", .webVisit, at: day("2026-09-19T12:00:00Z"), seconds: 10, key: "b"), settings: settings)
        s.delete(from: day("2026-09-19T10:00:00Z"), to: day("2026-09-19T14:00:00Z"))
        let ids = s.records(category: .webVisit, from: day("2026-09-19T00:00:00Z"), to: day("2026-09-19T23:59:59Z")).map(\.id)
        XCTAssertEqual(ids, ["keepEarly"])
    }

    func testDeleteAllAndDeleteCategory() throws {
        let s = store(now: day("2026-09-20T12:00:00Z"))
        let settings = allEnabled()
        s.record(record("1", .appUsage, at: day("2026-09-19T08:00:00Z"), seconds: 10), settings: settings)
        s.record(record("2", .webVisit, at: day("2026-09-19T08:00:00Z"), seconds: 10, key: "a"), settings: settings)
        s.delete(category: .appUsage)
        XCTAssertTrue(s.records(category: .appUsage, from: day("2026-09-19T00:00:00Z"), to: day("2026-09-19T23:59:59Z")).isEmpty)
        XCTAssertFalse(s.records(category: .webVisit, from: day("2026-09-19T00:00:00Z"), to: day("2026-09-19T23:59:59Z")).isEmpty)
        s.deleteAllRecords()
        XCTAssertTrue(s.records(category: .webVisit, from: day("2026-09-19T00:00:00Z"), to: day("2026-09-19T23:59:59Z")).isEmpty)
    }

    // MARK: settings round-trip

    func testSettingsRoundTrip() throws {
        let s = store(now: day("2026-09-19T12:00:00Z"))
        var settings = ActivitySettings(idleThresholdSeconds: 120)
        settings.set(ActivityCategorySettings(enabled: true, retentionDays: 14), for: .contentWatched)
        s.saveSettings(settings)
        let loaded = s.loadSettings()
        XCTAssertEqual(loaded.idleThresholdSeconds, 120)
        XCTAssertTrue(loaded.isEnabled(.contentWatched))
        XCTAssertEqual(loaded.settings(for: .contentWatched).retentionDays, 14)
        XCTAssertFalse(loaded.isEnabled(.appUsage))
    }

    func testDefaultsAreOffThirtyDaysSixtySecondIdle() throws {
        let settings = ActivitySettings()
        XCTAssertEqual(settings.idleThresholdSeconds, 60)
        for c in ActivityCategory.allCases {
            XCTAssertFalse(settings.isEnabled(c))
            XCTAssertEqual(settings.settings(for: c).retentionDays, 30)
        }
    }
}
