import XCTest
import Network
import MacBlockerCore
import MacBlockerWebUI
@testable import MacBlockerAppFeature

/// These exercise the hub's real capture/enqueue path. The injected transport
/// pauses one delivery after capture; a second producer can mutate concurrently.
/// It changes neither hub policy nor the order of state transitions.
final class ClusterOutboundOrderingTests: XCTestCase {
    private let registryKey = "ConnectionHub.clusters.v2"
    private var previousRegistry: Data?
    override func setUp() {
        super.setUp()
        previousRegistry = UserDefaults.standard.data(forKey: registryKey)
    }
    override func tearDown() {
        if let previousRegistry { UserDefaults.standard.set(previousRegistry, forKey: registryKey) }
        else { UserDefaults.standard.removeObject(forKey: registryKey) }
        super.tearDown()
    }

    private final class Recorder {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var gate: (([String: Any]) -> Bool)?
        private var frames: [[String: Any]] = []
        func arm(_ gate: @escaping ([String: Any]) -> Bool) {
            lock.lock(); self.gate = gate; lock.unlock()
        }
        func deliver(_ data: Data) {
            guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            lock.lock()
            let pause = gate?(value) == true
            if pause { gate = nil }
            lock.unlock()
            if pause {
                entered.signal()
                _ = release.wait(timeout: .now() + 10)
            }
            lock.lock(); frames.append(value); lock.unlock()
        }
        func all() -> [[String: Any]] {
            lock.lock(); defer { lock.unlock() }; return frames
        }
    }
    private func site(_ name: String, except: Bool = false, action: String = "block") -> [String: Any] {
        ["surface": "site", "sites": [name], "sitesExcept": except, "action": action]
    }
    private func setup(_ h: ConnectionHub) {
        h.hostingLocalHub = true
        for (program, id) in [("chrome", "c"), ("edge", "e"), ("safari", "s")] {
            h.setRoster(program: program, groups: [["id": id, "name": program]])
        }
        XCTAssertNil(h.linkGroups(program: "chrome", groupId: "c", targetProgram: "edge", targetGroupId: "e"))
        let anchor = (Date().timeIntervalSince1970 * 1000).rounded(.down)
        h.applySync(program: "chrome", groupId: "c", contribution: [
            "scalars": ["name": "Linked", "enabled": false, "mode": "after-minutes", "allowedMinutes": 60],
            "scopes": [site("chrome.example")], "usageMs": 1000.0, "usageResetAtMs": anchor
        ], ts: 0)
        h.applySync(program: "edge", groupId: "e", contribution: [
            "scalars": ["name": "Edge"], "scopes": [site("edge.example", except: true, action: "pause")]
        ], ts: 0)
    }
    private func shared(_ frame: [String: Any]) -> [String: Any] {
        (frame["cluster"] as? [String: Any])?["shared"] as? [String: Any] ?? [:]
    }
    private func sites(_ frame: [String: Any]) -> [[String: Any]] {
        (shared(frame)["scopes"] as? [[String: Any]] ?? []).filter { $0["surface"] as? String == "site" }
    }
    private func latestCluster(_ frames: [[String: Any]]) throws -> [String: Any] {
        try XCTUnwrap(frames.last(where: { $0["kind"] as? String == "cluster-updated" }))
    }
    /// The older send is deliberately paused. Both producers must finish their
    /// state updates while that send is blocked; this rules out sending under
    /// the hub lock, or serializing mutators with a synchronous queue hop.
    private func interleave(_ recorder: Recorder, outbound: DispatchQueue,
                            first: @escaping () -> Void, second: @escaping () -> Void) {
        let firstDone = DispatchSemaphore(value: 0)
        let secondDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { first(); firstDone.signal() }
        guard recorder.entered.wait(timeout: .now() + 5) == .success else {
            recorder.release.signal(); XCTFail("The real first delivery did not reach the barrier"); return
        }
        DispatchQueue.global().async { second(); secondDone.signal() }
        let completed = secondDone.wait(timeout: .now() + 5)
        recorder.release.signal()
        XCTAssertEqual(completed, .success, "Transport must not hold the hub or document locks")
        XCTAssertEqual(firstDone.wait(timeout: .now() + 5), .success)
        // This is a test-only wait for the injected sender, never a mutator hop.
        outbound.sync {}
    }
    func testEqualTimestampUsageFrameCannotDropALaterThirdBrowserUnion() throws {
        let recorder = Recorder(), outbound = DispatchQueue(label: "test.hub.outbound.union")
        let hub = ConnectionHub(testOutboundQueue: outbound, outboundDelivery: recorder.deliver)
        setup(hub); outbound.sync {}
        let policyTimestamp = try XCTUnwrap(shared(try latestCluster(recorder.all()))["ts"] as? Double)
        recorder.arm { ($0["kind"] as? String) == "cluster-updated" && (self.shared($0)["usageMs"] as? Double) == 1100 }
        interleave(recorder, outbound: outbound, first: {
            hub.applySync(program: "chrome", groupId: "c", contribution: ["usageDeltaMs": 100.0], ts: 0)
        }, second: {
            XCTAssertNil(hub.linkGroups(program: "safari", groupId: "s", targetProgram: "chrome", targetGroupId: "c"))
            hub.applySync(program: "safari", groupId: "s", contribution: ["scopes": [self.site("safari.example", except: true)]], ts: 0)
        })
        let last = try latestCluster(recorder.all())
        XCTAssertEqual(Set(sites(last).flatMap { $0["sites"] as? [String] ?? [] }), ["chrome.example", "edge.example", "safari.example"])
        XCTAssertEqual(shared(last)["usageMs"] as? Double, 1100)
        XCTAssertEqual(shared(last)["ts"] as? Double, policyTimestamp, "Equal policy timestamps cannot detect this ordering bug")
    }
    func testFullReconnectSnapshotIsSentBeforeLaterDeletionAndCannotResurrectEntry() throws {
        let recorder = Recorder(), outbound = DispatchQueue(label: "test.hub.outbound.reconnect")
        let hub = ConnectionHub(testOutboundQueue: outbound, outboundDelivery: recorder.deliver)
        setup(hub); outbound.sync {}
        let connection = NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
        recorder.arm { $0["kind"] as? String == "clusters" }
        interleave(recorder, outbound: outbound, first: { hub.sendClustersSnapshot(connection) }, second: {
            hub.applySync(program: "chrome", groupId: "c", contribution: ["scopes": [self.site("chrome.example")]], ts: 1)
        })
        let frames = recorder.all()
        let fullIndex = try XCTUnwrap(frames.lastIndex(where: { $0["kind"] as? String == "clusters" }))
        let updateIndex = try XCTUnwrap(frames.lastIndex(where: { $0["kind"] as? String == "cluster-updated" }))
        XCTAssertLessThan(fullIndex, updateIndex)
        XCTAssertEqual(sites(try latestCluster(frames)).flatMap { $0["sites"] as? [String] ?? [] }, ["chrome.example"])
        // Replay the browser's arrival-order full/partial registry replacement.
        var received: [String: Any]?
        for frame in frames {
            if let clusters = frame["clusters"] as? [[String: Any]] { received = clusters.first }
            if let cluster = frame["cluster"] as? [String: Any] { received = cluster }
        }
        let lines = (received?["shared"] as? [String: Any])?["scopes"] as? [[String: Any]]
        XCTAssertEqual(lines?.flatMap { $0["sites"] as? [String] ?? [] }, ["chrome.example"])
    }
    func testOlderUsageSnapshotCannotRestoreMembershipAfterExplicitUnlink() throws {
        let recorder = Recorder(), outbound = DispatchQueue(label: "test.hub.outbound.unlink")
        let hub = ConnectionHub(testOutboundQueue: outbound, outboundDelivery: recorder.deliver)
        setup(hub); outbound.sync {}
        recorder.arm { ($0["kind"] as? String) == "cluster-updated" && (self.shared($0)["usageMs"] as? Double) == 1100 }
        interleave(recorder, outbound: outbound, first: {
            hub.applySync(program: "chrome", groupId: "c", contribution: ["usageDeltaMs": 100.0], ts: 0)
        }, second: { XCTAssertNil(hub.unlinkGroup(program: "edge", groupId: "e")) })
        let last = try latestCluster(recorder.all())
        XCTAssertEqual(((last["cluster"] as? [String: Any])?["members"] as? [[String: Any]])?.count, 0, "Dissolved link tombstone must remain last")
    }
    func testOlderUsageSnapshotCannotRestoreMembershipAfterRosterRemoval() throws {
        let recorder = Recorder(), outbound = DispatchQueue(label: "test.hub.outbound.roster")
        let hub = ConnectionHub(testOutboundQueue: outbound, outboundDelivery: recorder.deliver)
        setup(hub); outbound.sync {}
        recorder.arm { ($0["kind"] as? String) == "cluster-updated" && (self.shared($0)["usageMs"] as? Double) == 1100 }
        interleave(recorder, outbound: outbound, first: {
            hub.applySync(program: "chrome", groupId: "c", contribution: ["usageDeltaMs": 100.0], ts: 0)
        }, second: { hub.setRoster(program: "edge", groups: []) })
        let last = try latestCluster(recorder.all())
        XCTAssertEqual(((last["cluster"] as? [String: Any])?["members"] as? [[String: Any]])?.count, 0)
        let roster = try XCTUnwrap(recorder.all().last(where: { $0["kind"] as? String == "rosters" }))
        XCTAssertEqual(((roster["rosters"] as? [String: Any])?["edge"] as? [[String: Any]])?.count, 0)
    }
    func testOlderUsageSnapshotCannotUndoBudgetPeriodRollover() throws {
        let recorder = Recorder(), outbound = DispatchQueue(label: "test.hub.outbound.rollover")
        let hub = ConnectionHub(testOutboundQueue: outbound, outboundDelivery: recorder.deliver)
        setup(hub); outbound.sync {}
        let before = try latestCluster(recorder.all())
        let anchor = try XCTUnwrap(shared(before)["usageResetAtMs"] as? Double)
        recorder.arm { ($0["kind"] as? String) == "cluster-updated" && (self.shared($0)["usageMs"] as? Double) == 1100 }
        interleave(recorder, outbound: outbound, first: {
            hub.applySync(program: "chrome", groupId: "c", contribution: ["usageDeltaMs": 100.0], ts: 0)
        }, second: { hub.rollSharedBudgets(nowMs: anchor + 25 * 3_600_000) })
        let last = try latestCluster(recorder.all())
        XCTAssertEqual(shared(last)["usageMs"] as? Double, 0)
        XCTAssertGreaterThan(try XCTUnwrap(shared(last)["usageResetAtMs"] as? Double), anchor)
        XCTAssertEqual(sites(last).count, 2)
    }
    func testFailedDetachWriteEnqueuesNoFalseMembershipAcknowledgement() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("outbound-refusal-\(UUID().uuidString)")
        let store = BlockerWebStore(shared: SharedAppGroupStore(baseDirectory: directory))
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        store.save(rawStore: ["blockedGroups": [["id": "m", "name": "Mac", "enabled": false,
                                                 "scopes": [["surface": "apps", "apps": []]]]]])
        let recorder = Recorder(), outbound = DispatchQueue(label: "test.hub.outbound.refusal")
        let hub = ConnectionHub(testOutboundQueue: outbound, outboundDelivery: recorder.deliver)
        setup(hub); hub.localWebStore = store
        hub.setRoster(program: "macapp", groups: [["id": "m", "name": "Mac"]])
        XCTAssertNil(hub.linkGroups(program: "macapp", groupId: "m", targetProgram: "chrome", targetGroupId: "c"))
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(store.loadRawJSON()).utf8)) as? [String: Any])
        hub.contributeLocalDefinitions(document: document, nowMs: Date().timeIntervalSince1970 * 1000)
        outbound.sync {}
        let before = recorder.all().count, bytes = try Data(contentsOf: store.fileURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        XCTAssertEqual(hub.unlinkGroup(program: "macapp", groupId: "m"), "local-storage-unavailable")
        outbound.sync {}
        XCTAssertEqual(recorder.all().count, before, "No outgoing detach before its atomic storage save succeeds")
        XCTAssertNotNil(hub.sharedUsage(groupID: "m"))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), bytes)
    }

}
