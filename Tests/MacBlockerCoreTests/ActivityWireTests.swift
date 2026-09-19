import XCTest
@testable import MacBlockerCore

final class ActivityWireTests: XCTestCase {
    func testParsesBrowserRecords() {
        let body: [String: Any] = ["records": [
            ["id": "1", "category": "web-visit", "startedAtMs": 1_600_000_000_000, "seconds": 30, "key": "youtube.com", "label": "youtube.com"],
            ["id": "2", "category": "content-watched", "startedAtMs": 1_600_000_100_000, "seconds": 200, "key": "youtube:abc", "label": "A Video", "platform": "youtube", "creator": "Someone"],
        ]]
        let records = ActivityWire.records(from: body)
        XCTAssertEqual(records.map(\.id), ["1", "2"])
        XCTAssertEqual(records[0].category, .webVisit)
        XCTAssertEqual(records[0].seconds, 30)
        XCTAssertEqual(records[1].platform, "youtube")
        XCTAssertEqual(records[1].startedAt, Date(timeIntervalSince1970: 1_600_000_100))
    }

    func testDropsAppUsageAndInvalidRecords() {
        let body: [String: Any] = ["records": [
            ["id": "app", "category": "app-usage", "startedAtMs": 1_600_000_000_000, "seconds": 30, "key": "com.x", "label": "X"],
            ["id": "bad-cat", "category": "nope", "seconds": 30, "key": "k", "label": "L"],
            ["id": "zero", "category": "web-visit", "seconds": 0, "key": "k", "label": "L"],
            ["category": "web-visit", "seconds": 5, "key": "k", "label": "L"], // missing id
            ["id": "ok", "category": "web-visit", "seconds": 5, "key": "k", "label": "L"],
        ]]
        let records = ActivityWire.records(from: body)
        XCTAssertEqual(records.map(\.id), ["ok"], "the extension cannot forge app-usage, and invalid rows are dropped")
    }

    func testRecordCapIsBounded() {
        let many = (0..<600).map { ["id": "\($0)", "category": "web-visit", "seconds": 1, "key": "k", "label": "L"] as [String: Any] }
        XCTAssertEqual(ActivityWire.records(from: ["records": many]).count, ActivityWire.maxRecordsPerFlush)
    }

    func testSettingsPayloadRoundTripsThroughMerge() {
        var settings = ActivitySettings(idleThresholdSeconds: 90)
        settings.set(ActivityCategorySettings(enabled: true, retentionDays: 14), for: .webVisit)
        let payload = ActivityWire.settingsPayload(settings)
        let back = ActivityWire.merged(ActivitySettings(), with: payload)
        XCTAssertTrue(back.isEnabled(.webVisit))
        XCTAssertEqual(back.settings(for: .webVisit).retentionDays, 14)
        XCTAssertEqual(back.idleThresholdSeconds, 90)
    }

    func testMergeOnlyTouchesSentCategories() {
        var current = ActivitySettings()
        current.setEnabled(true, for: .appUsage) // native-owned, must survive
        let body: [String: Any] = ["byCategory": ["web-visit": ["enabled": true, "retentionDays": 7]]]
        let merged = ActivityWire.merged(current, with: body)
        XCTAssertTrue(merged.isEnabled(.appUsage), "an extension set of web-visit must not clobber app-usage")
        XCTAssertTrue(merged.isEnabled(.webVisit))
        XCTAssertEqual(merged.settings(for: .webVisit).retentionDays, 7)
    }
}
