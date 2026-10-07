import XCTest
@testable import MacBlockerCore

final class GroupStoreTests: XCTestCase {

    // A store envelope carrying: two groups (one with an editor-only field and a
    // platform group type the native BlockGroup projection collapses), plus
    // top-level keys native code does not model. Every one of these must survive
    // a field-surgical mutation untouched.
    private func sampleEnvelope() -> [String: Any] {
        [
            "blockedGroups": [
                [
                    "id": "g1",
                    "groupType": "site",
                    "name": "Focus",
                    "enabled": true,
                    "mode": "instant",
                    "allowedMinutes": 15,
                    "sites": ["https://www.example.com/path"],
                    "apps": [["id": "com.apple.Safari", "name": "Safari"]],
                    // Editor-only field the native BlockGroup projection drops:
                    "fallbackUrl": "https://calm.example",
                ],
                [
                    "id": "g2",
                    "groupType": "youtube",
                    "name": "YouTube",
                    "enabled": false,
                    "mode": "after-minutes",
                    // Editor-only platform controls with no native equivalent:
                    "platformVideoMode": "all",
                    "sources": ["@someone"],
                ],
            ],
            "globalSettings": ["quitRetryMinutes": 5],
            "usageTimersMs": ["g1": 1000, "g2": 0],
            "usageResetAtMs": ["g1": 42],
            "ruleLog": [["message": "hi"]],
        ]
    }

    private func makeStore() -> (GroupStore, SharedAppGroupStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("groupstore-tests-\(UUID().uuidString)", isDirectory: true)
        let shared = SharedAppGroupStore(baseDirectory: dir)
        return (GroupStore(shared: shared), shared, dir)
    }

    // MARK: WebStoreDocument — loss preservation

    func testMutationPreservesUnknownTopLevelKeysAndGroupFields() throws {
        var document = WebStoreDocument(raw: sampleEnvelope())
        try document.setGroup(id: "g2", patch: ["enabled": true])

        // Unknown top-level keys untouched.
        XCTAssertEqual(document.raw["globalSettings"] as? [String: Int], ["quitRetryMinutes": 5])
        XCTAssertEqual(document.raw["usageTimersMs"] as? [String: Int], ["g1": 1000, "g2": 0])
        XCTAssertNotNil(document.raw["ruleLog"])

        // The edited group is stored as the editor stores it: its platform
        // fields live in its lines.
        let g2 = try XCTUnwrap(document.group(id: "g2"))
        XCTAssertEqual(g2["enabled"] as? Bool, true)
        let lines = g2["scopes"] as? [[String: Any]] ?? []
        XCTAssertTrue(lines.contains { ($0["sources"] as? [String])?.isEmpty == false }, "its creator list survived, in its lines: \(lines)")

        // The untouched group is byte-identical.
        let g1 = try XCTUnwrap(document.group(id: "g1"))
        XCTAssertEqual(g1["fallbackUrl"] as? String, "https://calm.example")
    }

    // MARK: WebStoreDocument — individual mutations

    func testSetModeRenameAllowedMinutes() throws {
        var document = WebStoreDocument(raw: sampleEnvelope())
        try document.setGroup(id: "g1", patch: ["mode": "after-minutes"])
        try document.setGroup(id: "g1", patch: ["name": "  Deep Work  "])
        try document.setGroup(id: "g1", patch: ["allowedMinutes": 45])

        let g1 = try XCTUnwrap(document.group(id: "g1"))
        XCTAssertEqual(g1["mode"] as? String, "after-minutes")
        XCTAssertEqual(g1["name"] as? String, "Deep Work") // trimmed
        XCTAssertEqual(g1["allowedMinutes"] as? Int, 45)
    }

    func testRenameRejectsEmpty() {
        var document = WebStoreDocument(raw: sampleEnvelope())
        XCTAssertThrowsError(try document.setGroup(id: "g1", patch: ["name": "   "])) { error in
            XCTAssertEqual(error as? GroupStoreError, .invalidInput("invalid-name"))
        }
    }

    func testMutatingMissingGroupThrows() {
        var document = WebStoreDocument(raw: sampleEnvelope())
        XCTAssertThrowsError(try document.setGroup(id: "nope", patch: ["enabled": true])) { error in
            XCTAssertEqual(error as? GroupStoreError, .groupNotFound("nope"))
        }
    }

    func testMacToolsNeverEditWebsiteLines() throws {
        // The scope line (owner 2026-09-27): Mac Vault edits only the Apps lines.
        var document = WebStoreDocument(raw: sampleEnvelope())
        XCTAssertThrowsError(try document.setGroup(id: "g1", patch: ["scopes": [["surface": "site", "action": "block", "sites": ["x.com"]]]])) { error in
            XCTAssertEqual(error as? GroupStoreError, .invalidInput("browser-lines"))
        }
        let apps: [[String: Any]] = [["surface": "apps", "action": "block", "apps": [["id": "com.example.App", "name": "App"]], "appsExcept": false]]
        try document.setGroup(id: "g1", patch: ["scopes": apps])
        let lines = document.group(id: "g1")?["scopes"] as? [[String: Any]] ?? []
        XCTAssertTrue(lines.contains { ($0["surface"] as? String) == "site" }, "lines sent without the browser's keep them as stored")
        XCTAssertEqual(WebStoreDocument.apps(of: document.group(id: "g1") ?? [:]).first?["id"] as? String, "com.example.App")
    }

    func testAddRemoveApplication() throws {
        var document = WebStoreDocument(raw: sampleEnvelope())
        try document.addApplication(id: "g1", bundleID: "com.apple.Safari", name: "Safari")
        var apps = WebStoreDocument.apps(of: try XCTUnwrap(document.group(id: "g1")))
        XCTAssertEqual(apps.count, 1, "duplicate bundle id must not stack")

        try document.addApplication(id: "g1", bundleID: "com.tinyspeck.slackmacgap", name: nil)
        apps = WebStoreDocument.apps(of: try XCTUnwrap(document.group(id: "g1")))
        XCTAssertEqual(apps.count, 2)
        let slack = try XCTUnwrap(apps.first { ($0["id"] as? String) == "com.tinyspeck.slackmacgap" })
        XCTAssertEqual(slack["name"] as? String, "com.tinyspeck.slackmacgap") // falls back to id

        try document.removeApplication(id: "g1", bundleID: "com.apple.Safari")
        apps = WebStoreDocument.apps(of: try XCTUnwrap(document.group(id: "g1")))
        XCTAssertEqual(apps.map { $0["id"] as? String }, ["com.tinyspeck.slackmacgap"])
    }

    func testDeleteGroupRemovesGroupAndCompanionKeys() throws {
        var document = WebStoreDocument(raw: sampleEnvelope())
        try document.deleteGroup(id: "g1")

        XCTAssertEqual(document.groupIDs, ["g2"])
        // Companion per-group maps are pruned for the deleted id, kept for others.
        XCTAssertEqual(document.raw["usageTimersMs"] as? [String: Int], ["g2": 0])
        XCTAssertEqual(document.raw["usageResetAtMs"] as? [String: Int], [:])
    }

    func testDeleteGroupClearsItsRollingMinutesToo() throws {
        var raw = sampleEnvelope()
        raw["usageBucketsMs"] = ["g1": ["60000": 1000], "g2": ["60000": 5]]
        var document = WebStoreDocument(raw: raw)
        try document.deleteGroup(id: "g1")
        XCTAssertEqual((document.raw["usageBucketsMs"] as? [String: Any])?.keys.sorted(), ["g2"])
    }

    func testRenameRefusesANameAnotherGroupHasInAnyCase() throws {
        var document = WebStoreDocument(raw: sampleEnvelope())
        XCTAssertThrowsError(try document.setGroup(id: "g1", patch: ["name": " youtube "])) { error in
            XCTAssertEqual(error as? GroupStoreError, .duplicateName("youtube"), "groups link by name, so names stay unique, as in the editor")
        }
        try document.setGroup(id: "g1", patch: ["name": "FOCUS"])
        XCTAssertEqual(document.group(id: "g1")?["name"] as? String, "FOCUS", "a group may change its own name's case")
    }

    func testAnEditIsCheckedAndStoredAsTheEditorDoes() throws {
        var document = WebStoreDocument(raw: sampleEnvelope())
        XCTAssertThrowsError(try document.setGroup(id: "g1", patch: ["timeWindowsText": "9-5"])) {
            XCTAssertEqual($0 as? GroupStoreError, .invalidInput("invalid-timeWindowsText"), "refused, never replaced by a default")
        }
        XCTAssertThrowsError(try document.setGroup(id: "g1", patch: ["allowedMinutes": 0]))
        try document.setGroup(id: "g1", patch: ["mode": "after-minutes", "allowedMinutes": 20, "timeWindowsText": "0900-1700"])
        XCTAssertEqual(document.group(id: "g1")?["allowedMinutes"] as? Int, 20)
        XCTAssertEqual(document.group(id: "g1")?["timeWindowsText"] as? String, "09:00-17:00", "stored in the editor's form")
        XCTAssertNotNil(document.group(id: "g1")?["scopes"], "stored through the editor's sanitizer")
    }

    func testLocksAreJudgedOnTheSharedView() throws {
        let (store, shared, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir); GroupStore.sharedOverlay = nil }
        let data = try JSONSerialization.data(withJSONObject: sampleEnvelope())
        shared.writeData(data, to: SharedAppGroupStore.webStoreFileName)
        // A linked device locked g1; the stored copy does not know yet.
        GroupStore.sharedOverlay = { raw in
            var copy = raw
            copy["blockedGroups"] = (raw["blockedGroups"] as? [[String: Any]] ?? []).map { group in
                var g = group
                if g["id"] as? String == "g1" { g["lockedAtMs"] = 1_000; g["name"] = "Focus (shared)" }
                return g
            }
            return copy
        }
        XCTAssertThrowsError(try store.mutate { try $0.setGroup(id: "g1", patch: ["enabled": false]) }) { error in
            XCTAssertEqual(error as? GroupStoreError, .groupLocked("g1"), "an AI tool may not edit what the user cannot")
        }
        XCTAssertEqual(store.loadGroups().first { $0.id == "g1" }?.name, "Focus (shared)", "tools read what the user sees")
        XCTAssertNoThrow(try store.mutate { try $0.setGroup(id: "g2", patch: ["enabled": true]) })
    }

    // MARK: Lock mode (frozen / strict / parental)

    private func lockedEnvelope(appsExcept: Bool) -> [String: Any] {
        ["blockedGroups": [[
            "id": "L", "name": "Locked", "enabled": true, "mode": "instant", "lockedAtMs": 1_000, "lockWaitHours": 24,
            "scopes": [["id": "apps-1", "surface": "apps", "platform": NSNull(), "action": "block",
                        "apps": [["id": "com.example.Editor", "name": "Editor"]], "appsExcept": appsExcept]],
        ]]]
    }

    func testALockedGroupRefusesEveryToolEdit() {
        var document = WebStoreDocument(raw: lockedEnvelope(appsExcept: false))
        let edits: [(inout WebStoreDocument) throws -> Void] = [
            { try $0.setGroup(id: "L", patch: ["enabled": false]) },
            { try $0.setGroup(id: "L", patch: ["mode": "after-minutes"]) },
            { try $0.setGroup(id: "L", patch: ["allowedMinutes": 90]) },
            { try $0.setGroup(id: "L", patch: ["name": "Other"]) },
            { try $0.removeApplication(id: "L", bundleID: "com.example.Editor") },
            { try $0.deleteGroup(id: "L") },
        ]
        for edit in edits {
            XCTAssertThrowsError(try edit(&document)) { error in
                XCTAssertEqual(error as? GroupStoreError, .groupLocked("L"))
            }
        }
        XCTAssertEqual(document.groupCount, 1)
    }

    func testALockedGroupRefusesQuickAddToo() {
        var document = WebStoreDocument(raw: lockedEnvelope(appsExcept: true))
        XCTAssertThrowsError(try document.addApplication(id: "L", bundleID: "com.hnc.Discord", name: "Discord")) { error in
            XCTAssertEqual(error as? GroupStoreError, .groupLocked("L"), "adding to a locked allowlist would loosen it")
        }
    }

    func testDeleteMissingGroupThrows() {
        var document = WebStoreDocument(raw: sampleEnvelope())
        XCTAssertThrowsError(try document.deleteGroup(id: "nope")) { error in
            XCTAssertEqual(error as? GroupStoreError, .groupNotFound("nope"))
        }
    }

    // MARK: GroupStore — I/O + enforcement-plan derivation

    func testMutatePersists() throws {
        let (store, shared, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Seed the store file.
        let seed = try JSONSerialization.data(withJSONObject: sampleEnvelope())
        shared.writeData(seed, to: SharedAppGroupStore.webStoreFileName)

        // Enable g2 (a timed group) so it enters the plan, and disable g1.
        _ = try store.mutate {
            try $0.setGroup(id: "g2", patch: ["enabled": true])
            try $0.setGroup(id: "g1", patch: ["enabled": false])
        }

        // The persisted store round-trips and kept unknown keys.
        let reloaded = store.load()
        XCTAssertEqual(reloaded.group(id: "g2")?["enabled"] as? Bool, true)
        XCTAssertNotNil(reloaded.raw["ruleLog"])
        XCTAssertEqual(reloaded.group(id: "g1")?["enabled"] as? Bool, false)
    }

    func testLoadGroupsReturnsEnforcementProjection() throws {
        let (store, shared, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let seed = try JSONSerialization.data(withJSONObject: sampleEnvelope())
        shared.writeData(seed, to: SharedAppGroupStore.webStoreFileName)

        let groups = store.loadGroups()
        XCTAssertEqual(groups.map(\.id), ["g1", "g2"])
        // Mac Vault tells only rule groups apart; a platform group is a list group.
        XCTAssertEqual(groups.first { $0.id == "g2" }?.groupType, .site)
    }

    func testLoadEmptyWhenNoFile() {
        let (store, _, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(store.load().groupCount, 0)
        XCTAssertTrue(store.loadGroups().isEmpty)
    }

    // MARK: Change notification — live-editor reconciliation

    func testMutateAndSavePostDidChangeNotification() throws {
        let (store, shared, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let seed = try JSONSerialization.data(withJSONObject: sampleEnvelope())
        shared.writeData(seed, to: SharedAppGroupStore.webStoreFileName)

        // A live WebView editor listens for this to re-seed itself after a native
        // (e.g. MCP) write. Observed synchronously (queue: nil) so the count is
        // deterministic on the posting thread.
        var posts = 0
        let token = NotificationCenter.default.addObserver(
            forName: GroupStore.didChangeNotification, object: nil, queue: nil
        ) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        _ = try store.mutate { try $0.setGroup(id: "g1", patch: ["enabled": false]) }
        XCTAssertEqual(posts, 1, "a successful mutation must notify the editor")

        store.save(store.load())
        XCTAssertEqual(posts, 2, "a direct save must notify the editor too")
    }

    func testSaveWithNotifyFalseDoesNotPost() throws {
        let (store, shared, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let seed = try JSONSerialization.data(withJSONObject: sampleEnvelope())
        shared.writeData(seed, to: SharedAppGroupStore.webStoreFileName)

        var posts = 0
        let token = NotificationCenter.default.addObserver(
            forName: GroupStore.didChangeNotification, object: nil, queue: nil
        ) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        // The editor's own persist path passes notify:false so it never re-seeds
        // itself; the default (true) still notifies so external writes reach it.
        store.save(store.load(), notify: false)
        XCTAssertEqual(posts, 0, "notify:false must not post the change notification")
        store.save(store.load())
        XCTAssertEqual(posts, 1, "the default still notifies")
    }

    func testFailedMutationDoesNotPostAndReleasesLock() throws {
        let (store, shared, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let seed = try JSONSerialization.data(withJSONObject: sampleEnvelope())
        shared.writeData(seed, to: SharedAppGroupStore.webStoreFileName)

        var posts = 0
        let token = NotificationCenter.default.addObserver(
            forName: GroupStore.didChangeNotification, object: nil, queue: nil
        ) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        // A throwing body writes nothing, so there is no editor-visible change.
        XCTAssertThrowsError(try store.mutate { try $0.setGroup(id: "missing", patch: ["enabled": false]) })
        XCTAssertEqual(posts, 0, "a no-op/failed mutation must not notify")

        // The lock was released on the throw path: this real mutation must not
        // deadlock, and it notifies exactly once.
        _ = try store.mutate { try $0.setGroup(id: "g1", patch: ["enabled": false]) }
        XCTAssertEqual(posts, 1)
    }
    func testUnsupportedSchemaRefusesNativeMutationAndLateWrite() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let shared = SharedAppGroupStore(baseDirectory: directory), store = GroupStore(shared: SharedAppGroupStore(baseDirectory: directory))
        let url = shared.url(for: SharedAppGroupStore.webStoreFileName)
        let bytes = Data(#"{"schemaVersion":99,"blockedGroups":[{"id":"one"}],"future":"keep"}"#.utf8)
        try bytes.write(to: url)
        XCTAssertThrowsError(try store.mutate { _ in XCTFail("unsupported document must not reach the mutator") })
        store.save(WebStoreDocument(raw: ["blockedGroups": []]))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertEqual(store.loadGroups().count, 0)
    }

    func testAlphaWebStoreWritesMetadataAndPreservesRawState() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let shared = SharedAppGroupStore(baseDirectory: directory)
        let store = GroupStore(shared: shared)
        store.save(WebStoreDocument(raw: ["blockedGroups": [], "opaque": ["keep": true], "usageTimersMs": ["one": 123]]))
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(shared.readData(SharedAppGroupStore.webStoreFileName))) as? [String: Any])
        XCTAssertEqual(raw["schemaVersion"] as? Int, 3)
        XCTAssertEqual((raw["storageMetadata"] as? [String: Any])?["product"] as? String, "mac")
        XCTAssertEqual((raw["opaque"] as? [String: Bool])?["keep"], true)
        XCTAssertEqual((raw["usageTimersMs"] as? [String: Int])?["one"], 123)
    }

}
