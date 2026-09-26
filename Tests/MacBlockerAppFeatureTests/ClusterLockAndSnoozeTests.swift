import XCTest
@testable import MacBlockerAppFeature

/// Owner 2026-09-26: a lock or unlock on any linked device applies to every
/// device (the latest LOCK CHANGE wins, not the latest save), and the parental
/// PIN travels with the lock. Ending a snooze early ends it everywhere.
final class ClusterLockAndSnoozeTests: XCTestCase {
    private func linkedHub() -> ConnectionHub {
        let hub = ConnectionHub()
        hub.setRoster(program: "macapp", groups: [["id": "m1", "name": "Focus"]])
        hub.setRoster(program: "chrome", groups: [["id": "c1", "name": "Focus"]])
        return hub
    }

    private func shared(_ hub: ConnectionHub, _ stored: [String: Any] = [:]) -> [String: Any] {
        var group: [String: Any] = ["id": "m1", "name": "Focus"]
        group.merge(stored) { _, new in new }
        let doc = hub.overlayShared(onto: ["blockedGroups": [group]])
        return (doc["blockedGroups"] as? [[String: Any]])?.first ?? [:]
    }

    func testAnUnlockOnOneDeviceUnlocksEveryDevice() {
        let hub = linkedHub()
        hub.applySync(program: "chrome", groupName: "Focus", contribution: ["scalars": [
            "freezeMode": "parental", "freezeChangedAtMs": 1_000, "parentalPasswordHash": "h", "parentalPasswordSalt": "s"
        ]], ts: 10)
        hub.applySync(program: "macapp", groupName: "Focus", contribution: ["scalars": [
            "freezeMode": "parental", "freezeChangedAtMs": 1_000, "parentalPasswordHash": "h", "parentalPasswordSalt": "s"
        ]], ts: 11)
        XCTAssertEqual(shared(hub)["freezeMode"] as? String, "parental")
        XCTAssertEqual(shared(hub)["parentalPasswordHash"] as? String, "h", "the PIN travels with the lock")

        // Chrome unlocks later; the Mac's stale "parental" no longer wins.
        hub.applySync(program: "chrome", groupName: "Focus", contribution: ["scalars": [
            "freezeMode": "none", "freezeChangedAtMs": 2_000
        ]], ts: 12)
        XCTAssertEqual(shared(hub)["freezeMode"] as? String, "none")

        // A later save on the Mac that carries its OLD lock does not bring it back.
        hub.applySync(program: "macapp", groupName: "Focus", contribution: ["scalars": [
            "freezeMode": "parental", "freezeChangedAtMs": 1_000, "allowedMinutes": 20
        ]], ts: 13)
        XCTAssertEqual(shared(hub)["freezeMode"] as? String, "none", "only a newer lock change moves the lock")
    }

    func testMembersWithoutAChangeTimeFallBackToTheStrictestLock() {
        let hub = linkedHub()
        hub.applySync(program: "chrome", groupName: "Focus", contribution: ["scalars": ["freezeMode": "frozen"]], ts: 1)
        hub.applySync(program: "macapp", groupName: "Focus", contribution: ["scalars": ["freezeMode": "strict"]], ts: 2)
        XCTAssertEqual(shared(hub)["freezeMode"] as? String, "strict")
    }

    func testAnEndedSnoozeFromAnotherDeviceEndsTheLocalOne() {
        let hub = linkedHub()
        let now = Date().timeIntervalSince1970 * 1000
        hub.applySync(program: "chrome", groupName: "Focus", contribution: [
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
}
