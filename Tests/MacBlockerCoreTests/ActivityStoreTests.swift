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

    func testWatchedFactsSaveAuthorsOnceAndFreezeTags() throws {
        let s = store(now: day("2026-09-29T12:00:00Z"))
        s.record(ActivityRecord(id: "w1", category: .contentWatched, startedAt: day("2026-09-29T09:00:00Z"), seconds: 60, key: "youtube:a", label: "A"), settings: allEnabled())
        let icon = "data:image/jpeg;base64,AAAA"
        let math = ActivityTag(id: "t1", name: "Math", color: "#2563eb")
        s.recordWatchedFacts([
            ActivityWatchedEntry(videoKey: "youtube:a", authorID: "youtube:channel:UC1", authorName: "Chan", authorIcon: icon),
            ActivityWatchedEntry(videoKey: "youtube:b", authorID: "youtube:channel:UC1", authorName: "Chan", tags: [math]),
            ActivityWatchedEntry(videoKey: "youtube:c", authorID: "youtube:channel:UC2", authorName: "Other", authorIcon: "https://not-a-data-uri")
        ])
        // Tags come later for a, once; b's tags never change after.
        s.recordWatchedFacts([
            ActivityWatchedEntry(videoKey: "youtube:a", tags: [math]),
            ActivityWatchedEntry(videoKey: "youtube:b", tags: [ActivityTag(id: "t2", name: "Music", color: "#db2777")])
        ])
        let facts = s.watchedFacts(for: ["youtube:a", "youtube:b", "youtube:c", "youtube:z"])
        XCTAssertEqual(facts["youtube:a"]?.author, ActivityAuthor(name: "Chan", icon: icon))
        XCTAssertEqual(facts["youtube:a"]?.tags, [math])
        XCTAssertEqual(facts["youtube:b"]?.author?.icon, icon)  // one icon per author
        XCTAssertEqual(facts["youtube:b"]?.tags, [math])
        XCTAssertEqual(facts["youtube:c"]?.author, ActivityAuthor(name: "Other", icon: nil))  // only data URIs
        XCTAssertNil(facts["youtube:c"]?.tags)
        XCTAssertNil(facts["youtube:z"])
        // Kept as long as the video's watched records: b and c have none.
        s.prune(settings: allEnabled())
        XCTAssertEqual(Set(s.watchedFacts(for: ["youtube:a", "youtube:b", "youtube:c"]).keys), ["youtube:a"])
        s.delete(category: .contentWatched)
        XCTAssertTrue(s.watchedFacts(for: ["youtube:a"]).isEmpty)
    }

    func testContentYearMapCountsOnlyTheFocusedTags() throws {
        let s = store(now: day("2026-09-29T12:00:00Z"))
        s.record(ActivityRecord(id: "a", category: .contentWatched, startedAt: day("2026-09-29T09:00:00Z"), seconds: 600, key: "youtube:a", label: "A"), settings: allEnabled())
        s.record(ActivityRecord(id: "b", category: .contentWatched, startedAt: day("2026-09-29T10:00:00Z"), seconds: 300, key: "youtube:b", label: "B"), settings: allEnabled())
        s.recordWatchedFacts([
            ActivityWatchedEntry(videoKey: "youtube:a", tags: [ActivityTag(id: "minecraft", name: "Minecraft", color: "#00ff00")]),
            ActivityWatchedEntry(videoKey: "youtube:b", tags: [ActivityTag(id: "music", name: "Music", color: "#ff0000")]),
        ])
        XCTAssertEqual(s.contentHistory(tagIDs: nil, days: 7).daySeconds.last, 900)
        XCTAssertEqual(s.contentHistory(tagIDs: ["gaming", "minecraft"], days: 7).daySeconds.last, 600)
        XCTAssertEqual(s.contentHistory(tagIDs: ["music"], days: 7).daySeconds.count, 7)
    }

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

    func testSessionsCrossingMidnightAreClippedWithoutChangingStoredRecords() throws {
        let midnight = day("2026-10-07T00:00:00Z")
        let s = store(now: midnight.addingTimeInterval(600))
        for category in ActivityCategory.allCases {
            s.record(record(category.rawValue, category, at: midnight.addingTimeInterval(-300), seconds: 900), settings: allEnabled())
            let today = s.records(category: category, from: midnight, to: midnight.addingTimeInterval(600))
            XCTAssertEqual(today.count, 1)
            XCTAssertEqual(today.first?.startedAt, midnight)
            XCTAssertEqual(today.first?.seconds, 600)
            let yesterday = s.aggregate(category: category, from: midnight.addingTimeInterval(-3600), to: midnight)
            XCTAssertEqual(yesterday.first?.seconds, 300)
            let whole = s.records(category: category, from: midnight.addingTimeInterval(-3600), to: midnight.addingTimeInterval(3600))
            XCTAssertEqual(whole.first?.seconds, 900)
        }
        let dashboard = s.dashboardSnapshot(from: midnight, to: midnight.addingTimeInterval(600))
        XCTAssertEqual(dashboard.app.totalSeconds, 600)
        XCTAssertEqual(dashboard.app.bars.first?.seconds, 600)
        XCTAssertEqual(dashboard.app.timeline.first?.seconds, 600)
        XCTAssertEqual(dashboard.web.totalSeconds, 600)
        XCTAssertEqual(dashboard.watched.first?.seconds, 600)
    }

    func testMultiDaySessionAndPartialRangeCountOnlyTheirOverlap() throws {
        let midnight = day("2026-10-07T00:00:00Z")
        let s = store(now: midnight.addingTimeInterval(600))
        s.record(record("long", .appUsage, at: midnight.addingTimeInterval(-172800), seconds: 173400), settings: allEnabled())
        let partial = s.records(category: .appUsage, from: midnight.addingTimeInterval(100), to: midnight.addingTimeInterval(200))
        XCTAssertEqual(partial.first?.seconds, 100)
        XCTAssertEqual(partial.first?.startedAt, midnight.addingTimeInterval(100))
        XCTAssertTrue(s.records(category: .appUsage, from: midnight.addingTimeInterval(600), to: midnight.addingTimeInterval(1200)).isEmpty)
        XCTAssertTrue(s.records(category: .appUsage, from: midnight, to: midnight).isEmpty)
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

    func testKindsFollowTheGlobalKeepUnlessSet() throws {
        let s = store(now: day("2026-09-19T12:00:00Z"))
        var settings = allEnabled()
        settings.retentionDays = 7
        settings.set(ActivityCategorySettings(enabled: true, retentionDays: 0), for: .webVisit)
        s.record(record("oldApp", .appUsage, at: day("2026-09-01T09:00:00Z"), seconds: 100), settings: settings)
        s.record(record("oldWeb", .webVisit, at: day("2026-09-01T09:00:00Z"), seconds: 100), settings: settings)
        s.prune(settings: settings)
        let range = (day("2026-08-01T00:00:00Z"), day("2026-09-19T23:59:59Z"))
        XCTAssertTrue(s.records(category: .appUsage, from: range.0, to: range.1).isEmpty)  // follows the global 7 days
        XCTAssertEqual(s.records(category: .webVisit, from: range.0, to: range.1).map(\.id), ["oldWeb"])  // its own: forever
    }

    func testSettingsSavedBeforeTheGlobalKeepFollowIt() throws {
        let old = #"{"byCategory":{"app-usage":{"enabled":true,"retentionDays":30}},"idleThresholdSeconds":60}"#
        let settings = try JSONDecoder().decode(ActivitySettings.self, from: Data(old.utf8))
        XCTAssertEqual(settings.retentionDays, 365)
        XCTAssertNil(settings.settings(for: .appUsage).retentionDays)
        XCTAssertTrue(settings.isEnabled(.appUsage))
        XCTAssertEqual(settings.effectiveRetentionDays(for: .appUsage), 365)
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

    func testDefaultsAreOffAYearSixtySecondIdle() throws {
        let settings = ActivitySettings()
        XCTAssertEqual(settings.idleThresholdSeconds, 60)
        for c in ActivityCategory.allCases {
            XCTAssertFalse(settings.isEnabled(c))
            XCTAssertNil(settings.settings(for: c).retentionDays)  // follows the global Keep
            XCTAssertEqual(settings.effectiveRetentionDays(for: c), 365)
        }
        XCTAssertEqual(settings.retentionDays, 365)
    }
    func testCompatibleAlphaActivityMigratesOnceAndFutureSettingsStayUnchanged() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("settings.json")
        let original = ActivitySettings()
        try JSONEncoder().encode(original).write(to: file)
        let store = ActivityStore(directory: root)
        XCTAssertEqual(store.loadSettings(), original)
        let migrated = try Data(contentsOf: file)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: migrated) as? [String: Any])
        XCTAssertNotNil(object["storageMetadata"])
        XCTAssertEqual(store.loadSettings(), original)
        XCTAssertEqual(try Data(contentsOf: file), migrated)
        let future = Data(#"{"storageMetadata":{"format":"activity.settings","schemaVersion":99,"product":"mac","writtenByAppVersion":"9.0.0"},"value":{"future":"keep"}}"#.utf8)
        try future.write(to: file)
        _ = store.loadSettings()
        store.saveSettings(original)
        XCTAssertNotNil(store.storageIssue)
        XCTAssertEqual(try Data(contentsOf: file), future)
    }

}
