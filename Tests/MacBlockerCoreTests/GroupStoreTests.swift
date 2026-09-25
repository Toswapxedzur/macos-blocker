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
                    "mode": "timer",
                    // Editor-only platform controls with no native equivalent:
                    "platformVideoMode": "all",
                    "platformAuthors": ["@someone"],
                ],
            ],
            "globalSettings": ["defaultSnoozeMinutes": 30],
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
        try document.setGroupEnabled(id: "g2", true)

        // Unknown top-level keys untouched.
        XCTAssertEqual(document.raw["globalSettings"] as? [String: Int], ["defaultSnoozeMinutes": 30])
        XCTAssertEqual(document.raw["usageTimersMs"] as? [String: Int], ["g1": 1000, "g2": 0])
        XCTAssertNotNil(document.raw["ruleLog"])

        // The edited group changed only its `enabled` field; its editor-only
        // platform fields survived.
        let g2 = try XCTUnwrap(document.group(id: "g2"))
        XCTAssertEqual(g2["enabled"] as? Bool, true)
        XCTAssertEqual(g2["platformVideoMode"] as? String, "all")
        XCTAssertEqual(g2["platformAuthors"] as? [String], ["@someone"])

        // The untouched group is byte-identical.
        let g1 = try XCTUnwrap(document.group(id: "g1"))
        XCTAssertEqual(g1["fallbackUrl"] as? String, "https://calm.example")
    }

    // MARK: WebStoreDocument — individual mutations

    func testSetModeRenameAllowedMinutes() throws {
        var document = WebStoreDocument(raw: sampleEnvelope())
        try document.setGroupMode(id: "g1", .afterMinutes)
        try document.renameGroup(id: "g1", name: "  Deep Work  ")
        try document.setGroupAllowedMinutes(id: "g1", 45)

        let g1 = try XCTUnwrap(document.group(id: "g1"))
        XCTAssertEqual(g1["mode"] as? String, "after-minutes")
        XCTAssertEqual(g1["name"] as? String, "Deep Work") // trimmed
        XCTAssertEqual(g1["allowedMinutes"] as? Int, 45)
    }

    func testRenameRejectsEmpty() {
        var document = WebStoreDocument(raw: sampleEnvelope())
        XCTAssertThrowsError(try document.renameGroup(id: "g1", name: "   ")) { error in
            XCTAssertEqual(error as? GroupStoreError, .invalidInput("name"))
        }
    }

    func testMutatingMissingGroupThrows() {
        var document = WebStoreDocument(raw: sampleEnvelope())
        XCTAssertThrowsError(try document.setGroupEnabled(id: "nope", true)) { error in
            XCTAssertEqual(error as? GroupStoreError, .groupNotFound("nope"))
        }
    }

    func testAddWebsiteIsIdempotentAcrossNormalization() throws {
        var document = WebStoreDocument(raw: sampleEnvelope())
        // Same host as the seeded "https://www.example.com/path".
        try document.addWebsite(id: "g1", host: "example.com")
        try document.addWebsite(id: "g1", host: "https://www.example.com")
        var sites = WebStoreDocument.sites(of: try XCTUnwrap(document.group(id: "g1")))
        XCTAssertEqual(sites.count, 1, "normalized-duplicate hosts must not stack")
        XCTAssertNil(document.group(id: "g1")?["sites"], "the legacy top-level list is folded into the site line")

        try document.addWebsite(id: "g1", host: "news.ycombinator.com")
        sites = WebStoreDocument.sites(of: try XCTUnwrap(document.group(id: "g1")))
        XCTAssertEqual(sites.count, 2)
        XCTAssertTrue(sites.contains("news.ycombinator.com"))
    }

    func testRemoveWebsiteMatchesByNormalizedHost() throws {
        var document = WebStoreDocument(raw: sampleEnvelope())
        try document.removeWebsite(id: "g1", host: "https://example.com")
        let sites = WebStoreDocument.sites(of: try XCTUnwrap(document.group(id: "g1")))
        XCTAssertTrue(sites.isEmpty)
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

    // MARK: Lock mode (frozen / strict / parental)

    private func lockedEnvelope(appsExcept: Bool) -> [String: Any] {
        ["blockedGroups": [[
            "id": "L", "name": "Locked", "enabled": true, "mode": "instant", "freezeMode": "strict",
            "scopes": [["id": "apps-1", "surface": "apps", "platform": NSNull(), "action": "block",
                        "apps": [["id": "com.example.Editor", "name": "Editor"]], "appsExcept": appsExcept]],
        ]]]
    }

    func testALockedGroupRefusesEveryToolEdit() {
        var document = WebStoreDocument(raw: lockedEnvelope(appsExcept: false))
        let edits: [(inout WebStoreDocument) throws -> Void] = [
            { try $0.setGroupEnabled(id: "L", false) },
            { try $0.setGroupMode(id: "L", .afterMinutes) },
            { try $0.setGroupAllowedMinutes(id: "L", 90) },
            { try $0.renameGroup(id: "L", name: "Other") },
            { try $0.removeApplication(id: "L", bundleID: "com.example.Editor") },
            { try $0.addWebsite(id: "L", host: "x.com") },
            { try $0.deleteGroup(id: "L") },
        ]
        for edit in edits {
            XCTAssertThrowsError(try edit(&document)) { error in
                XCTAssertEqual(error as? GroupStoreError, .groupLocked("L"))
            }
        }
        XCTAssertEqual(document.groupCount, 1)
    }

    func testBlockApplicationOnlyTightensEvenWhenLocked() throws {
        var blocklist = WebStoreDocument(raw: lockedEnvelope(appsExcept: false))
        XCTAssertTrue(try blocklist.blockApplication(id: "L", bundleID: "com.hnc.Discord", name: "Discord"))
        XCTAssertEqual(WebStoreDocument.apps(of: blocklist.group(id: "L")!).compactMap { $0["id"] as? String },
                       ["com.example.Editor", "com.hnc.Discord"], "a blocklist gains the app")

        var allowlist = WebStoreDocument(raw: lockedEnvelope(appsExcept: true))
        XCTAssertFalse(try allowlist.blockApplication(id: "L", bundleID: "com.hnc.Discord", name: "Discord"),
                       "an app outside the allowlist is already blocked")
        XCTAssertTrue(try allowlist.blockApplication(id: "L", bundleID: "com.example.Editor", name: "Editor"))
        XCTAssertTrue(WebStoreDocument.apps(of: allowlist.group(id: "L")!).isEmpty, "the allowlist loses the app instead of gaining it")
        XCTAssertTrue(WebStoreDocument.appsExcept(of: allowlist.group(id: "L")!))
    }

    func testDeleteMissingGroupThrows() {
        var document = WebStoreDocument(raw: sampleEnvelope())
        XCTAssertThrowsError(try document.deleteGroup(id: "nope")) { error in
            XCTAssertEqual(error as? GroupStoreError, .groupNotFound("nope"))
        }
    }

    // MARK: GroupStore — I/O + enforcement-plan derivation

    func testMutatePersistsAndRebuildsEnforcementPlan() throws {
        let (store, shared, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Seed the store file.
        let seed = try JSONSerialization.data(withJSONObject: sampleEnvelope())
        shared.writeData(seed, to: SharedAppGroupStore.webStoreFileName)

        // Enable g2 (a timer group) so it enters the plan, and disable g1.
        _ = try store.mutate {
            try $0.setGroupEnabled(id: "g2", true)
            try $0.setGroupEnabled(id: "g1", false)
        }

        // The persisted store round-trips and kept unknown keys.
        let reloaded = store.load()
        XCTAssertEqual(reloaded.group(id: "g2")?["enabled"] as? Bool, true)
        XCTAssertNotNil(reloaded.raw["ruleLog"])

        // The derived plan reflects the new enabled set (only g2 is enabled).
        let plan = try XCTUnwrap(shared.loadEnforcementPlan())
        XCTAssertEqual(plan.entries.map(\.groupID), ["g2"])
    }

    func testLoadGroupsReturnsEnforcementProjection() throws {
        let (store, shared, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let seed = try JSONSerialization.data(withJSONObject: sampleEnvelope())
        shared.writeData(seed, to: SharedAppGroupStore.webStoreFileName)

        let groups = store.loadGroups()
        XCTAssertEqual(groups.map(\.id), ["g1", "g2"])
        // The lossy projection collapses the youtube platform type to .app.
        XCTAssertEqual(groups.first { $0.id == "g2" }?.groupType, .app)
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

        _ = try store.mutate { try $0.setGroupEnabled(id: "g1", false) }
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
        XCTAssertThrowsError(try store.mutate { try $0.setGroupEnabled(id: "missing", false) })
        XCTAssertEqual(posts, 0, "a no-op/failed mutation must not notify")

        // The lock was released on the throw path: this real mutation must not
        // deadlock, and it notifies exactly once.
        _ = try store.mutate { try $0.setGroupEnabled(id: "g1", false) }
        XCTAssertEqual(posts, 1)
    }
}
