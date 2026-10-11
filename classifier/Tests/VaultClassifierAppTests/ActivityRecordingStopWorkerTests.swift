import Foundation
import XCTest
import VaultActivityCore
import VaultClassifierCore
@testable import VaultClassifierApp

@MainActor
final class ActivityRecordingStopWorkerTests: XCTestCase {
    private var directory: URL!
    private let wall = Date(timeIntervalSince1970: 1_800_000_000)
    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("activity-stop-\(UUID().uuidString)")
    }
    override func tearDown() async throws {
        LocalStateFile.flushAllPendingWrites()
        try? FileManager.default.removeItem(at: directory)
    }
    private var store: ActivityStore { ActivityStore(directory: directory.appendingPathComponent("Activity")) }
    private func worker() throws -> VaultClassifierWorkerService {
        try .init(testingDirectory: directory, emit: { _ in })
    }
    @discardableResult
    private func send(_ service: VaultClassifierWorkerService, _ body: [String: Any]) async throws -> [String: Any] {
        let value = try await service.handle(operation: "activity", data: body)
        return try XCTUnwrap(value as? [String: Any])
    }
    private func sample(_ service: VaultClassifierWorkerService, _ second: Double, app: String = "a.exe") async throws {
        _ = try await send(service, ["kind": "native-sample", "elapsedMs": 1000, "monotonicMs": second * 1000,
            "atMs": wall.addingTimeInterval(second).timeIntervalSince1970 * 1000, "appId": app, "name": app])
    }
    private func records() -> [ActivityRecord] {
        store.records(category: .appUsage, from: wall.addingTimeInterval(-1), to: wall.addingTimeInterval(10000))
    }
    private func startObservedBucket(_ service: VaultClassifierWorkerService) async throws {
        _ = try await send(service, ["kind": "setSettings", "category": "app-usage", "enabled": true])
        try await sample(service, 0)
        try await sample(service, 10)
        XCTAssertTrue(records().isEmpty)
    }

    func testCategoryOffSavesObservedUsageOnceAndLateDisabledRecordsStayRefused() async throws {
        let service = try worker()
        try await startObservedBucket(service)
        _ = try await send(service, ["kind": "setSettings", "category": "app-usage", "enabled": false])
        try await sample(service, 20)
        XCTAssertEqual(records().map(\.seconds), [10])
        try await sample(service, 40)
        _ = try await send(service, ["kind": "native-flush"])
        XCTAssertEqual(records().map(\.seconds), [10])
        XCTAssertFalse(store.record(.init(id: "late", category: .appUsage, startedAt: wall, seconds: 99, key: "late.exe", label: "Late")))
        _ = try await send(service, ["kind": "native-record", "records": [["id": "late-native", "key": "late.exe", "label": "Late",
            "seconds": 99, "startedAtMs": wall.timeIntervalSince1970 * 1000]]])
        let forged = try await send(service, ["kind": "browser-record", "records": [["id": "forged", "category": "app-usage",
            "key": "late.exe", "label": "Late", "seconds": 99, "startedAtMs": wall.timeIntervalSince1970 * 1000]]])
        XCTAssertEqual(forged["accepted"] as? Int, 0)
        XCTAssertEqual(records().map(\.seconds), [10])
        XCTAssertFalse(store.loadSettings().isEnabled(.webVisit))
        XCTAssertFalse(store.loadSettings().isEnabled(.contentWatched))
        XCTAssertEqual(store.loadSettings().retentionDays, 365)
    }

    func testMergedOffThenFlushKeepsObservedUsageAndRestartCannotReplayIt() async throws {
        let service = try worker()
        try await startObservedBucket(service)
        _ = try await send(service, ["kind": "settings", "settings": ["byCategory": ["app-usage": ["enabled": false]]]])
        XCTAssertFalse(store.loadSettings().isEnabled(.appUsage))
        let flushed = try await send(service, ["kind": "native-flush"])
        XCTAssertEqual(flushed["accepted"] as? Int, 1)
        XCTAssertEqual(records().map(\.seconds), [10])
        let restarted = try worker()
        try await sample(restarted, 100)
        _ = try await send(restarted, ["kind": "native-flush"])
        XCTAssertEqual(records().map(\.seconds), [10])
    }

    func testExternalOffThenReenableDoesNotIncludeDisabledGap() async throws {
        let service = try worker()
        try await startObservedBucket(service)
        store.updateSettings { $0.set(.init(enabled: false), for: .appUsage) }
        try await sample(service, 20)
        _ = try await send(service, ["kind": "setSettings", "category": "app-usage", "enabled": true])
        try await sample(service, 1000)
        try await sample(service, 1005)
        _ = try await send(service, ["kind": "native-flush"])
        XCTAssertEqual(records().map(\.seconds), [10, 5])
    }

    func testBrowserCategoryOffStillRefusesLateBrowserWritesWithoutChangingApps() async throws {
        let service = try worker()
        try await startObservedBucket(service)
        _ = try await send(service, ["kind": "settings", "settings": ["byCategory": ["web-visit": ["enabled": true]]]])
        var web: [String: Any] = ["id": "web-first", "category": "web-visit", "key": "example.test", "label": "Example",
            "seconds": 3, "startedAtMs": wall.timeIntervalSince1970 * 1000]
        let accepted = try await send(service, ["kind": "browser-record", "records": [web]])
        XCTAssertEqual(accepted["accepted"] as? Int, 1)
        _ = try await send(service, ["kind": "setSettings", "category": "web-visit", "enabled": false])
        web["id"] = "web-late"
        let refused = try await send(service, ["kind": "browser-record", "records": [web]])
        XCTAssertEqual(refused["accepted"] as? Int, 0)
        XCTAssertTrue(store.loadSettings().isEnabled(.appUsage))
        try await sample(service, 15)
        _ = try await send(service, ["kind": "native-flush"])
        XCTAssertEqual(records().map(\.seconds), [15])
        XCTAssertEqual(store.records(category: .webVisit, from: wall.addingTimeInterval(-1), to: wall.addingTimeInterval(100)).map(\.seconds), [3])
    }
}
