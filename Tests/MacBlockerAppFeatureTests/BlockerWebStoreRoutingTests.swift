#if os(macOS)
import XCTest
@testable import MacBlockerCore
import MacBlockerWebUI

/// The editor persists THROUGH GroupStore (one lock for both the WebView and
/// MCP writers). These lock in that the editor's save writes web-store.json and
/// does NOT self-notify — a re-seed notification is only for out-of-band
/// native writes.
final class BlockerWebStoreRoutingTests: XCTestCase {
    private func makeStore() -> (BlockerWebStore, SharedAppGroupStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("webstore-routing-\(UUID().uuidString)", isDirectory: true)
        let shared = SharedAppGroupStore(baseDirectory: dir)
        return (BlockerWebStore(shared: shared), shared, dir)
    }

    func testSavePersistsThroughGroupStore() throws {
        let (webStore, _, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let raw: [String: Any] = [
            "blockedGroups": [
                [
                    "id": "g1", "groupType": "app", "name": "Focus", "enabled": true,
                    "mode": "instant", "apps": [["id": "com.apple.Safari", "name": "Safari"]],
                ],
            ],
        ]
        webStore.save(rawStore: raw)

        // Persisted to the shared web-store.json …
        let json = try XCTUnwrap(webStore.loadRawJSON())
        XCTAssertTrue(json.contains("\"g1\""))
    }

    func testChosenGroupSurvivesNativeStoreReopen() throws {
        let (webStore, shared, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        webStore.save(rawStore: ["blockedGroups": [["id": "first", "name": "First"], ["id": "second", "name": "Second"]],
                                 "globalSettings": ["quickAddEnabled": true], "usageTimersMs": ["first": 500]])
        webStore.merge(changes: ["quickAddGroupId": "second"])
        let reopened = BlockerWebStore(shared: shared)
        let json = try XCTUnwrap(reopened.loadRawJSON())
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(raw["quickAddGroupId"] as? String, "second")
        XCTAssertEqual((raw["usageTimersMs"] as? [String: Int])?["first"], 500)
    }

    /// Found live on mini1 2026-09-26: the usage writer read the file THROUGH
    /// the shared overlay and wrote it back, baking another device's incomplete
    /// copy into this Mac's group (its Apps entry was lost).
    func testUsageWritesNeverPersistTheSharedOverlay() throws {
        let (webStore, _, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        webStore.save(rawStore: ["blockedGroups": [["id": "g1", "name": "Focus", "enabled": true, "mode": "instant",
            "scopes": [["id": "apps-1", "surface": "apps", "action": "block", "apps": [["id": "com.example.App"]]]]]]])
        defer { GroupStore.sharedOverlay = nil }
        GroupStore.sharedOverlay = { document in
            var overlaid = document
            overlaid["blockedGroups"] = [["id": "g1", "name": "Focus", "scopes": [] as [[String: Any]]]]
            return overlaid
        }
        webStore.writeUsage(timersMs: ["g1": 1_000], resetAtMs: ["g1": 1])
        let json = try XCTUnwrap(webStore.loadRawJSON())
        XCTAssertTrue(json.contains("com.example.App"), "the stored Apps entry survives a usage write")
        XCTAssertEqual(webStore.importedGroups().first?.targets.count ?? -1, 0, "enforcement still reads the overlay")
    }

    func testTheTickReadsOnceAndCountsAFinishedSnoozeOnce() throws {
        let (webStore, _, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        webStore.save(rawStore: ["blockedGroups": [["id": "g1", "name": "Focus"]],
                                 "globalSettings": ["quitRetryMinutes": 3],
                                 "usageTimersMs": ["g1": 5_000],
                                 "groupSnoozes": ["g1": ["startsAtMs": 1_000, "untilMs": 61_000]]])
        let first = webStore.loadForTick(nowMs: 100_000)
        XCTAssertEqual(((first["groupSnoozeTotalsMs"] as? [String: Any])?["g1"] as? NSNumber)?.doubleValue, 60_000)
        let again = webStore.loadForTick(nowMs: 200_000)
        XCTAssertEqual(((again["groupSnoozeTotalsMs"] as? [String: Any])?["g1"] as? NSNumber)?.doubleValue, 60_000, "counted once")
        let view = BlockerWebStore.enforcementView(of: again)
        XCTAssertEqual(view.groups.map(\.id), ["g1"])
        XCTAssertEqual(view.usage.timersMs["g1"], 5_000)
        XCTAssertEqual(view.quitRetryMinutes, 3)
        XCTAssertNotNil(view.snoozes["g1"]?.until)
    }

    func testTheMacAdoptsWhatItsLinkSharesIntoItsFile() throws {
        let (webStore, _, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        defer { GroupStore.sharedOverlay = nil }
        webStore.save(rawStore: ["blockedGroups": [["id": "g1", "name": "Focus", "allowedMinutes": 30]], "usageTimersMs": ["g1": 5]])
        GroupStore.sharedOverlay = { document in
            var overlaid = document
            overlaid["blockedGroups"] = [["id": "g1", "name": "Focus", "allowedMinutes": 45]]
            overlaid["groupSnoozeTotalsMs"] = ["g1": 60_000]
            return overlaid
        }
        XCTAssertTrue(webStore.adoptShared(), "the shared definition is written into the file")
        let json = try XCTUnwrap(webStore.loadRawJSON())
        XCTAssertTrue(json.contains("\"allowedMinutes\":45") && json.contains("60000") && json.contains("usageTimersMs"), json)
        XCTAssertFalse(webStore.adoptShared(), "caught up: nothing more to write")
    }

    func testADeletedGroupLeavesNoRuntimeEntry() {
        let tidy = BlockerWebStore.tidied(["blockedGroups": [["id": "g1"]],
                                           "usageTimersMs": ["g1": 5, "gone": 7],
                                           "groupSnoozeTotalsMs": ["gone": 1],
                                           "quickAddGroupId": "gone"], nowMs: 0)
        XCTAssertEqual((tidy?["usageTimersMs"] as? [String: Any])?.keys.sorted(), ["g1"])
        XCTAssertEqual((tidy?["groupSnoozeTotalsMs"] as? [String: Any])?.isEmpty, true)
        XCTAssertEqual(tidy?["quickAddGroupId"] as? String, "")
        XCTAssertNil(BlockerWebStore.tidied(["blockedGroups": [["id": "g1", "lockedAtMs": NSNull()]], "usageTimersMs": ["g1": 5]], nowMs: 0), "nothing to tidy: no write")

        let legacy = BlockerWebStore.tidied(["blockedGroups": [["id": "g1", "freezeMode": "strict", "frozenAtMs": 5, "strictFreezeHours": 3]]], nowMs: 0)
        let converted = (legacy?["blockedGroups"] as? [[String: Any]])?.first
        XCTAssertEqual((converted?["lockedAtMs"] as? NSNumber)?.doubleValue, 5, "an old strict freeze becomes the editor's lock once")
        XCTAssertEqual((converted?["lockWaitHours"] as? NSNumber)?.doubleValue, 3)
        XCTAssertNil(converted?["freezeMode"])
    }

    /// As the browser's worker (group-actions.js): a used-up budget snooze ends
    /// on the tick; its time was counted as it was used, so neither ending nor
    /// lapsing adds to the total.
    func testABudgetSnoozeEndsWhenUsedUpAndAddsNothingAtTheEnd() {
        let group: [String: Any] = ["id": "g1", "name": "Focus", "mode": "after-minutes", "allowedMinutes": 15,
                                    "resetIntervalHours": 2, "snoozeKind": "budget", "snoozeMinutes": 10]
        let entry: [String: Any] = ["kind": "budget", "extraMs": 600_000, "startsAtMs": 1_000_000, "untilMs": 8_200_000,
                                    "cooldownUntilMs": 8_320_000, "confirmationCount": 0, "changedAtMs": 1_000_000]
        let usedUp = BlockerWebStore.tidied(["blockedGroups": [group], "usageTimersMs": ["g1": 1_500_000],
                                             "groupSnoozes": ["g1": entry], "groupSnoozeTotalsMs": ["g1": 600_000]], nowMs: 2_000_000)
        let ended = (usedUp?["groupSnoozes"] as? [String: Any])?["g1"] as? [String: Any]
        XCTAssertEqual((ended?["untilMs"] as? NSNumber)?.doubleValue, 2_000_000, "ended now: the block returns")
        XCTAssertEqual((ended?["cooldownUntilMs"] as? NSNumber)?.doubleValue, 2_120_000, "its cooldown runs from now")
        XCTAssertEqual(ended?["activeMsApplied"] as? Bool, true, "marked done")
        XCTAssertEqual(((usedUp?["groupSnoozeTotalsMs"] as? [String: Any])?["g1"] as? NSNumber)?.doubleValue, 600_000, "nothing added at the end")
        let lapsed = BlockerWebStore.tidied(["blockedGroups": [group], "usageTimersMs": ["g1": 1_140_000],
                                             "groupSnoozes": ["g1": entry], "groupSnoozeTotalsMs": ["g1": 240_000]], nowMs: 8_300_000)
        XCTAssertEqual(((lapsed?["groupSnoozeTotalsMs"] as? [String: Any])?["g1"] as? NSNumber)?.doubleValue, 240_000, "nothing added when it lapses")
        let view = BlockerWebStore.enforcementView(of: ["blockedGroups": [group], "groupSnoozes": ["g1": entry]])
        XCTAssertEqual(view.snoozes["g1"]?.budgetExtra, 600, "enforcement reads the extra")
    }

    /// What a budget snooze gives each tick is added to the stored total.
    func testSnoozeTimeGivenOnATickIsAddedToTheTotal() throws {
        let (webStore, _, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        webStore.save(rawStore: ["blockedGroups": [["id": "g1", "name": "Focus"]], "groupSnoozeTotalsMs": ["g1": 5_000]])
        webStore.writeUsage(timersMs: ["g1": 61_000], resetAtMs: [:], snoozeGivenMs: ["g1": 1_000])
        webStore.writeUsage(timersMs: ["g1": 62_000], resetAtMs: [:], snoozeGivenMs: ["g1": 1_000])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(XCTUnwrap(webStore.loadRawJSON()).utf8)) as? [String: Any])
        XCTAssertEqual(((object["groupSnoozeTotalsMs"] as? [String: Any])?["g1"] as? NSNumber)?.doubleValue, 7_000)
    }

    func testTheEditorMergesOnlyTheKeysItSet() throws {
        let (webStore, _, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        webStore.save(rawStore: ["blockedGroups": [["id": "g1", "name": "A"]], "groupSnoozeTotalsMs": ["g1": 60_000]])
        webStore.merge(changes: ["blockedGroups": [["id": "g1", "name": "B"]], "quickAddGroupId": NSNull()])
        let json = try XCTUnwrap(webStore.loadRawJSON())
        XCTAssertTrue(json.contains("\"B\"") && json.contains("60000"), "the engine's key is kept: \(json)")
    }

    func testAnUnlinkedMacGroupKeepsItsAppsLinesAndDuplicatesAreRenamed() throws {
        let (webStore, _, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        webStore.save(rawStore: ["blockedGroups": [["id": "m1", "name": "Focus", "scopes": [
            ["id": "site-1", "surface": "site", "sites": ["example.com"]],
            ["id": "apps-1", "surface": "apps", "apps": [["id": "com.example.App"]]]]]]])
        webStore.keepOwnLines(groupIds: ["m1"])
        let json = try XCTUnwrap(webStore.loadRawJSON())
        XCTAssertTrue(json.contains("apps-1") && !json.contains("site-1"), json)
        let renamed = BlockerWebStore.tidied(["blockedGroups": [["id": "a", "name": "Work"], ["id": "b", "name": "work"]]], nowMs: 0, linkedGroupIds: ["b"])
        XCTAssertEqual((renamed?["blockedGroups"] as? [[String: Any]])?.compactMap { $0["name"] as? String }, ["Work (2)", "work"],
                       "the linked group keeps its name; the other is renamed silently")
    }

    func testEditorSaveDoesNotSelfNotify() {
        let (webStore, _, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        var posts = 0
        let token = NotificationCenter.default.addObserver(
            forName: GroupStore.didChangeNotification, object: nil, queue: nil
        ) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        webStore.save(rawStore: ["blockedGroups": [] as [[String: Any]]])
        XCTAssertEqual(posts, 0, "the editor's own persist must not post a re-seed notification")
    }

    func testSaveIgnoresNonObjectPayload() {
        let (webStore, shared, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        // A non-dictionary top-level payload is not a valid store; save is a no-op.
        webStore.save(rawStore: [1, 2, 3])
        XCTAssertNil(shared.readData(SharedAppGroupStore.webStoreFileName), "no file written for a non-object payload")
    }
    func testDeletedCustomMemoryCannotBeResurrectedByLateStateCallback() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("deleted-state-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let shared = SharedAppGroupStore(baseDirectory: dir)
        let store = BlockerWebStore(shared: shared)
        let native = GroupStore(shared: shared)
        native.save(WebStoreDocument(raw: ["blockedGroups": [
            ["id": "gone", "name": "Gone", "groupType": "custom"],
            ["id": "kept", "name": "Kept", "groupType": "custom"]],
            "cbRuleState": ["gone": ["events": 3], "kept": ["events": 9]]]))
        try native.mutate { try $0.deleteGroup(id: "gone") }
        store.writeRuleStates(["gone": "{\"events\":4}", "kept": "{\"events\":10}"])
        XCTAssertEqual(store.ruleState(groupID: "gone"), "{}")
        XCTAssertEqual(store.ruleState(groupID: "kept"), "{\"events\":10}")
    }

}
#endif
