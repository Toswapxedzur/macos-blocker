import XCTest
import MacBlockerCore
@testable import MacBlockerAppFeature

final class ActivityRecorderServiceTests: XCTestCase {
    private var directory: URL!
    private var store: ActivityStore!
    private let wall = Date(timeIntervalSince1970: 1_800_000_000)
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("activity-recorder-\(UUID().uuidString)")
        store = ActivityStore(directory: directory)
        store.saveSettings(.init(categories: [.appUsage: .init(enabled: true, retentionDays: 17)], retentionDays: 365))
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }
    private func sample(_ second: Double, app: String? = "test.app", active: Bool = true) -> ActivitySample {
        .init(monotonic: second, wall: wall.addingTimeInterval(second), appKey: app, appLabel: "Test", active: active)
    }
    private func rows() -> [ActivityRecord] {
        store.records(category: .appUsage, from: wall.addingTimeInterval(-1), to: wall.addingTimeInterval(10000))
    }

    func testOffSavesOnlyAlreadyObservedIntervalAndRejectsLateDisabledWrites() {
        let recorder = ActivityRecorderService(store: store, maxStepSeconds: 60)
        recorder.sample(sample(0)); recorder.sample(sample(10))
        store.updateSettings { $0.set(.init(enabled: false, retentionDays: 17), for: .appUsage) }
        recorder.sample(sample(20))
        XCTAssertEqual(rows().map(\.seconds), [10])
        recorder.sample(sample(200)); recorder.stop(); recorder.stop()
        XCTAssertEqual(rows().map(\.seconds), [10])
        XCTAssertFalse(store.record(.init(id: "late", category: .appUsage, startedAt: wall, seconds: 50, key: "late", label: "Late")))
        XCTAssertFalse(store.loadSettings().isEnabled(.appUsage))
        XCTAssertFalse(store.loadSettings().isEnabled(.webVisit))
        XCTAssertFalse(store.loadSettings().isEnabled(.contentWatched))
        XCTAssertEqual(store.loadSettings().settings(for: .appUsage).retentionDays, 17)
    }

    func testStopAfterExternalOffSavesObservedBucketWithoutASecondTick() {
        let recorder = ActivityRecorderService(store: store, maxStepSeconds: 60)
        recorder.sample(sample(0)); recorder.sample(sample(7))
        store.updateSettings { $0.set(.init(enabled: false), for: .appUsage) }
        recorder.stop(); recorder.stop()
        XCTAssertEqual(rows().map(\.seconds), [7])
        let restarted = ActivityRecorderService(store: store, maxStepSeconds: 60)
        restarted.sample(sample(100)); restarted.stop()
        XCTAssertEqual(rows().map(\.seconds), [7])
    }

    func testReenableStartsFreshAndRetentionOnlyChangeKeepsRecording() {
        let recorder = ActivityRecorderService(store: store, maxStepSeconds: 60)
        recorder.sample(sample(0)); recorder.sample(sample(5))
        store.updateSettings { $0.retentionDays = 30 }
        recorder.sample(sample(10))
        store.updateSettings { $0.set(.init(enabled: false), for: .appUsage) }
        recorder.sample(sample(20))
        store.updateSettings { $0.set(.init(enabled: true), for: .appUsage) }
        recorder.sample(sample(1000)); recorder.sample(sample(1004)); recorder.stop()
        XCTAssertEqual(rows().map(\.seconds), [10, 4])
        XCTAssertEqual(store.loadSettings().retentionDays, 30)
    }

    func testAppSwitchAndInactiveSampleStillUseExistingEligibility() {
        let recorder = ActivityRecorderService(store: store, maxStepSeconds: 60)
        recorder.sample(sample(0)); recorder.sample(sample(5, app: "other.app"))
        recorder.sample(sample(8, app: "other.app")); recorder.sample(sample(10, active: false))
        recorder.stop()
        XCTAssertEqual(rows().map(\.seconds), [5, 3])
        XCTAssertEqual(rows().map(\.key), ["test.app", "other.app"])
    }
}
