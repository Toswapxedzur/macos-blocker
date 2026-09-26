import XCTest
@testable import MacBlockerCore

/// Owner 2026-09-26: the AI tools get exactly the user's gates, and a lock has
/// parallel gates (a wait, a PIN) plus the confirmation on every unfreeze
/// (10 × 5 s). The Mac tools run the editor's own group-actions.js and
/// parental-pin.js in JavaScriptCore; reference values come from the JS.
final class ParentalPinAndLockToolsTests: XCTestCase {
    private let salt = "0123456789abcdef0123456789abcdef"
    private let runtime = GroupActionsRuntime.shared

    func testThePinCodeRunsInJavaScriptCoreWithTheEditorsResults() {
        let current: [String: Any] = ["id": "g", "parentalPasswordSalt": salt,
            "parentalPasswordHash": "pbkdf2-sha256$100000$cd1acbfdcaa962d759a8dab87c23a654f5c696abf2e8f5c7cb8bee6699edcc48"]
        let ok = runtime.call("verifySync", [current, "135790"], module: "CBParentalPin") as? [String: Any]
        XCTAssertEqual(ok?["ok"] as? Bool, true, "the editor's PBKDF2 hash verifies in JavaScriptCore")
        let wrong = runtime.call("verifySync", [current, "135791"], module: "CBParentalPin") as? [String: Any]
        XCTAssertEqual(wrong?["ok"] as? Bool, false)
        let legacy: [String: Any] = ["id": "o", "parentalPasswordSalt": salt,
            "parentalPasswordHash": "87a7255c0b85f145372cdd6868e15934785693be23e5d7911b4b0fcd3c7c4ff3"]
        let upgraded = runtime.call("verifySync", [legacy, "246810"], module: "CBParentalPin") as? [String: Any]
        XCTAssertEqual(upgraded?["ok"] as? Bool, true)
        XCTAssertEqual((upgraded?["upgradedHash"] as? String)?.hasPrefix("pbkdf2-sha256$100000$"), true)
        let fields = runtime.call("newPinFieldsSync", ["482915"], module: "CBParentalPin") as? [String: Any]
        XCTAssertEqual((fields?["parentalPasswordSalt"] as? String)?.count, 32, "salt bytes come from the Mac's random source")
        XCTAssertEqual(runtime.constant("CONFIRMATIONS") as? Int, 10)
    }

    func testTheBundledRulesAreTheEditorsFiles() throws {
        // sync-webui.sh copies them; a stale copy would give the tools other rules.
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for name in ["group-actions.js", "parental-pin.js"] {
            let canonical = repo.deletingLastPathComponent().appendingPathComponent("customBlocker/\(name)")
            guard FileManager.default.fileExists(atPath: canonical.path) else { continue }
            let bundled = repo.appendingPathComponent("Sources/MacBlockerCore/Resources/\(name)")
            XCTAssertEqual(try Data(contentsOf: bundled), try Data(contentsOf: canonical), "\(name) is stale: run sync-webui.sh")
        }
    }

    func testSchedulesAndMinutesReadLikeTheEditor() throws {
        // The Mac reads the editor's store with its own parsers; they must
        // accept exactly what the editor's (group-actions.js) accept.
        let lines = ["0900-1700", "2300-0100", "1200-1200", "09:00-17:00", "900-1700", "2400-0100", "0960-1000", " 0800-0900 ", "0800 - 0900", "abcd-efgh"]
        for line in lines {
            let js = runtime.call("normalizeTimeWindowLine", [line]) as? String
            let swift = ScheduleParser.parseWindow(line)
            XCTAssertEqual(js != nil, swift != nil, "\(line): editor \(js ?? "rejects"), Mac \(swift == nil ? "rejects" : "accepts")")
        }
        for value: Any in [30, 0, -5, 1.5, "abc"] {
            let js = runtime.call("parseAllowedMinutes", [value]) as? Double
            let data = try JSONSerialization.data(withJSONObject: ["blockedGroups": [["id": "g", "name": "G", "allowedMinutes": value]]])
            let swift = try ChromeExtensionImporter.importGroups(from: data).groups.first?.allowedMinutes
            XCTAssertEqual(swift, js ?? 15, "allowedMinutes \(value)")
        }
    }

    // MARK: Store actions

    private func document() -> WebStoreDocument {
        let unlocked = runtime.call("normalizeLock", [[String: Any]()]) as? [String: Any] ?? [:]
        return WebStoreDocument(raw: ["blockedGroups": [
            ["id": "a", "name": "A"].merging(unlocked) { $1 },
            ["id": "b", "name": "B"].merging(unlocked) { $1 },
        ]])
    }

    func testCreateMoveAndFreezeLikeTheEditor() throws {
        var doc = document()
        let id = try doc.createGroup(name: "Focus")
        XCTAssertThrowsError(try doc.createGroup(name: " focus ")) { XCTAssertEqual($0 as? GroupStoreError, .duplicateName("focus")) }
        XCTAssertFalse(WebStoreDocument.isLocked(doc.group(id: id) ?? [:]), "a created group is never frozen")
        var withDefault = WebStoreDocument(raw: ["globalSettings": ["defaultSnoozeMinutes": 7], "blockedGroups": []])
        let seven = try withDefault.createGroup(name: "Seven")
        XCTAssertEqual(withDefault.group(id: seven)?["snoozeMinutes"] as? Double, 7, "the user's default snooze length")

        try doc.moveGroup(id: id, to: 0)
        XCTAssertEqual(doc.groupIDs.first, id)
        XCTAssertEqual(try doc.lockGroup(id: "a", waitHours: 2), .done)
        XCTAssertTrue(WebStoreDocument.isLocked(doc.group(id: "a") ?? [:]))
        XCTAssertEqual(doc.group(id: "a")?["lockWaitHours"] as? Double, 2)
        XCTAssertThrowsError(try doc.moveGroup(id: "a", to: 0)) { XCTAssertEqual($0 as? GroupStoreError, .groupLocked("a")) }
        XCTAssertEqual(try doc.lockGroup(id: "a", waitHours: 1), .refused("not-stricter"), "while frozen only stricter")
        XCTAssertEqual(try doc.lockGroup(id: "a", waitHours: 5), .done)
        XCTAssertEqual(try doc.lockGroup(id: "a", pin: "482915"), .done, "a PIN where there was none is stricter")
        XCTAssertEqual(try doc.lockGroup(id: "a", pin: "111111"), .refused("pin-already-set"))
    }

    func testUnfreezeGates() throws {
        var doc = document()
        let now = Date(timeIntervalSince1970: 1_000_000)
        try doc.lockGroup(id: "a", waitHours: 2, now: now)
        XCTAssertEqual(try doc.unlockCheck(id: "a", pin: nil, now: now.addingTimeInterval(3600)),
                       .waitUntil(now.addingTimeInterval(7200)), "the wait gate holds for its hours")
        XCTAssertEqual(try doc.unlockCheck(id: "a", pin: nil, now: now.addingTimeInterval(7201)), .done)
        let version = (doc.group(id: "a")?["lockVersion"] as? NSNumber)?.intValue ?? -1
        XCTAssertEqual(try doc.unlockGroup(id: "a", lockVersion: version - 1, now: now.addingTimeInterval(7300)), .refused("lock-changed"))
        XCTAssertEqual(try doc.unlockGroup(id: "a", lockVersion: version, now: now.addingTimeInterval(7300)), .done)
        XCTAssertFalse(WebStoreDocument.isLocked(doc.group(id: "a") ?? [:]))
        XCTAssertThrowsError(try doc.unlockCheck(id: "a", pin: nil)) { XCTAssertEqual($0 as? GroupStoreError, .notLocked("a")) }

        try doc.lockGroup(id: "b", pin: "482915", now: now)
        XCTAssertEqual(try doc.unlockCheck(id: "b", pin: "000000", now: now), .pinWrong(waitSeconds: 1))
        XCTAssertNotNil((doc.raw["parentalPinAttempts"] as? [String: Any])?["b"], "the wrong PIN is counted in the editor's own store key")
        XCTAssertEqual(try doc.unlockCheck(id: "b", pin: "482915", now: now.addingTimeInterval(0.5)), .pinWait(seconds: 1))
        XCTAssertEqual(try doc.unlockCheck(id: "b", pin: "482915", now: now.addingTimeInterval(2)), .done)
    }

    func testSnoozeToolsFollowTheEditorsRules() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("snoozetools-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let shared = SharedAppGroupStore(baseDirectory: dir)
        var raw = document().raw
        var groups = raw["blockedGroups"] as? [[String: Any]] ?? []
        groups[0]["snoozeMinutes"] = 10
        groups[0]["snoozeConfirmations"] = 1
        raw["blockedGroups"] = groups
        shared.writeData(try JSONSerialization.data(withJSONObject: raw), to: SharedAppGroupStore.webStoreFileName)
        var now = Date(timeIntervalSince1970: 1_000_000)
        let tools = VaultMCPTools.groupTools(store: GroupStore(shared: shared), clock: { now })
        func call(_ name: String, _ args: [String: Any]) -> MCPToolResult { tools.first { $0.name == name }!.handler(args) }
        XCTAssertFalse(call("lock_group", ["id": "a"]).isError, "snoozing works on a frozen group too")
        let asked = call("snooze_group", ["id": "a"]); XCTAssertFalse(asked.isError, "asks its one confirmation: \(asked.text)")
        now.addTimeInterval(5)
        XCTAssertFalse(call("snooze_group", ["id": "a", "confirm": true]).isError)
        let entry = (GroupStore(shared: shared).load().raw["groupSnoozes"] as? [String: Any])?["a"] as? [String: Any]
        XCTAssertEqual(((entry?["untilMs"] as? NSNumber)?.doubleValue ?? 0) - ((entry?["startsAtMs"] as? NSNumber)?.doubleValue ?? 0), 600_000, "10 min from the saved settings")
        XCTAssertTrue(call("snooze_group", ["id": "a"]).isError, "one at a time")
        now.addTimeInterval(60)
        XCTAssertFalse(call("end_snooze", ["id": "a"]).isError)
        let ended = (GroupStore(shared: shared).load().raw["groupSnoozes"] as? [String: Any])?["a"] as? [String: Any]
        XCTAssertEqual(ended?["activeMsApplied"] as? Bool, true, "the ended entry is kept")
        XCTAssertEqual(((GroupStore(shared: shared).load().raw["groupSnoozeTotalsMs"] as? [String: Any])?["a"] as? NSNumber)?.doubleValue, 60_000, "the 60 s it ran")
    }

    func testTheUnlockToolRunsTheWholeConfirmation() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("locktools-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let shared = SharedAppGroupStore(baseDirectory: dir)
        shared.writeData(try JSONSerialization.data(withJSONObject: document().raw), to: SharedAppGroupStore.webStoreFileName)
        var now = Date(timeIntervalSince1970: 1_000_000)
        let tools = VaultMCPTools.groupTools(store: GroupStore(shared: shared), clock: { now })
        func call(_ name: String, _ args: [String: Any]) -> MCPToolResult {
            tools.first { $0.name == name }!.handler(args)
        }
        XCTAssertFalse(call("lock_group", ["id": "a"]).isError)
        XCTAssertFalse(call("unlock_group", ["id": "a"]).isError, "the first call starts the confirmation")
        now.addTimeInterval(2)
        XCTAssertTrue(call("unlock_group", ["id": "a", "confirm": true]).isError, "too early")
        for step in 1...10 {
            now.addTimeInterval(5)
            let result = call("unlock_group", ["id": "a", "confirm": true])
            XCTAssertFalse(result.isError, "step \(step): \(result.text)")
            XCTAssertEqual(WebStoreDocument.isLocked(GroupStore(shared: shared).load().group(id: "a") ?? [:]), step < 10)
        }

        XCTAssertFalse(call("lock_group", ["id": "b", "pin": "482915"]).isError)
        XCTAssertTrue(call("unlock_group", ["id": "b", "pin": "111111"]).isError)
        let counted = GroupStore(shared: shared).load().raw["parentalPinAttempts"] as? [String: Any]
        XCTAssertNotNil(counted?["b"], "a wrong PIN through a tool is saved like one typed in the editor")
    }
}
