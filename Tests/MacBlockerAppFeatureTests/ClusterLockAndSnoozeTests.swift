import XCTest
@testable import MacBlockerAppFeature
import MacBlockerCore

/// Owner 2026-09-26: linked groups lock together — one lock for the link,
/// owned by the hub and versioned: a device's change is taken only when it was
/// made on top of the hub's current version (a stale or joining device can
/// never overwrite it; a device's change made while the hub was away wins when
/// it returns). A locked group cannot join a link. Ending a snooze early ends it
/// everywhere.
final class ClusterLockAndSnoozeTests: XCTestCase {
    private func linkedHub() -> ConnectionHub {
        let hub = ConnectionHub()
        hub.setRoster(program: "macapp", groups: [["id": "m1", "name": "Focus"]])
        hub.setRoster(program: "chrome", groups: [["id": "c1", "name": "Focus"]])
        XCTAssertNil(hub.linkGroups(program: "macapp", groupId: "m1", targetProgram: "chrome", targetGroupId: "c1"))
        return hub
    }

    private func shared(_ hub: ConnectionHub, _ stored: [String: Any] = [:]) -> [String: Any] {
        var group: [String: Any] = ["id": "m1", "name": "Focus"]
        group.merge(stored) { _, new in new }
        let doc = hub.overlayShared(onto: ["blockedGroups": [group]])
        return (doc["blockedGroups"] as? [[String: Any]])?.first ?? [:]
    }

    private func unit(locked: Bool, version: Int, pin: String? = nil) -> [String: Any] {
        ["lockedAtMs": locked ? 1_000 : NSNull(), "lockWaitHours": 0,
         "parentalPasswordHash": pin ?? NSNull(), "parentalPasswordSalt": pin == nil ? NSNull() : "s", "lockVersion": version]
    }

    private func sync(_ hub: ConnectionHub, _ program: String, lock: [String: Any], base: Int) {
        hub.applySync(program: program, groupId: ["macapp": "m1", "chrome": "c1", "firefox": "f1"][program] ?? "",
                      contribution: ["scalars": ["allowedMinutes": 15], "lock": lock, "lockBase": base], ts: 1)
    }

    func testTheLinksLockMovesOnlyOnTopOfItsVersion() {
        let hub = linkedHub()
        sync(hub, "chrome", lock: unit(locked: false, version: 3), base: 0)
        sync(hub, "macapp", lock: unit(locked: true, version: 9), base: 0)
        XCTAssertNil(shared(hub)["lockedAtMs"] as? NSNumber, "a joining member never changes the link's lock")
        XCTAssertEqual(shared(hub)["lockVersion"] as? Int, 3)
        XCTAssertEqual(shared(hub)["lockSyncedVersion"] as? Int, 3, "the Mac reads the link's version")

        sync(hub, "macapp", lock: unit(locked: true, version: 4, pin: "h"), base: 3)
        XCTAssertEqual(shared(hub)["lockedAtMs"] as? Int, 1_000, "a change made on the current version is taken")
        XCTAssertEqual(shared(hub)["parentalPasswordHash"] as? String, "h", "the PIN travels with the lock")

        sync(hub, "chrome", lock: unit(locked: false, version: 5), base: 3)
        XCTAssertEqual(shared(hub)["lockedAtMs"] as? Int, 1_000, "a change made on an old version is dropped")

        sync(hub, "chrome", lock: unit(locked: false, version: 5), base: 4)
        XCTAssertNil(shared(hub)["lockedAtMs"] as? NSNumber, "an unlock made on the current version unlocks the link")
    }

    func testALockedGroupCannotBeLinked() {
        let hub = ConnectionHub()
        hub.setRoster(program: "macapp", groups: [["id": "m1", "name": "Focus", "frozen": true]])
        hub.setRoster(program: "chrome", groups: [["id": "c1", "name": "Focus"]])
        XCTAssertEqual(hub.linkGroups(program: "macapp", groupId: "m1", targetProgram: "chrome", targetGroupId: "c1"), "group-locked")
        hub.setRoster(program: "macapp", groups: [["id": "m1", "name": "Focus"]])
        XCTAssertNil(hub.sharedUsage(groupID: "m1"), "same names never link on their own (owner 2026-09-27)")
        XCTAssertNil(hub.linkGroups(program: "macapp", groupId: "m1", targetProgram: "chrome", targetGroupId: "c1"), "unfrozen, Link links them")

        sync(hub, "chrome", lock: unit(locked: true, version: 1), base: 0)
        hub.setRoster(program: "firefox", groups: [["id": "f1", "name": "Other"]])
        XCTAssertEqual(hub.linkGroups(program: "firefox", groupId: "f1", targetProgram: "macapp", targetGroupId: "m1"), "group-locked",
                       "a locked link takes no one new, so nobody can unlock it by joining")
        XCTAssertEqual(hub.unlinkGroup(program: "chrome", groupId: "c1"), "group-locked", "nor is it undone while locked")
    }

    func testTheLinksSnoozeTotalCountsEachSnoozeOnce() {
        let hub = linkedHub()
        hub.setRoster(program: "firefox", groups: [["id": "f1", "name": "Focus"]])
        XCTAssertNil(hub.linkGroups(program: "firefox", groupId: "f1", targetProgram: "macapp", targetGroupId: "m1"))
        let now = (Date().timeIntervalSince1970 * 1000).rounded(.down)
        let entry: [String: Any] = ["startsAtMs": now - 600_000, "untilMs": now - 300_000, "cooldownUntilMs": now - 300_000, "changedAtMs": now - 600_000]
        // Every device reports the same finished snooze.
        for program in ["chrome", "firefox", "macapp"] {
            hub.applySync(program: program, groupId: ["macapp": "m1", "chrome": "c1", "firefox": "f1"][program] ?? "", contribution: ["snooze": entry, "snoozeTs": now - 600_000], ts: 0)
        }
        XCTAssertEqual(shared(hub)["snoozeTotalMs"] as? Double, nil, "overlay carries no total; read the cluster")
        let total = { () -> Double in
            let json = hub.clustersJSON()
            let clusters = ((try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any])?["clusters"] as? [[String: Any]] ?? []
            return ((clusters.first?["shared"] as? [String: Any])?["snoozeTotalMs"] as? NSNumber)?.doubleValue ?? -1
        }
        XCTAssertEqual(total(), 300_000, "a snooze three devices saw counts once")
        // A second snooze, ended early on one device, counts its snoozed part once.
        let second: [String: Any] = ["startsAtMs": now - 100_000, "untilMs": now - 40_000, "cooldownUntilMs": now - 40_000, "changedAtMs": now - 40_000]
        hub.applySync(program: "chrome", groupId: "c1", contribution: ["snooze": second, "snoozeTs": now - 40_000], ts: 0)
        hub.applySync(program: "firefox", groupId: "f1", contribution: ["snooze": second, "snoozeTs": now - 40_000], ts: 0)
        XCTAssertEqual(total(), 360_000)
        hub.applySync(program: "macapp", groupId: "m1", contribution: ["snoozeTotalMs": 9_999_999.0], ts: 0)
        XCTAssertEqual(total(), 360_000, "a member's own figure is not taken")
    }

    func testAnEndedSnoozeFromAnotherDeviceEndsTheLocalOne() {
        let hub = linkedHub()
        let now = Date().timeIntervalSince1970 * 1000
        hub.applySync(program: "chrome", groupId: "c1", contribution: [
            "snooze": ["startsAtMs": now - 60_000, "untilMs": now, "cooldownUntilMs": now, "changedAtMs": now],
            "snoozeTs": now
        ], ts: 0)
        let document: [String: Any] = [
            "blockedGroups": [["id": "m1", "name": "Focus"]],
            "groupSnoozes": ["m1": ["startsAtMs": now - 60_000, "untilMs": now + 600_000, "cooldownUntilMs": now + 600_000]]
        ]
        let snooze = (hub.overlayShared(onto: document)["groupSnoozes"] as? [String: Any])?["m1"] as? [String: Any]
        XCTAssertEqual((snooze?["untilMs"] as? NSNumber)?.doubleValue, now, "the newer END replaces the local active snooze")
    }

    func testTheMacGroupListComesFromItsStoreEveryTick() {
        // A group created or renamed with the window closed (by the "+" or a
        // tool) can be linked; a rename keeps a link (names are shared).
        let hub = ConnectionHub()
        hub.setRoster(program: "chrome", groups: [["id": "c1", "name": "Focus"]])
        let now = Date().timeIntervalSince1970 * 1000
        hub.contributeLocalDefinitions(document: ["blockedGroups": [["id": "m1", "name": "Work"]]], nowMs: now)
        XCTAssertNil(hub.linkGroups(program: "chrome", groupId: "c1", targetProgram: "macapp", targetGroupId: "m1"), "linked by the user, pinned by id")
        hub.contributeLocalDefinitions(document: ["blockedGroups": [["id": "m1", "name": "Renamed"]]], nowMs: now)
        XCTAssertNotNil(hub.sharedUsage(groupID: "m1"), "a rename keeps the link")
        hub.contributeLocalDefinitions(document: ["blockedGroups": []], nowMs: now)
        XCTAssertNil(hub.sharedUsage(groupID: "m1"), "a delete ends it")
        XCTAssertEqual(hub.takeUnlinkedLocalGroups(), ["m1"])
    }

    func testUnlinkDissolvesATwoMemberLinkAndQueuesTheMacGroup() {
        let hub = linkedHub()
        XCTAssertNil(hub.unlinkGroup(program: "chrome", groupId: "c1"))
        XCTAssertNil(hub.sharedUsage(groupID: "m1"), "the link is gone")
        XCTAssertEqual(hub.takeUnlinkedLocalGroups(), ["m1"], "the Mac group keeps only its own lines")
        XCTAssertEqual(hub.unlinkGroup(program: "chrome", groupId: "c1"), "not-linked")
    }

    func testTheInitiatorsSettingsAndNameWinTheFirstMerge() {
        let hub = ConnectionHub()
        hub.setRoster(program: "macapp", groups: [["id": "m1", "name": "Mac name"]])
        hub.setRoster(program: "chrome", groups: [["id": "c1", "name": "Browser name"]])
        XCTAssertNil(hub.linkGroups(program: "chrome", groupId: "c1", targetProgram: "macapp", targetGroupId: "m1"))
        hub.applySync(program: "macapp", groupId: "m1", contribution: ["scalars": ["name": "Mac name", "allowedMinutes": 10]], ts: 0)
        hub.applySync(program: "chrome", groupId: "c1", contribution: ["scalars": ["name": "Browser name", "allowedMinutes": 20]], ts: 0)
        let overlaid = hub.overlayShared(onto: ["blockedGroups": [["id": "m1", "name": "Mac name"]]])
        let group = (overlaid["blockedGroups"] as? [[String: Any]])?.first
        XCTAssertEqual(group?["name"] as? String, "Browser name", "linked groups share one name: the initiator's")
        XCTAssertEqual(group?["allowedMinutes"] as? Int, 20)
    }


    func testTheLinkToolsDoWhatTheButtonsDo() {
        let hub = ConnectionHub()
        hub.setRoster(program: "macapp", groups: [["id": "m1", "name": "Focus"]])
        hub.setRoster(program: "chrome", groups: [["id": "c1", "name": "Other"]])
        let tools = LinkMCPTools.tools(hub: hub)
        func call(_ name: String, _ args: [String: Any]) -> MCPToolResult { tools.first { $0.name == name }!.handler(args) }
        XCTAssertTrue(call("list_links", [:]).text.contains("\"Other\""), "the other programs' groups are listed")
        XCTAssertFalse(call("link_groups", ["program": "macapp", "groupId": "m1", "targetProgram": "chrome", "targetGroupId": "c1"]).isError)
        XCTAssertNotNil(hub.sharedUsage(groupID: "m1"))
        XCTAssertTrue(call("link_groups", ["program": "macapp", "groupId": "m1", "targetProgram": "chrome", "targetGroupId": "c1"]).isError, "already linked")
        XCTAssertFalse(call("unlink_group", ["program": "chrome", "groupId": "c1"]).isError)
        XCTAssertNil(hub.sharedUsage(groupID: "m1"))
    }
}
