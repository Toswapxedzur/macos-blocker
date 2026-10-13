import XCTest
import Network
import MacBlockerCore
@testable import MacBlockerAppFeature

final class ActivitySettingsNotificationTests: XCTestCase {
    private func connection(_ hub: ConnectionHub, program: String, admit: Bool = true) -> NWConnection {
        let connection = NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
        hub.registerPendingPeer(connection, challenge: "isolated-test")
        if admit { XCTAssertNil(hub.admitAuthenticatedPeer(connection, program: program)) }
        return connection
    }
    private func incoming(_ hub: ConnectionHub, _ connection: NWConnection, _ message: [String: Any]) throws {
        hub.handleIncoming(connection, key: ObjectIdentifier(connection), data: try JSONSerialization.data(withJSONObject: message))
    }
    private func decoded(_ frames: [Data]) -> [[String: Any]] {
        frames.compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
    private func notifications(_ frames: [Data]) -> [[String: Any]] {
        decoded(frames).filter { $0["kind"] as? String == "activity-settings-updated" }
    }

    func testSuccessfulCommitNotifiesAuthenticatedBrowsersAndWelcomePrecedesInitialState() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ActivityStore(directory: directory), queue = DispatchQueue(label: "test.activity.welcome")
        var frames: [Data] = []
        let hub = ConnectionHub(testOutboundQueue: queue) { frames.append($0) }
        hub.activityStore = store
        queue.sync {}; frames.removeAll()
        let chrome = connection(hub, program: "chrome")
        let initial = decoded({ queue.sync {}; return frames }())
        XCTAssertEqual(initial.prefix(2).map { $0["kind"] as? String }, ["welcome", "activity-settings-updated"])
        XCTAssertEqual(initial.first?["activitySettingsNotifications"] as? Bool, true)
        let edge = connection(hub, program: "edge"), classifier = connection(hub, program: "classifier")
        let pending = connection(hub, program: "safari", admit: false)
        XCTAssertEqual(hub.activityNotificationRecipients, ["chrome", "edge"])
        queue.sync {}; frames.removeAll()
        let committed = try XCTUnwrap(store.updateSettings { $0.setEnabled(true, for: .webVisit) })
        queue.sync {}
        let published = try XCTUnwrap(notifications(frames).last?["body"] as? [String: Any])
        XCTAssertEqual(published["revision"] as? Int, committed.revision)
        XCTAssertEqual(published["epoch"] as? String, committed.epoch)
        XCTAssertEqual(notifications(frames).count, 1)
        withExtendedLifetime([chrome, edge, classifier, pending]) {}
    }

    func testOlderAndRetiredCallbacksCannotOverwriteCurrentSettings() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let otherDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: otherDirectory) }
        let store = ActivityStore(directory: directory), queue = DispatchQueue(label: "test.activity.order")
        var frames: [Data] = []
        let hub = ConnectionHub(testOutboundQueue: queue) { frames.append($0) }
        hub.activityStore = store
        let old = try XCTUnwrap(store.updateSettings { $0.idleThresholdSeconds = 60 })
        let current = try XCTUnwrap(store.updateSettings { $0.idleThresholdSeconds = 90 })
        queue.sync {}; frames.removeAll()
        hub.publishActivitySettings(old, from: store)
        hub.publishActivitySettings(current, from: store)
        queue.sync {}; XCTAssertTrue(frames.isEmpty)
        let other = ActivityStore(directory: otherDirectory)
        hub.activityStore = other
        queue.sync {}; frames.removeAll()
        hub.publishActivitySettings(current, from: store)
        _ = store.updateSettings { $0.idleThresholdSeconds = 120 }
        queue.sync {}; XCTAssertTrue(frames.isEmpty)
    }

    func testStorageFailureHasExplicitErrorAndNoCommitNotification() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // A directory at the exact settings-file path reliably refuses atomic
        // replacement without relying on permissions or the runner's identity.
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("settings.json"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ActivityStore(directory: directory), queue = DispatchQueue(label: "test.activity.failure")
        var frames: [Data] = []
        let hub = ConnectionHub(testOutboundQueue: queue) { frames.append($0) }
        hub.activityStore = store
        let chrome = connection(hub, program: "chrome")
        queue.sync {}; frames.removeAll()
        try incoming(hub, chrome, ["kind": "classifier-request", "requestID": "failure", "operation": "activity-settings", "body": ["settings": ["idleThresholdSeconds": 90]]])
        queue.sync {}
        XCTAssertTrue(notifications(frames).isEmpty)
        XCTAssertEqual(decoded(frames).last?["error"] as? String, "activity-storage-unavailable")
        XCTAssertEqual(store.settingsSnapshot().revision, 0)
    }

    func testSetReplyRetainsExactCommitWhenAnotherObserverCommitsAgain() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ActivityStore(directory: directory), queue = DispatchQueue(label: "test.activity.exact-reply")
        var frames: [Data] = []
        let hub = ConnectionHub(testOutboundQueue: queue) { frames.append($0) }
        hub.activityStore = store
        let chrome = connection(hub, program: "chrome")
        let token = store.observeSettings { snapshot in
            if snapshot.revision == 1 { store.updateSettings { $0.idleThresholdSeconds = 180 } }
        }
        defer { store.removeSettingsObserver(token) }
        queue.sync {}; frames.removeAll()
        try incoming(hub, chrome, ["kind": "classifier-request", "requestID": "exact", "operation": "activity-settings", "body": ["settings": ["idleThresholdSeconds": 90]]])
        queue.sync {}
        let response = try XCTUnwrap(decoded(frames).last(where: { $0["kind"] as? String == "classifier-response" })?["body"] as? [String: Any])
        XCTAssertEqual(response["revision"] as? Int, 1)
        XCTAssertEqual((response["settings"] as? [String: Any])?["idleThresholdSeconds"] as? Double, 90)
        XCTAssertEqual(store.settingsSnapshot().revision, 2)
        XCTAssertEqual((notifications(frames).last?["body"] as? [String: Any])?["revision"] as? Int, 2)
    }

    func testClassifierAndBrowserCannotForgeNativeSettingsNotification() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ActivityStore(directory: directory), queue = DispatchQueue(label: "test.activity.forgery")
        var frames: [Data] = []
        let hub = ConnectionHub(testOutboundQueue: queue) { frames.append($0) }
        hub.activityStore = store
        let chrome = connection(hub, program: "chrome"), classifier = connection(hub, program: "classifier")
        queue.sync {}; frames.removeAll()
        for source in [chrome, classifier] {
            try incoming(hub, source, ["kind": "activity-settings-updated", "body": ["settings": [:], "revision": 999]])
            try incoming(hub, source, ["kind": "classifier-broadcast", "operation": "activity-settings-updated", "body": ["settings": [:]]])
        }
        queue.sync {}; XCTAssertTrue(frames.isEmpty)
        XCTAssertEqual(store.settingsSnapshot().revision, 0)
    }
}
