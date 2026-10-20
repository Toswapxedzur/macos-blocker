#if os(macOS)
import Foundation
import Network
import XCTest
import MacBlockerCore
import MacBlockerWebUI
import VaultClassifierBridge
import VaultClassifierCore
@testable import MacBlockerAppFeature

final class BootstrapUsageTests: XCTestCase {
    private var suites: [String] = []
    private var connections: [NWConnection] = []
    override func tearDown() {
        connections.forEach { $0.cancel() }
        suites.forEach { UserDefaults.standard.removePersistentDomain(forName: $0) }
        super.tearDown()
    }
    private final class Frames {
        let queue = DispatchQueue(label: "Agentic.BootstrapUsage.Frames")
        var values: [[String: Any]] = []
        func all() -> [[String: Any]] { queue.sync { values } }
        func clear() { queue.sync { values.removeAll() } }
        func cluster() throws -> [String: Any] {
            try XCTUnwrap(all().reversed().compactMap { ($0["cluster"] as? [String: Any]) ?? ($0["clusters"] as? [[String: Any]])?.first }.first)
        }
        func shared() throws -> [String: Any] { try XCTUnwrap(try cluster()["shared"] as? [String: Any]) }
        func generation() throws -> String { try XCTUnwrap((try shared()["browserIdentityStatus"] as? [String: Any])?["generation"] as? String) }
        func contributed() throws -> Bool { try XCTUnwrap((try cluster()["members"] as? [[String: Any]])?.first { $0["program"] as? String == "chrome" }?["contributed"] as? Bool) }
    }
    private func hub(_ defaults: UserDefaults? = nil) -> (ConnectionHub, Frames, UserDefaults) {
        let name = "Agentic.BootstrapUsage." + UUID().uuidString
        let defaults = defaults ?? UserDefaults(suiteName: name)!
        if defaults.volatileDomainNames.contains(name) == false { suites.append(name) }
        let frames = Frames()
        let hub = ConnectionHub(testOutboundQueue: frames.queue, registryDefaults: defaults,
            browserIdentityBudgetPredicate: { scalars, scopes, _ in BrowserIdentityBudgetPolicy.affects(scalars, scopes: scopes, browserBundleIDs: ["com.google.chrome"]) },
            outboundDelivery: { data in frames.values.append((try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]) })
        return (hub, frames, defaults)
    }
    private func policy(rolling: Bool = false, enabled: Bool = true, minutes: Int = 30) -> [String: Any] {
        ["groupType": "site", "mode": "after-minutes", "enabled": enabled, "allowedMinutes": minutes,
         "resetIntervalHours": 24, "resetAtMidnight": false, "rollingLimit": rolling]
    }
    private func stage(_ hub: ConnectionHub, rolling: Bool = false, nativeFirst: Bool = true, initiator: String = "macapp") throws -> Double {
        hub.setRoster(program: "macapp", groups: [["id": "m", "name": "Native"]])
        hub.setRoster(program: "chrome", groups: [["id": "b", "name": "Browser"]])
        XCTAssertNil(hub.linkGroups(program: initiator, groupId: initiator == "macapp" ? "m" : "b", targetProgram: initiator == "macapp" ? "chrome" : "macapp", targetGroupId: initiator == "macapp" ? "b" : "m"))
        let anchor = (Date().timeIntervalSince1970 * 1000 - 2_000).rounded(.down)
        if nativeFirst { hub.applySync(program: "macapp", groupId: "m", contribution: nativeOriginal(rolling: rolling, anchor: anchor), ts: 0) }
        return anchor
    }
    private func nativeOriginal(rolling: Bool, anchor: Double) -> [String: Any] {
        var frame: [String: Any] = ["scalars": policy(rolling: rolling), "scopes": [["surface": "apps", "apps": [["id": "com.example.Editor"]]]], "usageMs": 5_000.0, "usageResetAtMs": anchor]
        if rolling { frame["usageBucketsSeed"] = [String(Int64((anchor / 60_000).rounded(.down) * 60_000)): 5_000.0] }
        return frame
    }
    private func register(_ hub: ConnectionHub, capability: Bool = false, identity: Bool = false) throws -> (NWConnection, String?) {
        let connection = NWConnection(host: "127.0.0.1", port: 18787, using: .tcp)
        connections.append(connection)
        hub.registerPendingPeer(connection, challenge: String(repeating: "a", count: 43))
        let descriptor = identity ? try XCTUnwrap(BrowserApplicationIdentity(kind: "mac-bundle-id", value: "com.google.chrome")) : nil
        return (connection, hub.admitAuthenticatedPeer(connection, program: "chrome", browserIdentity: descriptor, supportsOriginalUsage: capability))
    }
    private func send(_ hub: ConnectionHub, _ connection: NWConnection, _ payload: [String: Any], generation: String? = nil) throws {
        var frame = payload; frame["kind"] = "group-sync"; frame["groupId"] = "b"
        if let generation { frame["browserIdentitySnapshotApplied"] = ["generation": generation] }
        hub.handleIncoming(connection, key: ObjectIdentifier(connection), data: try JSONSerialization.data(withJSONObject: frame))
    }
    private func definition(rolling: Bool = false, enabled: Bool = true) -> [String: Any] {
        ["scalars": policy(rolling: rolling, enabled: enabled), "scopes": [["surface": "site", "sites": ["example.com"]]], "ts": 0.0]
    }
    private func row(_ defaults: UserDefaults) throws -> [String: Any] {
        let data = try XCTUnwrap(defaults.data(forKey: "ConnectionHub.clusters.v2"))
        let payload = try StorageSchemaPolicy(format: "hub.clusters", currentSchema: 3).payload(from: data)
        return try XCTUnwrap((try JSONSerialization.jsonObject(with: payload) as? [[String: Any]])?.first)
    }
    private func canonical(_ hub: ConnectionHub) throws -> [String: Any] {
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(hub.clustersJSON().utf8)) as? [String: Any])
        return try XCTUnwrap((root["clusters"] as? [[String: Any]])?.first?["shared"] as? [String: Any])
    }

    func testDefinitionOnlyFixedJoinRetainsOriginalAndPendingAcrossRestart() throws {
        let (first, firstFrames, defaults) = hub(); let anchor = try stage(first)
        let (legacy, refusal) = try register(first); XCTAssertNil(refusal)
        XCTAssertNil(try firstFrames.cluster()["shared"])
        try send(first, legacy, definition())
        XCTAssertFalse(try firstFrames.contributed())
        for field in ["usageMs", "usageResetAtMs", "usageBuckets"] { XCTAssertNil(try firstFrames.shared()[field]) }
        XCTAssertTrue((try row(defaults)["contributed"] as? [String] ?? []).contains("chrome"))
        XCTAssertEqual(try row(defaults)["originalUsagePending"] as? [String], ["chrome"])
        first.removePeer(ObjectIdentifier(legacy))
        first.applySync(program: "macapp", groupId: "m", contribution: ["usageDeltaMs": 1_000.0], ts: 0)
        first.applySync(program: "macapp", groupId: "m", contribution: ["scalars": policy(enabled: false)], ts: Date().timeIntervalSince1970 * 1000)
        let (restarted, frames, _) = hub(defaults); restarted.restoreClustersLocked()
        let (updated, updatedRefusal) = try register(restarted, capability: true, identity: true); XCTAssertNil(updatedRefusal)
        let originalGeneration = try frames.generation()
        try send(restarted, updated, [:], generation: originalGeneration)
        var original = definition(enabled: true); original["usageMs"] = 8_000.0; original["usageResetAtMs"] = anchor
        try send(restarted, updated, original, generation: originalGeneration)
        XCTAssertEqual(try XCTUnwrap(restarted.sharedUsage(groupID: "m")).ms, 9_000)
        XCTAssertEqual((try canonical(restarted)["scalars"] as? [String: Any])?["enabled"] as? Bool, false)
        XCTAssertTrue(try frames.contributed())
        XCTAssertFalse(try frames.generation() == originalGeneration)
        XCTAssertEqual(try row(defaults)["originalUsagePending"] as? [String], [])
    }

    func testPendingAbsoluteIncludesItsDeltaAndNativeKeepsDeltaOrSeedSemantics() throws {
        let (hub, frames, _) = hub(); let anchor = try stage(hub)
        let (peer, refusal) = try register(hub); XCTAssertNil(refusal)
        // Tagged3.1 sends definitions separately and retains a prior link's
        // baseline; its first later report includes current absolute+delta.
        try send(hub, peer, definition())
        XCTAssertFalse(try frames.contributed())
        try send(hub, peer, ["usageMs": 8_000.0, "usageResetAtMs": anchor, "usageDeltaMs": 1_000.0])
        XCTAssertEqual(try XCTUnwrap(hub.sharedUsage(groupID: "m")).ms, 8_000)
        XCTAssertTrue(try frames.contributed())
        try send(hub, peer, ["usageMs": 9_000.0, "usageResetAtMs": anchor, "usageDeltaMs": 1_000.0])
        XCTAssertEqual(try XCTUnwrap(hub.sharedUsage(groupID: "m")).ms, 9_000)
        XCTAssertTrue(try frames.contributed())
        let (native, _, _) = self.hub(); _ = try stage(native, nativeFirst: false)
        var nativeFrame = nativeOriginal(rolling: false, anchor: anchor); nativeFrame["usageDeltaMs"] = 1_000.0
        native.applySync(program: "macapp", groupId: "m", contribution: nativeFrame, ts: 0)
        XCTAssertEqual(try XCTUnwrap(native.sharedUsage(groupID: "m")).ms, 1_000)
    }

    func testRollingLegacyRefusesBeforeWelcomeAndWhenPolicyIsFirstDiscovered() throws {
        let (known, frames, _) = hub(); _ = try stage(known, rolling: true); frames.clear()
        let (_, refusal) = try register(known)
        XCTAssertEqual(refusal, "browser-upgrade-required")
        XCTAssertFalse(frames.all().contains { ["welcome", "clusters", "cluster-updated"].contains($0["kind"] as? String ?? "") })
        let (unknown, unknownFrames, _) = hub(); _ = try stage(unknown, nativeFirst: false, initiator: "chrome"); unknownFrames.clear()
        let (legacy, initialRefusal) = try register(unknown); XCTAssertNil(initialRefusal)
        XCTAssertNil(try unknownFrames.cluster()["shared"])
        try send(unknown, legacy, definition(rolling: true))
        XCTAssertTrue(unknownFrames.all().contains { $0["kind"] as? String == "rejected" && $0["reason"] as? String == "browser-upgrade-required" })
        // The test observer also records canonical broadcasts with zero destinations.
        // Only frames queued before retirement can reach this legacy peer.
        XCTAssertEqual(unknown.activityNotificationRecipients, [])
        XCTAssertFalse(unknownFrames.all().prefix { $0["kind"] as? String != "rejected" }.contains { ($0["cluster"] as? [String: Any])?["shared"] != nil
            || (($0["clusters"] as? [[String: Any]]) ?? []).contains { $0["shared"] != nil } })
    }

    func testUpdatedRollingRetainsOriginalBucketsBeforeCompleteGeneration() throws {
        let (hub, frames, defaults) = hub(); let anchor = try stage(hub, rolling: true)
        let (peer, refusal) = try register(hub, capability: true, identity: true); XCTAssertNil(refusal)
        let generation = try frames.generation(); try send(hub, peer, [:], generation: generation)
        try send(hub, peer, definition(rolling: true), generation: generation)
        XCTAssertFalse(try frames.contributed())
        let minute = (anchor / 60_000).rounded(.down) * 60_000, key = String(Int64(minute))
        hub.applySync(program: "macapp", groupId: "m", contribution: ["usageBuckets": [key: 1_000.0]], ts: 0)
        try send(hub, peer, ["usageBucketsSeed": [key: 8_000.0], "usageResetAtMs": anchor], generation: generation)
        XCTAssertEqual(try XCTUnwrap(hub.sharedUsage(groupID: "m")).buckets[minute], 9_000)
        XCTAssertTrue(try frames.contributed())
        XCTAssertFalse(try frames.generation() == generation)
        XCTAssertEqual(try row(defaults)["originalUsagePending"] as? [String], [])
    }

    func testFailedOriginalSaveKeepsPendingAndDoesNotPublishCompletion() throws {
        let (hub, frames, defaults) = hub(); let anchor = try stage(hub)
        let (peer, refusal) = try register(hub, capability: true, identity: true); XCTAssertNil(refusal)
        let generation = try frames.generation(); try send(hub, peer, [:], generation: generation)
        try send(hub, peer, definition(), generation: generation)
        let good = try XCTUnwrap(defaults.data(forKey: "ConnectionHub.clusters.v2")), count = frames.all().count
        let unsupported = Data("unsupported original registry bytes".utf8)
        defaults.set(unsupported, forKey: "ConnectionHub.clusters.v2")
        try send(hub, peer, ["usageMs": 8_000.0, "usageResetAtMs": anchor, "usageDeltaMs": 1_000.0], generation: generation)
        XCTAssertEqual(try XCTUnwrap(hub.sharedUsage(groupID: "m")).ms, 5_000)
        XCTAssertEqual(defaults.data(forKey: "ConnectionHub.clusters.v2"), unsupported)
        XCTAssertFalse(frames.all().dropFirst(count).contains { $0["kind"] as? String == "cluster-updated" })
        XCTAssertTrue(frames.all().dropFirst(count).contains { $0["reason"] as? String == "local-storage-unavailable" })
        defaults.set(good, forKey: "ConnectionHub.clusters.v2")
        let (restarted, fresh, _) = self.hub(defaults); restarted.restoreClustersLocked()
        let (replacement, retryRefusal) = try register(restarted, capability: true, identity: true); XCTAssertNil(retryRefusal)
        let retryGeneration = try fresh.generation()
        try send(restarted, replacement, ["usageMs": 8_000.0, "usageResetAtMs": anchor, "usageDeltaMs": 1_000.0], generation: retryGeneration)
        XCTAssertEqual(try XCTUnwrap(restarted.sharedUsage(groupID: "m")).ms, 8_000)
        XCTAssertTrue(try fresh.contributed())
    }

    func testExpiredFixedAndRollingOriginalsCompleteWithoutResurrection() throws {
        for rolling in [false, true] {
            let (hub, frames, defaults) = hub(); let anchor = try stage(hub, rolling: rolling)
            let (peer, refusal) = try register(hub, capability: true, identity: true); XCTAssertNil(refusal)
            let generation = try frames.generation(); try send(hub, peer, [:], generation: generation)
            try send(hub, peer, definition(rolling: rolling), generation: generation)
            if rolling {
                let expired = String(Int64((anchor / 60_000).rounded(.down) * 60_000 - 25 * 3_600_000))
                try send(hub, peer, ["usageBucketsSeed": [expired: 8_000.0], "usageResetAtMs": anchor], generation: generation)
                XCTAssertEqual(try XCTUnwrap(hub.sharedUsage(groupID: "m")).buckets.values.reduce(0, +), 5_000)
            } else {
                var resetPolicy = policy(minutes: 20); resetPolicy["resetIntervalHours"] = 12
                hub.applySync(program: "macapp", groupId: "m", contribution: ["scalars": resetPolicy], ts: Date().timeIntervalSince1970 * 1000)
                hub.applySync(program: "macapp", groupId: "m", contribution: ["usageDeltaMs": 1_000.0], ts: 0)
                try send(hub, peer, ["usageMs": 8_000.0, "usageResetAtMs": anchor], generation: generation)
                XCTAssertEqual(try XCTUnwrap(hub.sharedUsage(groupID: "m")).ms, 1_000)
            }
            XCTAssertTrue(try frames.contributed())
            XCTAssertEqual(try row(defaults)["originalUsagePending"] as? [String], [])
        }
    }

    func testHistoricalCompletedRollingRowsDefaultReadyWithoutNewField() throws {
        let (hub, frames, defaults) = hub(); let anchor = try stage(hub, rolling: true)
        let (peer, refusal) = try register(hub, capability: true, identity: true); XCTAssertNil(refusal)
        let generation = try frames.generation(); try send(hub, peer, [:], generation: generation)
        var original = definition(rolling: true)
        original["usageBucketsSeed"] = [String(Int64((anchor / 60_000).rounded(.down) * 60_000)): 8_000.0]; original["usageResetAtMs"] = anchor
        try send(hub, peer, original, generation: generation)
        var saved = try row(defaults); saved.removeValue(forKey: "originalUsagePending")
        let payload = try JSONSerialization.data(withJSONObject: [saved])
        defaults.set(try StorageSchemaPolicy(format: "hub.clusters", currentSchema: 2).wrap(payload), forKey: "ConnectionHub.clusters.v2")
        let (restarted, fresh, _) = self.hub(defaults); restarted.restoreClustersLocked()
        let (_, legacyRefusal) = try register(restarted); XCTAssertNil(legacyRefusal)
        XCTAssertTrue(try fresh.contributed())
        XCTAssertNotNil(try fresh.shared()["usageBuckets"])
    }

    func testSchemaThreePreservesPendingAndRejectsDowngradeOrMissingLedger() throws {
        let (hub, _, defaults) = hub(); _ = try stage(hub)
        let bytes = try XCTUnwrap(defaults.data(forKey: "ConnectionHub.clusters.v2"))
        XCTAssertThrowsError(try StorageSchemaPolicy(format: "hub.clusters", currentSchema: 2).payload(from: bytes))
        let payload = try StorageSchemaPolicy(format: "hub.clusters", currentSchema: 3).payload(from: bytes)
        XCTAssertEqual(try row(defaults)["originalUsagePending"] as? [String], ["chrome"])
        var historical = try XCTUnwrap((try JSONSerialization.jsonObject(with: payload)) as? [[String: Any]])
        historical[0].removeValue(forKey: "originalUsagePending")
        let oldPayload = try JSONSerialization.data(withJSONObject: historical)
        defaults.set(try StorageSchemaPolicy(format: "hub.clusters", currentSchema: 2).wrap(oldPayload), forKey: "ConnectionHub.clusters.v2")
        let (migrated, _, _) = self.hub(defaults); migrated.restoreClustersLocked()
        let (legacy, refusal) = try register(migrated); XCTAssertNil(refusal)
        try send(migrated, legacy, definition())
        XCTAssertEqual(try row(defaults)["originalUsagePending"] as? [String], ["chrome"])
        let migratedBytes = try XCTUnwrap(defaults.data(forKey: "ConnectionHub.clusters.v2"))
        XCTAssertThrowsError(try StorageSchemaPolicy(format: "hub.clusters", currentSchema: 2).payload(from: migratedBytes))
        let invalid = try StorageSchemaPolicy(format: "hub.clusters", currentSchema: 3).wrap(oldPayload)
        defaults.set(invalid, forKey: "ConnectionHub.clusters.v2")
        let (refusing, _, _) = self.hub(defaults); refusing.restoreClustersLocked()
        XCTAssertEqual(refusing.activeClusterCount(), 0)
        refusing.setRoster(program: "chrome", groups: [])
        XCTAssertEqual(defaults.data(forKey: "ConnectionHub.clusters.v2"), invalid)
    }

    func testTentativeNoninitiatorRollingPolicyDoesNotRefuseFixedInitiator() throws {
        let (hub, frames, _) = hub(); _ = try stage(hub, rolling: true, initiator: "chrome")
        let (legacy, refusal) = try register(hub); XCTAssertNil(refusal)
        hub.setRoster(program: "edge", groups: [["id": "e", "name": "Edge"]])
        XCTAssertNil(hub.linkGroups(program: "chrome", groupId: "b", targetProgram: "edge", targetGroupId: "e"))
        try send(hub, legacy, definition())
        XCTAssertEqual((try canonical(hub)["scalars"] as? [String: Any])?["rollingLimit"] as? Bool, false)
        XCTAssertEqual(hub.activityNotificationRecipients, ["chrome"])
        XCTAssertFalse(frames.all().contains { $0["kind"] as? String == "rejected" })
    }

    func testKnownNewRollingPreflightRefusesBeforeLinkOrFileMutation() throws {
        let (hub, frames, defaults) = hub()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Agentic.BootstrapPreflight." + UUID().uuidString)
        defer { hub.localWebStore = nil; try? FileManager.default.removeItem(at: directory) }
        let store = BlockerWebStore(shared: SharedAppGroupStore(baseDirectory: directory))
        var group = policy(rolling: true); group["id"] = "m"; group["name"] = "Native"; group["scopes"] = [["surface": "apps", "apps": [["id": "com.example.Editor"]]]]
        store.save(rawStore: ["blockedGroups": [group], "usageTimersMs": ["m": 5_000.0]])
        hub.localWebStore = store; hub.hostingLocalHub = true
        hub.contributeLocalDefinitions(document: [:], nowMs: Date().timeIntervalSince1970 * 1000)
        hub.setRoster(program: "chrome", groups: [["id": "b", "name": "Browser"]])
        let (_, refusal) = try register(hub); XCTAssertNil(refusal)
        let before = store.loadRawJSON(), registry = defaults.data(forKey: "ConnectionHub.clusters.v2")
        let signal = DispatchSemaphore(value: 0); var result: String?
        hub.linkGroupsWithBrowserIdentityPreflight(program: "macapp", groupId: "m", targetProgram: "chrome", targetGroupId: "b") { result = $0; signal.signal() }
        XCTAssertEqual(signal.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(result, "browser-upgrade-required")
        XCTAssertEqual(hub.activeClusterCount(), 0)
        XCTAssertEqual(store.loadRawJSON(), before)
        XCTAssertEqual(defaults.data(forKey: "ConnectionHub.clusters.v2"), registry)
        XCTAssertFalse(frames.all().contains { $0["kind"] as? String == "cluster-updated" })
    }
}
#endif
