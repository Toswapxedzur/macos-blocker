import XCTest
@testable import MacBlockerAppFeature
import MacBlockerCore
import MacBlockerWebUI

/// Detaching must persist the hub budget even when a disabled Mac group never
/// visits the enabled-only enforcement loop, and before another tick can run.
final class ClusterDetachedRuntimeTests: XCTestCase {
    private let apps: [[String: Any]] = [["id": "apps-1", "surface": "apps", "apps": [["id": "com.example.Game"]]]]
    private let sites: [[String: Any]] = [["id": "site-1", "surface": "site", "sites": ["example.com"]]]

    private func raw(_ store: BlockerWebStore) throws -> [String: Any] {
        let text = try XCTUnwrap(store.loadRawJSON())
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
    private func number(_ document: [String: Any], _ key: String, _ id: String = "m1") -> Double? {
        ((document[key] as? [String: Any])?[id] as? NSNumber)?.doubleValue
    }
    private func fixture(rolling: Bool) throws -> (ConnectionHub, BlockerWebStore, URL, Double) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("detached-runtime-\(UUID().uuidString)")
        let store = BlockerWebStore(shared: SharedAppGroupStore(baseDirectory: directory))
        let now = (Date().timeIntervalSince1970 * 1000).rounded(.down)
        store.save(rawStore: [
            "blockedGroups": [["id": "m1", "name": "Mac", "enabled": false, "mode": "after-minutes", "allowedMinutes": 10,
                               "resetIntervalHours": 24, "rollingLimit": rolling, "scopes": apps],
                              ["id": "other", "name": "Untouched", "enabled": false]],
            "usageTimersMs": ["m1": 5_000.0, "other": 73.0], "usageResetAtMs": ["m1": now],
            "usageBucketsMs": ["m1": UsageBudget.bucketJSON([UsageBudget.bucketStartMs(now): 5_000])],
            "globalSettings": ["sentinel": "preserve"], "cbRuleState": ["other": ["sentinel": 17]]
        ])
        let hub = ConnectionHub(); hub.hostingLocalHub = true; hub.localWebStore = store
        hub.setRoster(program: "macapp", groups: [["id": "m1", "name": "Mac"], ["id": "other", "name": "Untouched"]])
        hub.setRoster(program: "chrome", groups: [["id": "c1", "name": "Browser"]])
        XCTAssertNil(hub.linkGroups(program: "chrome", groupId: "c1", targetProgram: "macapp", targetGroupId: "m1"))
        hub.contributeLocalDefinitions(document: try raw(store), nowMs: now)
        hub.applySync(program: "chrome", groupId: "c1", contribution: [
            "scalars": ["name": "Browser", "enabled": false, "mode": "after-minutes", "allowedMinutes": 20,
                        "resetIntervalHours": 24, "rollingLimit": rolling], "scopes": sites,
            "usageMs": 240_000.0, "usageResetAtMs": now,
            "usageBucketsSeed": UsageBudget.bucketJSON([UsageBudget.bucketStartMs(now) - 60_000: 100_000,
                                                       UsageBudget.bucketStartMs(now): 140_000])
        ], ts: 0)
        // Count a completed break, then retain the current break and cooldown.
        let finished: [String: Any] = ["startsAtMs": now - 600_000, "untilMs": now - 300_000,
                                      "cooldownUntilMs": now - 300_000, "changedAtMs": now - 600_000]
        hub.applySync(program: "chrome", groupId: "c1", contribution: ["snooze": finished, "snoozeTs": now - 600_000], ts: 0)
        let active: [String: Any] = ["startsAtMs": now, "untilMs": now + 60_000,
                                    "cooldownUntilMs": now + 360_000, "changedAtMs": now]
        hub.applySync(program: "chrome", groupId: "c1", contribution: ["snooze": active, "snoozeTs": now], ts: 0)
        return (hub, store, directory, now)
    }

    func testDisabledDetachPersistsBeforeTickForBothBudgetKindsAndRemovalPaths() throws {
        for rolling in [false, true] {
            for path in ["mac", "browser", "roster"] {
                let (hub, store, directory, now) = try fixture(rolling: rolling)
                defer { try? FileManager.default.removeItem(at: directory) }
                let before = try XCTUnwrap(hub.sharedUsage(groupID: "m1"))
                if path == "roster" { hub.setRoster(program: "chrome", groups: []) }
                else { XCTAssertNil(hub.unlinkGroup(program: path == "mac" ? "macapp" : "chrome", groupId: path == "mac" ? "m1" : "c1")) }
                XCTAssertNil(hub.sharedUsage(groupID: "m1"))
                let reopened = BlockerWebStore(shared: SharedAppGroupStore(baseDirectory: directory))
                let document = try raw(reopened)
                let group = try XCTUnwrap((document["blockedGroups"] as? [[String: Any]])?.first { ($0["id"] as? String) == "m1" })
                XCTAssertEqual(group["enabled"] as? Bool, false)
                XCTAssertEqual(group["allowedMinutes"] as? Int, 20)
                XCTAssertEqual((group["scopes"] as? [[String: Any]])?.compactMap { $0["surface"] as? String }, ["apps"])
                XCTAssertEqual(number(document, "usageTimersMs"), rolling ? UsageBudget.usedMs(before.buckets) : before.ms)
                XCTAssertEqual(number(document, "usageResetAtMs"), before.resetAtMs)
                if rolling {
                    let buckets = try XCTUnwrap(UsageBudget.parseBuckets((document["usageBucketsMs"] as? [String: Any])?["m1"]))
                    XCTAssertEqual(buckets, before.buckets)
                }
                let snooze = try XCTUnwrap((document["groupSnoozes"] as? [String: Any])?["m1"] as? [String: Any])
                XCTAssertEqual((snooze["untilMs"] as? NSNumber)?.doubleValue, now + 60_000)
                XCTAssertEqual((snooze["cooldownUntilMs"] as? NSNumber)?.doubleValue, now + 360_000)
                XCTAssertEqual(number(document, "groupSnoozeTotalsMs"), 300_000)
                XCTAssertEqual(number(document, "usageTimersMs", "other"), 73)
                XCTAssertEqual((document["globalSettings"] as? [String: Any])?["sentinel"] as? String, "preserve")
                XCTAssertEqual(((document["cbRuleState"] as? [String: Any])?["other"] as? [String: Any])?["sentinel"] as? Int, 17)
            }
        }
    }

    func testRelinkAfterReopenKeepsDetachedUsageAndCountsNextDeltaOnce() throws {
        for rolling in [false, true] {
            let (hub, store, directory, now) = try fixture(rolling: rolling)
            defer { try? FileManager.default.removeItem(at: directory) }
            XCTAssertNil(hub.unlinkGroup(program: "chrome", groupId: "c1"))
            let reopened = BlockerWebStore(shared: SharedAppGroupStore(baseDirectory: directory))
            let fresh = ConnectionHub(); fresh.hostingLocalHub = true; fresh.localWebStore = reopened
            fresh.setRoster(program: "macapp", groups: [["id": "m1", "name": "Browser"]])
            fresh.setRoster(program: "chrome", groups: [["id": "c1", "name": "Browser"]])
            XCTAssertNil(fresh.linkGroups(program: "macapp", groupId: "m1", targetProgram: "chrome", targetGroupId: "c1"))
            fresh.contributeLocalDefinitions(document: try raw(reopened), nowMs: now)
            fresh.applySync(program: "chrome", groupId: "c1", contribution: ["scalars": ["mode": "after-minutes", "rollingLimit": rolling], "scopes": sites, "usageMs": 1_000.0, "usageResetAtMs": now], ts: 0)
            let before = try XCTUnwrap(fresh.sharedUsage(groupID: "m1"))
            let delta: [String: Any] = rolling ? ["usageBuckets": UsageBudget.bucketJSON([UsageBudget.bucketStartMs(now): 2_000])] : ["usageDeltaMs": 2_000.0]
            fresh.applySync(program: "chrome", groupId: "c1", contribution: delta, ts: 0)
            let after = try XCTUnwrap(fresh.sharedUsage(groupID: "m1"))
            XCTAssertEqual(rolling ? UsageBudget.usedMs(after.buckets) : after.ms, (rolling ? UsageBudget.usedMs(before.buckets) : before.ms) + 2_000)
            XCTAssertEqual(number(try raw(store), "usageTimersMs"), 240_000, "no stale detached queue writes or echo into the saved source")
        }
    }

    func testNewerLocalSchemaRefusesDetachWithoutChangingFileOrMembership() throws {
        let (hub, store, directory, _) = try fixture(rolling: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        var document = try raw(store)
        var metadata = try XCTUnwrap(document["storageMetadata"] as? [String: Any])
        metadata["schemaVersion"] = 999; document["storageMetadata"] = metadata
        let future = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        try future.write(to: store.fileURL, options: [.atomic])
        XCTAssertEqual(hub.unlinkGroup(program: "chrome", groupId: "c1"), "local-storage-unavailable")
        XCTAssertNotNil(hub.sharedUsage(groupID: "m1"))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), future)
    }

    func testDeletedLocalGroupIsNotRecreatedOnBrowserRemoval() throws {
        let (hub, store, directory, _) = try fixture(rolling: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        store.save(rawStore: ["blockedGroups": [["id": "other", "name": "Untouched", "enabled": false]], "usageTimersMs": ["other": 73.0]])
        hub.setRoster(program: "chrome", groups: [])
        let document = try raw(store)
        XCTAssertEqual((document["blockedGroups"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, ["other"])
        XCTAssertNil(number(document, "usageTimersMs"))
    }

    func testAtomicWriteFailureKeepsBytesAndMembership() throws {
        let (hub, store, directory, _) = try fixture(rolling: false)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let before = try Data(contentsOf: store.fileURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        XCTAssertEqual(hub.unlinkGroup(program: "chrome", groupId: "c1"), "local-storage-unavailable")
        XCTAssertNotNil(hub.sharedUsage(groupID: "m1"))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), before)
    }

    func testDetachBeforeMacOriginalContributesKeepsOwnLinesAndSharedInitiatorSettingsAndRuntime() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("detached-original-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BlockerWebStore(shared: SharedAppGroupStore(baseDirectory: directory))
        let now = (Date().timeIntervalSince1970 * 1000).rounded(.down)
        store.save(rawStore: ["blockedGroups": [["id": "m1", "name": "Original", "enabled": false,
                                                "mode": "after-minutes", "allowedMinutes": 10, "scopes": apps]],
                             "usageTimersMs": ["m1": 5_000.0], "usageResetAtMs": ["m1": now]])
        let hub = ConnectionHub(); hub.hostingLocalHub = true; hub.localWebStore = store
        hub.setRoster(program: "macapp", groups: [["id": "m1", "name": "Original"]])
        hub.setRoster(program: "chrome", groups: [["id": "c1", "name": "Foreign"]])
        XCTAssertNil(hub.linkGroups(program: "chrome", groupId: "c1", targetProgram: "macapp", targetGroupId: "m1"))
        hub.applySync(program: "chrome", groupId: "c1", contribution: [
            "scalars": ["name": "Foreign", "enabled": false, "mode": "after-minutes", "allowedMinutes": 20],
            "scopes": sites, "usageMs": 240_000.0, "usageResetAtMs": now
        ], ts: 0)
        XCTAssertNil(hub.unlinkGroup(program: "chrome", groupId: "c1"))
        let document = try raw(store)
        let group = try XCTUnwrap((document["blockedGroups"] as? [[String: Any]])?.first)
        XCTAssertEqual(group["name"] as? String, "Foreign")
        XCTAssertEqual(group["allowedMinutes"] as? Int, 20)
        XCTAssertEqual((group["scopes"] as? [[String: Any]])?.compactMap { $0["surface"] as? String }, ["apps"])
        XCTAssertEqual(number(document, "usageTimersMs"), 240_000)
        XCTAssertEqual(number(document, "usageResetAtMs"), now)
    }

    func testAuthoritativeZeroOnDetachClearsStaleAnchorBucketsAndSnoozeTotals() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("detached-zero-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BlockerWebStore(shared: SharedAppGroupStore(baseDirectory: directory))
        store.save(rawStore: ["blockedGroups": [["id": "m1", "name": "Original", "enabled": false, "scopes": apps]],
                             "usageTimersMs": ["m1": 5_000.0], "usageResetAtMs": ["m1": 1000.0],
                             "usageBucketsMs": ["m1": ["1000": 5000.0]],
                             "groupSnoozes": ["m1": ["startsAtMs": 1000.0, "untilMs": 9_999_999_999_999.0]],
                             "groupSnoozeTotalsMs": ["m1": 90_000.0]])
        let hub = ConnectionHub(); hub.hostingLocalHub = true; hub.localWebStore = store
        hub.setRoster(program: "macapp", groups: [["id": "m1", "name": "Original"]])
        hub.setRoster(program: "chrome", groups: [["id": "c1", "name": "Browser"]])
        XCTAssertNil(hub.linkGroups(program: "chrome", groupId: "c1", targetProgram: "macapp", targetGroupId: "m1"))
        XCTAssertNil(hub.unlinkGroup(program: "chrome", groupId: "c1"))
        let document = try raw(store)
        XCTAssertEqual(number(document, "usageTimersMs"), 0)
        XCTAssertNil(number(document, "usageResetAtMs"))
        XCTAssertEqual(UsageBudget.parseBuckets((document["usageBucketsMs"] as? [String: Any])?["m1"]), [:])
        XCTAssertEqual(((document["groupSnoozes"] as? [String: Any])?["m1"] as? [String: Any])?.isEmpty, true)
        XCTAssertEqual(number(document, "groupSnoozeTotalsMs"), 0)
    }

    func testPreackAdoptionEndsSnoozeWithoutAdoptingOriginalUsageOrDefinition() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("detached-end-snooze-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory); GroupStore.sharedOverlay = nil }
        let store = BlockerWebStore(shared: SharedAppGroupStore(baseDirectory: directory))
        let now = (Date().timeIntervalSince1970 * 1000).rounded(.down)
        store.save(rawStore: ["blockedGroups": [["id": "m1", "name": "Original", "allowedMinutes": 10, "enabled": false, "scopes": apps]],
                             "usageTimersMs": ["m1": 5_000.0], "usageResetAtMs": ["m1": now],
                             "groupSnoozes": ["m1": ["startsAtMs": now - 1000, "untilMs": now + 600_000, "changedAtMs": now - 1000]]])
        let hub = ConnectionHub(); hub.hostingLocalHub = true; hub.localWebStore = store
        hub.setRoster(program: "macapp", groups: [["id": "m1", "name": "Original"]])
        hub.setRoster(program: "chrome", groups: [["id": "c1", "name": "Foreign"]])
        XCTAssertNil(hub.linkGroups(program: "chrome", groupId: "c1", targetProgram: "macapp", targetGroupId: "m1"))
        hub.applySync(program: "chrome", groupId: "c1", contribution: [
            "scalars": ["name": "Foreign", "allowedMinutes": 20], "usageMs": 240_000.0, "usageResetAtMs": now,
            "snooze": ["startsAtMs": now - 1000, "untilMs": now, "cooldownUntilMs": now + 300_000, "changedAtMs": now], "snoozeTs": now
        ], ts: 0)
        GroupStore.sharedOverlay = { hub.overlayShared(onto: $0) }
        XCTAssertTrue(store.adoptShared())
        let document = try raw(store)
        XCTAssertEqual((document["blockedGroups"] as? [[String: Any]])?.first?["name"] as? String, "Original")
        XCTAssertEqual(number(document, "usageTimersMs"), 5_000)
        let snooze = try XCTUnwrap((document["groupSnoozes"] as? [String: Any])?["m1"] as? [String: Any])
        XCTAssertEqual((snooze["untilMs"] as? NSNumber)?.doubleValue, now)
        XCTAssertEqual((snooze["cooldownUntilMs"] as? NSNumber)?.doubleValue, now + 300_000)
    }

    @MainActor
    func testFirstEnabledTickReportsOnlyFreshIncrementAfterSharedAdoption() throws {
        for rolling in [false, true] {
            let (hub, store, directory, now) = try fixture(rolling: rolling)
            defer { try? FileManager.default.removeItem(at: directory) }
            // A browser increment has already locked the absolute seed path.
            hub.applySync(program: "chrome", groupId: "c1", contribution: rolling
                          ? ["usageBuckets": UsageBudget.bucketJSON([UsageBudget.bucketStartMs(now): 1_000])]
                          : ["usageDeltaMs": 1_000.0], ts: 0)
            let shared = try XCTUnwrap(hub.sharedUsage(groupID: "m1"))
            let before = rolling ? UsageBudget.usedMs(shared.buckets) : shared.ms
            var current = store.loadUsageTimers()
            current.timersMs = ["m1": before]; current.resetAtMs = ["m1": now]; current.bucketsMs = ["m1": shared.buckets]
            let group = BlockGroup(id: "m1", groupType: .site, name: "Browser", enabled: true, mode: .afterMinutes,
                                   allowedMinutes: 20, resetIntervalHours: 24, rollingLimit: rolling,
                                   targets: [BlockTarget(id: "com.example.Game", kind: .application, displayName: "Game", normalizedValue: "com.example.Game")])
            let bridge = MacEnforcementBridge(webStore: store)
            _ = bridge.reconcileUsage(current: current, groups: [group], frontmost: "com.example.Game", elapsed: 2,
                                      now: Date(timeIntervalSince1970: now / 1000), hub: hub)
            let after = try XCTUnwrap(hub.sharedUsage(groupID: "m1"))
            XCTAssertEqual(rolling ? UsageBudget.usedMs(after.buckets) : after.ms, before + 2_000)
        }
    }
    func testUnreportedNativeLockRefusesExplicitUnlinkFromEitherPeer() throws {
        for program in ["macapp", "chrome"] {
            let (hub, store, directory, now) = try fixture(rolling: false)
            defer { try? FileManager.default.removeItem(at: directory) }
            var document = try raw(store)
            var groups = try XCTUnwrap(document["blockedGroups"] as? [[String: Any]])
            groups[0]["lockVersion"] = 7; groups[0]["lockedAtMs"] = now
            groups[0]["parentalPasswordHash"] = "private-fixture-hash"
            document["blockedGroups"] = groups; store.save(rawStore: document)
            let before = try Data(contentsOf: store.fileURL)
            XCTAssertEqual(hub.unlinkGroup(program: program, groupId: program == "macapp" ? "m1" : "c1"), "group-locked")
            XCTAssertNotNil(hub.sharedUsage(groupID: "m1"))
            XCTAssertEqual(try Data(contentsOf: store.fileURL), before)
        }
    }

    func testPeerRosterRemovalPreservesStrictlyNewerAtomicNativeLock() throws {
        let (hub, store, directory, now) = try fixture(rolling: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stale: [String: Any] = ["lockVersion": 2, "lockedAtMs": NSNull(), "lockWaitHours": 0,
                                    "parentalPasswordHash": NSNull(), "parentalPasswordSalt": NSNull()]
        hub.applySync(program: "chrome", groupId: "c1", contribution: ["scalars": ["name": "Browser", "enabled": false, "mode": "after-minutes", "allowedMinutes": 20, "resetIntervalHours": 24, "rollingLimit": false], "lock": stale, "lockBase": 0], ts: 10)
        var document = try raw(store)
        var groups = try XCTUnwrap(document["blockedGroups"] as? [[String: Any]])
        groups[0]["lockVersion"] = 7; groups[0]["lockedAtMs"] = now
        groups[0]["lockWaitHours"] = 3; groups[0]["parentalPasswordHash"] = "private-fixture-hash"
        groups[0]["parentalPasswordSalt"] = "private-fixture-salt"; groups[0]["lockSyncedVersion"] = 2
        let expected = groups[0]; document["blockedGroups"] = groups; store.save(rawStore: document)
        hub.setRoster(program: "chrome", groups: [])
        XCTAssertNil(hub.sharedUsage(groupID: "m1"))
        let saved = try XCTUnwrap((try raw(store)["blockedGroups"] as? [[String: Any]])?.first)
        for field in WebStoreDocument.lockFieldNames + ["lockSyncedVersion"] {
            XCTAssertEqual(WebStoreDocument.canonicalJSON(saved[field]), WebStoreDocument.canonicalJSON(expected[field]), field)
        }
        XCTAssertEqual(number(try raw(store), "usageTimersMs"), 240_000)
    }

    func testNewerOrEqualSharedUnlockClearsStaleLocalAtomicLockAndPermitsUnlink() throws {
        for sharedVersion in [7, 8] {
            let (hub, store, directory, now) = try fixture(rolling: false)
            defer { try? FileManager.default.removeItem(at: directory) }
            var document = try raw(store)
            var groups = try XCTUnwrap(document["blockedGroups"] as? [[String: Any]])
            groups[0]["lockVersion"] = 7; groups[0]["lockedAtMs"] = now
            groups[0]["parentalPasswordHash"] = "private-fixture-hash"; groups[0]["parentalPasswordSalt"] = "private-fixture-salt"
            document["blockedGroups"] = groups; store.save(rawStore: document)
            hub.applySync(program: "chrome", groupId: "c1", contribution: ["scalars": ["name": "Browser", "enabled": false, "mode": "after-minutes", "allowedMinutes": 20, "resetIntervalHours": 24, "rollingLimit": false], "lock": ["lockVersion": sharedVersion, "lockedAtMs": NSNull(), "lockWaitHours": 0]], ts: 10)
            XCTAssertNil(hub.unlinkGroup(program: "chrome", groupId: "c1"))
            let saved = try XCTUnwrap((try raw(store)["blockedGroups"] as? [[String: Any]])?.first)
            XCTAssertEqual(saved["lockVersion"] as? Int, sharedVersion)
            XCTAssertFalse(WebStoreDocument.isLocked(saved))
            XCTAssertNil(saved["parentalPasswordHash"] as? String)
            XCTAssertNil(saved["parentalPasswordSalt"] as? String)
        }
    }

}
