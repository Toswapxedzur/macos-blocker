import XCTest
@testable import MacBlockerAppFeature
import MacBlockerCore

/// Original state must survive delayed, reordered and interrupted first links.
final class ClusterFirstJoinTests: XCTestCase {
    private let apps: [[String: Any]] = [["surface": "apps", "id": "apps-1", "apps": [["id": "com.example.Game"]]]]
    private let sites: [[String: Any]] = [["surface": "site", "id": "site-1", "sites": ["example.com"]]]
    private func hub(initiator: String = "chrome") -> ConnectionHub {
        let h = ConnectionHub(); h.hostingLocalHub = true
        h.setRoster(program: "macapp", groups: [["id": "m1", "name": "Mac"]])
        h.setRoster(program: "chrome", groups: [["id": "c1", "name": "Browser"]])
        XCTAssertNil(h.linkGroups(program: initiator, groupId: initiator == "chrome" ? "c1" : "m1", targetProgram: initiator == "chrome" ? "macapp" : "chrome", targetGroupId: initiator == "chrome" ? "m1" : "c1"))
        return h
    }
    private func original(_ program: String, rolling: Bool, anchor: Double) -> [String: Any] {
        let usage = program == "chrome" ? 300_000.0 : 120_000.0
        let key = String(Int64(UsageBudget.bucketStartMs(anchor)))
        return ["scalars": ["name": program == "chrome" ? "Browser" : "Mac", "allowedMinutes": program == "chrome" ? 20 : 10,
                            "mode": "after-minutes", "resetIntervalHours": program == "chrome" ? 24 : 12, "rollingLimit": rolling],
                "scopes": program == "chrome" ? sites : apps,
                "usageMs": usage, "usageResetAtMs": anchor, "usageBucketsSeed": [key: usage]]
    }
    private func localDocument(_ anchor: Double) -> [String: Any] {
        ["blockedGroups": [["id": "m1", "name": "Mac", "allowedMinutes": 10, "scopes": apps]],
         "usageTimersMs": ["m1": 120_000.0], "usageResetAtMs": ["m1": anchor]]
    }
    private func group(_ h: ConnectionHub, anchor: Double) throws -> [String: Any] {
        try XCTUnwrap((h.overlayShared(onto: localDocument(anchor))["blockedGroups"] as? [[String: Any]])?.first)
    }
    func testLocalOriginalIsNotAdoptedBeforeItsContribution() throws {
        let h = hub(initiator: "macapp"), now = Date().timeIntervalSince1970 * 1000
        h.applySync(program: "chrome", groupId: "c1", contribution: original("chrome", rolling: false, anchor: now), ts: 10_000)
        let pending = try group(h, anchor: now)
        XCTAssertEqual(pending["name"] as? String, "Mac")
        XCTAssertEqual(pending["allowedMinutes"] as? Int, 10)
        XCTAssertEqual((pending["scopes"] as? [[String: Any]])?.first?["surface"] as? String, "apps")
        h.contributeLocalDefinitions(document: localDocument(now), nowMs: now)
        XCTAssertEqual(try group(h, anchor: now)["name"] as? String, "Mac")
        XCTAssertEqual(try XCTUnwrap(h.sharedUsage(groupID: "m1")).ms, 300_000)
    }
    func testInitialPolicyAndUsageSurviveBothOrdersAndRestartWithLiveDeltas() throws {
        for initiator in ["macapp", "chrome"] {
            for first in ["macapp", "chrome"] {
                for rolling in [false, true] {
                    for restart in [false, true] {
                        var h = hub(initiator: initiator)
                        let now = (Date().timeIntervalSince1970 * 1000).rounded(.down)
                        let minute = UsageBudget.bucketStartMs(now)
                        h.applySync(program: first, groupId: first == "macapp" ? "m1" : "c1", contribution: original(first, rolling: rolling, anchor: now), ts: 0)
                        let delta: [String: Any] = rolling ? ["usageBuckets": UsageBudget.bucketJSON([minute: 2_000]), "usageTransferId": "join-delta"] : ["usageDeltaMs": 2_000.0, "usageDeltaAnchorMs": now, "usageTransferId": "join-delta"]
                        h.applySync(program: first, groupId: first == "macapp" ? "m1" : "c1", contribution: delta, ts: 0)
                        if restart { let restored = ConnectionHub(); restored.restoreClustersLocked(); h = restored }
                        let second = first == "macapp" ? "chrome" : "macapp"
                        let payload = original(second, rolling: rolling, anchor: now)
                        h.applySync(program: second, groupId: second == "macapp" ? "m1" : "c1", contribution: payload, ts: 50_000)
                        // A retried original is not another usage transfer or edit.
                        h.applySync(program: second, groupId: second == "macapp" ? "m1" : "c1", contribution: payload, ts: 0)
                        let result = try XCTUnwrap(h.sharedUsage(groupID: "m1"))
                        XCTAssertEqual(rolling ? result.buckets[minute] : result.ms, 302_000)
                        let merged = try group(h, anchor: now)
                        XCTAssertEqual(merged["name"] as? String, initiator == "chrome" ? "Browser" : "Mac")
                        XCTAssertEqual((merged["scopes"] as? [[String: Any]])?.compactMap { $0["surface"] as? String }.sorted(), ["apps", "site"])
                        h.applySync(program: "chrome", groupId: "c1", contribution: ["usageMs": 999_000.0, "usageBucketsSeed": UsageBudget.bucketJSON([minute: 999_000])], ts: 0)
                        let after = try XCTUnwrap(h.sharedUsage(groupID: "m1"))
                        XCTAssertEqual(rolling ? after.buckets[minute] : after.ms, 302_000)
                    }
                }
            }
        }
    }
    func testAddingAnotherBrowserPreservesExistingUsageAndBothBrowserScopes() throws {
        let h = hub(), now = (Date().timeIntervalSince1970 * 1000).rounded(.down)
        for p in ["macapp", "chrome"] { h.applySync(program: p, groupId: p == "macapp" ? "m1" : "c1", contribution: original(p, rolling: false, anchor: now), ts: 0) }
        h.applySync(program: "chrome", groupId: "c1", contribution: ["usageDeltaMs": 2_000.0], ts: 0)
        h.setRoster(program: "safari", groups: [["id": "s1", "name": "Safari"]])
        XCTAssertNil(h.linkGroups(program: "safari", groupId: "s1", targetProgram: "macapp", targetGroupId: "m1"))
        h.applySync(program: "chrome", groupId: "c1", contribution: ["usageDeltaMs": 3_000.0], ts: 0)
        h.applySync(program: "safari", groupId: "s1", contribution: ["scalars": ["name": "Safari", "allowedMinutes": 99], "scopes": [["surface": "items", "platform": "youtube", "id": "items-1"]], "usageMs": 400_000.0, "usageResetAtMs": now], ts: now)
        XCTAssertEqual(try XCTUnwrap(h.sharedUsage(groupID: "m1")).ms, 403_000)
        let merged = try group(h, anchor: now)
        XCTAssertEqual(merged["name"] as? String, "Browser")
        XCTAssertEqual((merged["scopes"] as? [[String: Any]])?.compactMap { $0["surface"] as? String }.sorted(), ["apps", "items", "site"])
    }
    func testAddingBrowserWhileAnotherOriginalIsPendingPreservesEarlierDeltas() throws {
        let h = hub(), now = (Date().timeIntervalSince1970 * 1000).rounded(.down)
        h.applySync(program: "macapp", groupId: "m1", contribution: original("macapp", rolling: false, anchor: now), ts: 0)
        h.applySync(program: "macapp", groupId: "m1", contribution: ["usageDeltaMs": 2_000.0], ts: 0)
        h.setRoster(program: "safari", groups: [["id": "s1", "name": "Safari"]])
        XCTAssertNil(h.linkGroups(program: "safari", groupId: "s1", targetProgram: "macapp", targetGroupId: "m1"))
        h.applySync(program: "chrome", groupId: "c1", contribution: original("chrome", rolling: false, anchor: now), ts: 0)
        h.applySync(program: "safari", groupId: "s1", contribution: ["scalars": ["name": "Safari"], "scopes": [[String: Any]](), "usageMs": 200_000.0, "usageResetAtMs": now], ts: 0)
        XCTAssertEqual(try XCTUnwrap(h.sharedUsage(groupID: "m1")).ms, 302_000)
    }
    func testIndependentOriginalAnchorsStillSeedTheMaximum() throws {
        let h = hub(), now = (Date().timeIntervalSince1970 * 1000).rounded(.down)
        h.applySync(program: "macapp", groupId: "m1", contribution: original("macapp", rolling: false, anchor: now - 60_000), ts: 0)
        h.applySync(program: "macapp", groupId: "m1", contribution: ["usageDeltaMs": 2_000.0], ts: 0)
        h.applySync(program: "chrome", groupId: "c1", contribution: original("chrome", rolling: false, anchor: now), ts: 0)
        XCTAssertEqual(try XCTUnwrap(h.sharedUsage(groupID: "m1")).ms, 302_000)
        XCTAssertEqual(try XCTUnwrap(h.sharedUsage(groupID: "m1")).resetAtMs, now - 60_000)
    }
    func testRealBudgetEditDuringJoinResetsUsageAndRejectsOldOriginal() throws {
        for rolling in [false, true] {
            let h = hub(), now = (Date().timeIntervalSince1970 * 1000).rounded(.down)
            h.applySync(program: "chrome", groupId: "c1", contribution: original("chrome", rolling: rolling, anchor: now - 60_000), ts: 0)
            h.applySync(program: "chrome", groupId: "c1", contribution: ["scalars": ["name": "Browser", "mode": "after-minutes", "allowedMinutes": 20, "resetIntervalHours": 6, "rollingLimit": rolling]], ts: now)
            let reset = try XCTUnwrap(h.sharedUsage(groupID: "m1"))
            XCTAssertEqual(reset.ms, 0)
            XCTAssertTrue(reset.buckets.isEmpty)
            h.applySync(program: "macapp", groupId: "m1", contribution: original("macapp", rolling: rolling, anchor: now - 60_000), ts: 0)
            let after = try XCTUnwrap(h.sharedUsage(groupID: "m1"))
            XCTAssertEqual(after.ms, 0)
            XCTAssertTrue(after.buckets.isEmpty, "a pending original cannot revive rolling history after a real edit")
            XCTAssertEqual(try group(h, anchor: now)["resetIntervalHours"] as? Int, 6)
        }
    }
    func testRemovingPendingBrowserAndRelinkingDoesNotReuseJoiningDeltas() throws {
        let h = hub(), now = (Date().timeIntervalSince1970 * 1000).rounded(.down)
        h.applySync(program: "macapp", groupId: "m1", contribution: original("macapp", rolling: false, anchor: now), ts: 0)
        h.applySync(program: "macapp", groupId: "m1", contribution: ["usageDeltaMs": 2_000.0], ts: 0)
        XCTAssertNil(h.unlinkGroup(program: "chrome", groupId: "c1"))
        XCTAssertNil(h.linkGroups(program: "chrome", groupId: "c1", targetProgram: "macapp", targetGroupId: "m1"))
        for p in ["macapp", "chrome"] { h.applySync(program: p, groupId: p == "macapp" ? "m1" : "c1", contribution: original(p, rolling: false, anchor: now), ts: 0) }
        XCTAssertEqual(try XCTUnwrap(h.sharedUsage(groupID: "m1")).ms, 300_000)
    }
    func testFutureHubStorageIsPreservedAndCannotBeWrittenDuringJoining() throws {
        let key = "ConnectionHub.clusters.v2"
        let previous = UserDefaults.standard.data(forKey: key)
        defer { if let previous { UserDefaults.standard.set(previous, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        _ = hub()
        let saved = try XCTUnwrap(UserDefaults.standard.data(forKey: key))
        var wrapped = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        var metadata = try XCTUnwrap(wrapped["storageMetadata"] as? [String: Any])
        metadata["schemaVersion"] = 999; wrapped["storageMetadata"] = metadata
        let future = try JSONSerialization.data(withJSONObject: wrapped, options: [.sortedKeys])
        UserDefaults.standard.set(future, forKey: key)
        let restored = ConnectionHub(); restored.restoreClustersLocked()
        restored.setRoster(program: "macapp", groups: [["id": "m1", "name": "Mac"]])
        restored.setRoster(program: "chrome", groups: [["id": "c1", "name": "Browser"]])
        XCTAssertEqual(restored.linkGroups(program: "chrome", groupId: "c1", targetProgram: "macapp", targetGroupId: "m1"), "unsupported-storage")
        restored.contributeLocalDefinitions(document: localDocument(Date().timeIntervalSince1970 * 1000), nowMs: 0)
        XCTAssertEqual(UserDefaults.standard.data(forKey: key), future)
    }
    func testExpiredOriginalCannotReseedAfterBudgetRollover() throws {
        let h = hub(), now = (Date().timeIntervalSince1970 * 1000).rounded(.down)
        h.applySync(program: "chrome", groupId: "c1", contribution: original("chrome", rolling: false, anchor: now), ts: 0)
        h.rollSharedBudgets(nowMs: now + 25 * 3_600_000)
        h.applySync(program: "macapp", groupId: "m1", contribution: original("macapp", rolling: false, anchor: now), ts: 0)
        XCTAssertEqual(try XCTUnwrap(h.sharedUsage(groupID: "m1")).ms, 0)
    }
}
