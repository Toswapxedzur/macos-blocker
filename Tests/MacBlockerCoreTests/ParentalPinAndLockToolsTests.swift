import XCTest
@testable import MacBlockerCore

/// Owner 2026-09-26: the AI tools get exactly the user's gates. The Mac tools
/// check a PIN the way the editor does (customBlocker parental-pin.js, which
/// the Mac editor runs): same hash, same old formats, same retry wait, same
/// stored wrong-PIN counts. Reference values come from parental-pin.js.
final class ParentalPinAndLockToolsTests: XCTestCase {
    private let salt = "0123456789abcdef0123456789abcdef"

    func testHashesMatchTheEditor() {
        XCTAssertEqual(ParentalPin.hash(pin: "135790", salt: salt),
                       "pbkdf2-sha256$100000$cd1acbfdcaa962d759a8dab87c23a654f5c696abf2e8f5c7cb8bee6699edcc48")
        XCTAssertEqual(ParentalPin.legacySHA256(pin: "246810", salt: salt),
                       "87a7255c0b85f145372cdd6868e15934785693be23e5d7911b4b0fcd3c7c4ff3")
        XCTAssertEqual(ParentalPin.legacyFallbackHash(pin: "112233", salt: salt), "fb192946b2f0547a")
        XCTAssertEqual(ParentalPin.legacyFallbackHash(pin: "000000", salt: "a"), "fb1f48a7366e33db")
    }

    func testVerifyAndUpgrade() {
        let current: [String: Any] = ["id": "g", "parentalPasswordSalt": salt, "parentalPasswordHash": ParentalPin.hash(pin: "135790", salt: salt)]
        XCTAssertTrue(ParentalPin.verify(group: current, pin: "135790").ok)
        XCTAssertFalse(ParentalPin.verify(group: current, pin: "135791").ok)
        let old: [String: Any] = ["id": "o", "parentalPasswordSalt": salt, "parentalPasswordHash": "87a7255c0b85f145372cdd6868e15934785693be23e5d7911b4b0fcd3c7c4ff3"]
        let result = ParentalPin.verify(group: old, pin: "246810")
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.upgradedHash, ParentalPin.hash(pin: "246810", salt: salt), "an old-format PIN is upgraded")
    }

    func testRetryWait() {
        XCTAssertEqual([1, 2, 3, 7, 8, 20].map { ParentalPin.retryDelayMs(failures: $0) }, [1000, 2000, 4000, 64000, 64000, 64000])
        let group: [String: Any] = ["id": "g", "parentalPasswordSalt": salt, "parentalPasswordHash": ParentalPin.hash(pin: "135790", salt: salt)]
        var attempts: [String: Any] = [:]
        XCTAssertEqual(ParentalPin.check(attempts: &attempts, group: group, pin: "000000", nowMs: 0), .wrong(waitSeconds: 1))
        XCTAssertEqual(ParentalPin.check(attempts: &attempts, group: group, pin: "135790", nowMs: 500), .waiting(seconds: 1))
        XCTAssertEqual(ParentalPin.check(attempts: &attempts, group: group, pin: "000001", nowMs: 1000), .wrong(waitSeconds: 2))
        XCTAssertEqual(ParentalPin.check(attempts: &attempts, group: group, pin: "135790", nowMs: 3000), .ok(upgradedHash: nil))
        XCTAssertTrue(attempts.isEmpty)
    }

    // MARK: Store actions

    private func document() -> WebStoreDocument {
        WebStoreDocument(raw: ["blockedGroups": [
            ["id": "a", "name": "A", "freezeMode": "none", "strictFreezeHours": 24],
            ["id": "b", "name": "B", "freezeMode": "none"],
        ]])
    }

    func testCreateMoveAndLockLikeTheEditor() throws {
        var doc = document()
        let id = try doc.createGroup(name: "Focus")
        XCTAssertThrowsError(try doc.createGroup(name: " focus ")) { XCTAssertEqual($0 as? GroupStoreError, .duplicateName("focus")) }
        XCTAssertEqual(doc.group(id: id)?["freezeMode"] as? String, "none", "a created group is never locked")
        var withDefault = WebStoreDocument(raw: ["globalSettings": ["defaultSnoozeMinutes": 7], "blockedGroups": []])
        let seven = try withDefault.createGroup(name: "Seven")
        XCTAssertEqual(withDefault.group(id: seven)?["snoozeMinutes"] as? Double, 7, "the user's default snooze length")

        try doc.moveGroup(id: id, to: 0)
        XCTAssertEqual(doc.groupIDs.first, id)
        XCTAssertEqual(try doc.lockGroup(id: "a", mode: .frozen), .done)
        XCTAssertThrowsError(try doc.moveGroup(id: "a", to: 0)) { XCTAssertEqual($0 as? GroupStoreError, .groupLocked("a")) }
        XCTAssertThrowsError(try doc.lockGroup(id: "a", mode: .strict)) { XCTAssertEqual($0 as? GroupStoreError, .groupLocked("a")) }
        XCTAssertThrowsError(try doc.lockGroup(id: "b", mode: .strict, strictHours: 100))
        XCTAssertThrowsError(try doc.lockGroup(id: "b", mode: .parental)) { XCTAssertEqual($0 as? GroupStoreError, .pinRequired) }
    }

    func testUnlockGates() throws {
        var doc = document()
        let now = Date(timeIntervalSince1970: 1_000_000)
        try doc.lockGroup(id: "a", mode: .frozen, now: now)
        XCTAssertEqual(try doc.unlockGroup(id: "a", now: now), .needsConfirmation)
        XCTAssertEqual(try doc.unlockGroup(id: "a", confirmed: true, now: now), .done)
        XCTAssertEqual(doc.group(id: "a")?["freezeMode"] as? String, "none")
        XCTAssertThrowsError(try doc.unlockGroup(id: "a")) { XCTAssertEqual($0 as? GroupStoreError, .notLocked("a")) }

        try doc.lockGroup(id: "a", mode: .strict, strictHours: 2, now: now)
        XCTAssertEqual(try doc.unlockGroup(id: "a", confirmed: true, now: now.addingTimeInterval(3600)),
                       .strictUntil(now.addingTimeInterval(7200)), "strict opens only after its hours")
        XCTAssertEqual(try doc.unlockGroup(id: "a", confirmed: true, now: now.addingTimeInterval(7201)), .done)

        try doc.lockGroup(id: "b", mode: .parental, pin: "482915", now: now)
        let wrong = try doc.unlockGroup(id: "b", pin: "000000", now: now)
        XCTAssertEqual(wrong, .pinWrong(waitSeconds: 1))
        XCTAssertNotNil((doc.raw[ParentalPin.attemptsKey] as? [String: Any])?["b"], "the wrong PIN is counted in the editor's own store key")
        XCTAssertEqual(try doc.unlockGroup(id: "b", pin: "482915", now: now.addingTimeInterval(0.5)), .pinWait(seconds: 1))
        XCTAssertEqual(try doc.unlockGroup(id: "b", pin: "482915", now: now.addingTimeInterval(2)), .done)
    }

    func testTheUnlockToolAsksWaitsAndConfirms() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("locktools-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let shared = SharedAppGroupStore(baseDirectory: dir)
        shared.writeData(try JSONSerialization.data(withJSONObject: document().raw), to: SharedAppGroupStore.webStoreFileName)
        var now = Date(timeIntervalSince1970: 1_000_000)
        let tools = VaultMCPTools.groupTools(store: GroupStore(shared: shared), clock: { now })
        func call(_ name: String, _ args: [String: Any]) -> MCPToolResult {
            tools.first { $0.name == name }!.handler(args)
        }
        XCTAssertFalse(call("lock_group", ["id": "a", "mode": "frozen"]).isError)
        XCTAssertFalse(call("unlock_group", ["id": "a"]).isError, "the first call asks")
        now.addTimeInterval(2)
        XCTAssertTrue(call("unlock_group", ["id": "a", "confirm": true]).isError, "too early")
        now.addTimeInterval(4)
        XCTAssertFalse(call("unlock_group", ["id": "a", "confirm": true]).isError)
        XCTAssertEqual(GroupStore(shared: shared).load().group(id: "a")?["freezeMode"] as? String, "none")
        XCTAssertTrue(call("unlock_group", ["id": "a", "confirm": true]).isError, "not locked any more")

        XCTAssertFalse(call("lock_group", ["id": "b", "mode": "parental", "pin": "482915"]).isError)
        XCTAssertTrue(call("unlock_group", ["id": "b", "pin": "111111"]).isError)
        let counted = GroupStore(shared: shared).load().raw[ParentalPin.attemptsKey] as? [String: Any]
        XCTAssertNotNil(counted?["b"], "a wrong PIN through a tool is saved like one typed in the editor")
    }
}
