import XCTest
@testable import MacBlockerAppFeature
@testable import MacBlockerWebUI
import MacBlockerCore
import struct VaultClassifierCore.StorageSchemaPolicy

/// Real canonical writes and the same JSC admission as the popup. No alternate
/// policy implementation or live preference/application data is used.
final class NativePreciseEditorTests: XCTestCase {
    private let registryKey = "ConnectionHub.clusters.v2"
    private var previousRegistry: Any?
    override func setUpWithError() throws {
        try super.setUpWithError()
        guard Bundle.main.bundleIdentifier?.hasPrefix("com.adamancia.vault.") != true else {
            throw NSError(domain: "PreciseEditorFixture", code: 1)
        }
        previousRegistry = UserDefaults.standard.object(forKey: registryKey)
        UserDefaults.standard.removeObject(forKey: registryKey)
    }
    override func tearDownWithError() throws {
        if let previousRegistry { UserDefaults.standard.set(previousRegistry, forKey: registryKey) }
        else { UserDefaults.standard.removeObject(forKey: registryKey) }
        XCTAssertTrue(UserDefaults.standard.synchronize())
        try super.tearDownWithError()
    }
    private final class Frames {
        private let lock = NSLock()
        private var values: [Data] = []
        func append(_ data: Data) { lock.lock(); values.append(data); lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return values.count }
    }
    private struct Fixture {
        let root: URL
        let store: BlockerWebStore
        let hub: ConnectionHub
        let queue: DispatchQueue
        let frames: Frames
        let now: Double
    }
    private func group(_ id: String, name: String) throws -> [String: Any] {
        let result = try GroupActionsRuntime.shared.callThrowing("createToolGroup",
            [[[String: Any]](), "site", ["name": name], "desktop"], module: "CBGroupScopes") as? [String: Any]
        var group = try XCTUnwrap(result?["group"] as? [String: Any])
        group["id"] = id; group["enabled"] = false; group["allowedMinutes"] = 20
        group["scopes"] = [["id": "apps-1", "entryID": "apps", "surface": "apps", "action": "block",
                            "platform": NSNull(), "apps": [["id": "com.example.Original"]], "appsExcept": false]]
        return group
    }
    private func raw(_ store: BlockerWebStore) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(store.loadRawJSON()).utf8)) as? [String: Any])
    }
    private func local(_ store: BlockerWebStore) throws -> [String: Any] {
        try XCTUnwrap((try raw(store)["blockedGroups"] as? [[String: Any]])?.first { ($0["id"] as? String) == "m1" })
    }
    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-precise-editor-\(UUID().uuidString)")
        let store = BlockerWebStore(shared: SharedAppGroupStore(baseDirectory: root))
        let now = (Date().timeIntervalSince1970 * 1000).rounded(.down)
        store.save(rawStore: ["blockedGroups": [try group("m1", name: "Native20"), try group("other", name: "Other")],
                             "usageTimersMs": ["m1": 5000.0, "other": 73.0], "usageResetAtMs": ["m1": now],
                             "cbRuleState": ["m1": ["events": 3], "other": ["events": 7]], "quickAddGroupId": "m1",
                             "globalSettings": ["sentinel": "preserve"]])
        let queue = DispatchQueue(label: "NativePreciseEditorTests.outbound")
        let frames = Frames()
        let hub = ConnectionHub(testOutboundQueue: queue, outboundDelivery: { frames.append($0) })
        hub.hostingLocalHub = true; hub.localWebStore = store
        hub.setRoster(program: "chrome", groups: [["id": "c1", "name": "Browser"]])
        hub.contributeLocalDefinitions(document: try raw(store), nowMs: now)
        XCTAssertNil(hub.linkGroups(program: "chrome", groupId: "c1", targetProgram: "macapp", targetGroupId: "m1"))
        hub.applySync(program: "chrome", groupId: "c1", contribution: ["scalars": ["name": "Native20", "allowedMinutes": 20, "enabled": false],
                      "scopes": [["id": "site-1", "entryID": "site", "surface": "site", "platform": NSNull(), "action": "block", "sites": ["example.com"]]],
                      "usageMs": 5000.0, "usageResetAtMs": now], ts: 0)
        hub.contributeLocalDefinitions(document: try raw(store), nowMs: now)
        queue.sync {}
        return Fixture(root: root, store: store, hub: hub, queue: queue, frames: frames, now: now)
    }
    private func request(before: [String: Any]?, after: [String: Any]?, intent: String = "edit") throws -> [String: Any] {
        let change = try GroupActionsRuntime.shared.callThrowing("editorChange", [before.map { $0 as Any } ?? NSNull(), after.map { $0 as Any } ?? NSNull(), "desktop"], module: "CBGroupScopes")
        return ["intent": intent, "changes": [change]]
    }
    private func browser24(_ f: Fixture) {
        f.hub.applySync(program: "chrome", groupId: "c1", contribution: ["scalars": ["name": "Browser24", "allowedMinutes": 24, "enabled": false],
                       "scopes": [["id": "site-1", "entryID": "site", "surface": "site", "platform": NSNull(), "action": "block", "sites": ["example.net"]]]], ts: (Date().timeIntervalSince1970 * 1000).rounded(.down))
        f.queue.sync {}
    }
    private func appsEdit(_ before: [String: Any]) -> [String: Any] {
        var after = before
        var lines = before["scopes"] as? [[String: Any]] ?? []
        let index = lines.firstIndex { ($0["surface"] as? String) == "apps" }!
        lines[index]["apps"] = [["id": "com.example.Edited"]]; after["scopes"] = lines
        return after
    }
    func testStaleUIAppsOnlyEditPreservesNewerSharedScalarAndWebsite() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let ui20 = try local(f.store); browser24(f)
        let reply = try f.store.applyEditorDefinitionRequest(request(before: ui20, after: appsEdit(ui20)))
        let saved = try local(f.store)
        XCTAssertEqual(saved["name"] as? String, "Browser24")
        XCTAssertEqual((saved["allowedMinutes"] as? NSNumber)?.intValue, 24)
        XCTAssertTrue(WebStoreDocument.apps(of: saved).contains { ($0["id"] as? String) == "com.example.Edited" })
        XCTAssertEqual((saved["scopes"] as? [[String: Any]])?.first { ($0["surface"] as? String) == "site" }?["sites"] as? [String], ["example.net"])
        XCTAssertTrue(NSDictionary(dictionary: ["groups": reply]).isEqual(to: ["groups": try raw(f.store)["blockedGroups"]!]))
    }
    func testPendingNativeAllowanceThenStaleUIAppsEditPreservesBoth() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let ui20 = try local(f.store); browser24(f)
        let native = GroupStore(shared: SharedAppGroupStore(baseDirectory: f.root))
        try native.mutate { try $0.setGroup(id: "m1", patch: ["allowedMinutes": 30]) }
        _ = try f.store.applyEditorDefinitionRequest(request(before: ui20, after: appsEdit(ui20)))
        let saved = try local(f.store)
        XCTAssertEqual((saved["allowedMinutes"] as? NSNumber)?.intValue, 30)
        XCTAssertEqual(saved["name"] as? String, "Browser24")
        XCTAssertTrue(WebStoreDocument.apps(of: saved).contains { ($0["id"] as? String) == "com.example.Edited" })
    }
    func testGenuineScalarEditAndUnlinkedBudgetRestart() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let before = try local(f.store); browser24(f)
        var after = before; after["allowedMinutes"] = 30
        _ = try f.store.applyEditorDefinitionRequest(request(before: before, after: after))
        XCTAssertEqual((try local(f.store)["allowedMinutes"] as? NSNumber)?.intValue, 30)
        let other = try XCTUnwrap((try raw(f.store)["blockedGroups"] as? [[String: Any]])?.first { ($0["id"] as? String) == "other" })
        var changed = other; changed["mode"] = "after-minutes"; changed["rollingLimit"] = true
        _ = try f.store.applyEditorDefinitionRequest(request(before: other, after: changed))
        let document = try raw(f.store)
        XCTAssertEqual(((document["usageTimersMs"] as? [String: Any])?["other"] as? NSNumber)?.doubleValue, 0)
        XCTAssertNotNil((document["usageResetAtMs"] as? [String: Any])?["other"])
    }
    func testFailedSaveDoesNotPublishOrAcknowledgeAndRetryKeepsIntent() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let ui20 = try local(f.store); browser24(f)
        let edit = try request(before: ui20, after: appsEdit(ui20))
        let bytes = try Data(contentsOf: f.store.fileURL)
        let snapshot = try JSONSerialization.jsonObject(with: Data(f.hub.clustersJSON().utf8)) as! NSDictionary
        let registry = UserDefaults.standard.object(forKey: registryKey) as? Data
        let frames = f.frames.count
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: f.root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.root.path) }
        XCTAssertThrowsError(try f.store.applyEditorDefinitionRequest(edit))
        f.queue.sync {}
        XCTAssertEqual(try Data(contentsOf: f.store.fileURL), bytes)
        XCTAssertEqual(UserDefaults.standard.object(forKey: registryKey) as? Data, registry)
        XCTAssertEqual(f.frames.count, frames)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(f.hub.clustersJSON().utf8)) as? NSDictionary, snapshot)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.root.path)
        _ = try f.store.applyEditorDefinitionRequest(edit)
        XCTAssertEqual((try local(f.store)["allowedMinutes"] as? NSNumber)?.intValue, 24)
    }
    func testRefusedSecondChangeIsAtomicAndCurrentSharedLockWins() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let before = try local(f.store)
        let good = try XCTUnwrap(try request(before: before, after: appsEdit(before))["changes"] as? [Any])
        let bad: [String: Any] = ["id": "missing", "fields": ["set": ["name": "Nope"]]]
        let bytes = try Data(contentsOf: f.store.fileURL); let frames = f.frames.count
        let hubBefore = try JSONSerialization.jsonObject(with: Data(f.hub.clustersJSON().utf8)) as! NSDictionary
        XCTAssertThrowsError(try f.store.applyEditorDefinitionRequest(["intent": "edit", "changes": good + [bad]]))
        f.queue.sync {}; XCTAssertEqual(try Data(contentsOf: f.store.fileURL), bytes); XCTAssertEqual(f.frames.count, frames)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(f.hub.clustersJSON().utf8)) as? NSDictionary, hubBefore)
        f.hub.applySync(program: "chrome", groupId: "c1", contribution: ["scalars": ["name": "BrowserLocked", "allowedMinutes": 24, "enabled": false], "lock": ["lockVersion": 1, "lockedAtMs": f.now, "lockWaitHours": 1], "lockBase": 0], ts: (Date().timeIntervalSince1970 * 1000).rounded(.down))
        f.queue.sync {}; let lockedBytes = try Data(contentsOf: f.store.fileURL); let lockedFrames = f.frames.count
        XCTAssertThrowsError(try f.store.applyEditorDefinitionRequest(request(before: before, after: appsEdit(before))))
        f.queue.sync {}; XCTAssertEqual(try Data(contentsOf: f.store.fileURL), lockedBytes); XCTAssertEqual(f.frames.count, lockedFrames)
    }
    func testMatchingCurrentLockCASCommitsAndSharedLockIsAcknowledged() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let before = try local(f.store)
        var locked = before
        locked["lockedAtMs"] = (Date().timeIntervalSince1970 * 1000).rounded(.down)
        locked["lockWaitHours"] = 1
        locked["lockVersion"] = 1
        _ = try f.store.applyEditorDefinitionRequest(request(before: before, after: locked, intent: "lock-fields"))
        let saved = try local(f.store)
        XCTAssertTrue(WebStoreDocument.isLocked(saved))
        XCTAssertEqual((saved["lockVersion"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual((saved["lockSyncedVersion"] as? NSNumber)?.intValue, 1)
        let data = try XCTUnwrap(UserDefaults.standard.data(forKey: registryKey))
        let payload = try StorageSchemaPolicy(format: "hub.clusters", currentSchema: 3).payload(from: data)
        let cluster = try XCTUnwrap((JSONSerialization.jsonObject(with: payload) as? [[String: Any]])?.first)
        XCTAssertEqual(((cluster["sharedLock"] as? [String: Any])?["lockVersion"] as? NSNumber)?.intValue, 1)
    }
    func testDeleteCleansRuntimeAndMembershipWithoutRemovingOtherGroupState() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let before = try local(f.store)
        _ = try f.store.applyEditorDefinitionRequest(request(before: before, after: nil))
        let document = try raw(f.store)
        XCTAssertFalse((document["blockedGroups"] as? [[String: Any]] ?? []).contains { ($0["id"] as? String) == "m1" })
        for key in WebStoreDocument.perGroupMapKeys { XCTAssertNil((document[key] as? [String: Any])?["m1"], key) }
        XCTAssertEqual(((document["cbRuleState"] as? [String: Any])?["other"] as? [String: Any])?["events"] as? Int, 7)
        XCTAssertEqual(document["quickAddGroupId"] as? String, "")
        XCTAssertFalse(f.hub.linkedLocalGroupIds().contains("m1"))
    }
    func testCreateAndReorderKeepIndependentCurrentGroup() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let created = try group("new", name: "New")
        _ = try f.store.applyEditorDefinitionRequest(request(before: nil, after: created))
        let result = try f.store.applyEditorDefinitionRequest(["intent": "reorder", "changes": [], "order": ["new", "m1"], "movedId": "new"])
        XCTAssertEqual(result.compactMap { $0["id"] as? String }, ["new", "m1", "other"])
    }
    func testStagedCommitRetainsJoiningOriginsReceiptsBucketsAndSnooze() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        f.hub.setRoster(program: "edge", groups: [["id": "e1", "name": "LateOriginal"]])
        XCTAssertNil(f.hub.linkGroups(program: "chrome", groupId: "c1", targetProgram: "edge", targetGroupId: "e1"))
        f.hub.applySync(program: "edge", groupId: "e1", contribution: [
            "scopes": [["id": "site-e1", "entryID": "site", "surface": "site", "action": "block", "platform": NSNull(),
                        "sites": ["excluded.example"], "sitesExcept": true]],
            "usageMs": 5000.0, "usageResetAtMs": f.now
        ], ts: 0)
        f.hub.setRoster(program: "firefox", groups: [["id": "f1", "name": "UnacknowledgedOriginal"]])
        XCTAssertNil(f.hub.linkGroups(program: "chrome", groupId: "c1", targetProgram: "firefox", targetGroupId: "f1"))
        let minute = UsageBudget.bucketStartMs(f.now)
        f.hub.applySync(program: "chrome", groupId: "c1", contribution: [
            "usageDeltaMs": 1000.0, "usageBuckets": UsageBudget.bucketJSON([minute: 1000.0]),
            "usageTransferId": "owned-clone-receipt", "usageDeltaAnchorMs": f.now,
            "snooze": ["startsAtMs": f.now, "untilMs": f.now + 600_000, "changedAtMs": f.now], "snoozeTs": f.now
        ], ts: 0)
        f.queue.sync {}
        func registry() throws -> [String: Any] {
            let data = try XCTUnwrap(UserDefaults.standard.data(forKey: registryKey))
            let payload = try StorageSchemaPolicy(format: "hub.clusters", currentSchema: 3).payload(from: data)
            return try XCTUnwrap((JSONSerialization.jsonObject(with: payload) as? [[String: Any]])?.first)
        }
        let before = try registry()
        let ui = try local(f.store)
        _ = try f.store.applyEditorDefinitionRequest(request(before: ui, after: appsEdit(ui)))
        let after = try registry()
        // A config-bearing edit persists the staged copy, exposing omissions
        // that would be invisible when merely discarding a failed transaction.
        for field in ["id", "initiator", "members", "memberGroupIds", "contributed", "scopeOrigins", "sharedUsageMs",
                      "sharedUsageResetAtMs", "usageSeeded", "joiningUsageBaseMs", "joiningUsageDeltaMs", "joiningSeedFloorMs",
                      "joiningBucketsBase", "joiningBucketDeltas", "usageTransferReceipts", "sharedBuckets", "bucketsSeeded",
                      "sharedSnooze", "sharedSnoozeTs", "sharedSnoozeTotalMs", "snoozeCountedStartMs", "sharedLock"] {
            XCTAssertEqual(WebStoreDocument.canonicalJSON(after[field]), WebStoreDocument.canonicalJSON(before[field]), field)
        }
        XCTAssertEqual(after["groupName"] as? String, before["groupName"] as? String)
        XCTAssertEqual((after["sharedScalars"] as? [String: Any])?["name"] as? String, (before["sharedScalars"] as? [String: Any])?["name"] as? String)
        XCTAssertEqual((after["sharedScalars"] as? [String: Any])?["allowedMinutes"] as? Int, (before["sharedScalars"] as? [String: Any])?["allowedMinutes"] as? Int)
        XCTAssertGreaterThanOrEqual((after["sharedTs"] as? Double) ?? 0, (before["sharedTs"] as? Double) ?? 0)
        let savedScopes = after["sharedScopes"] as? [[String: Any]] ?? []
        XCTAssertTrue(savedScopes.contains { ($0["surface"] as? String) == "apps" && (($0["apps"] as? [[String: Any]])?.first?["id"] as? String) == "com.example.Edited" })
        XCTAssertEqual(savedScopes.filter { ($0["surface"] as? String) != "apps" }.map { WebStoreDocument.canonicalJSON($0) }, (before["sharedScopes"] as? [[String: Any]] ?? []).filter { ($0["surface"] as? String) != "apps" }.map { WebStoreDocument.canonicalJSON($0) })
        XCTAssertFalse((before["scopeOrigins"] as? [String: String] ?? [:]).isEmpty)
        XCTAssertFalse((before["usageTransferReceipts"] as? [String: Double] ?? [:]).isEmpty)
        XCTAssertFalse((before["sharedBuckets"] as? [String: Double] ?? [:]).isEmpty)
        XCTAssertNotNil(before["joiningUsageBaseMs"])
    }
    func testFutureRegistryRefusesWithoutEffects() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let ui = try local(f.store); let edit = try request(before: ui, after: appsEdit(ui))
        let original = try Data(contentsOf: f.store.fileURL); let frames = f.frames.count
        let future = try StorageSchemaPolicy(format: "hub.clusters", currentSchema: 999).wrap(Data("[]".utf8))
        UserDefaults.standard.set(future, forKey: registryKey)
        XCTAssertThrowsError(try f.store.applyEditorDefinitionRequest(edit))
        f.queue.sync {}; XCTAssertEqual(try Data(contentsOf: f.store.fileURL), original); XCTAssertEqual(f.frames.count, frames)
        XCTAssertEqual(UserDefaults.standard.data(forKey: registryKey), future)
    }
    func testMixedLegacySnapshotRefusesWholeRequestAndSettingsOnlyStillWork() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let bytes = try Data(contentsOf: f.store.fileURL)
        let frames = f.frames.count
        XCTAssertThrowsError(try f.store.mergeEditorSideEffectChanges([
            "blockedGroups": [], "globalSettings": ["sentinel": "must-not-write"],
            "usageTimersMs": ["m1": 999_999.0]
        ]))
        f.queue.sync {}
        XCTAssertEqual(try Data(contentsOf: f.store.fileURL), bytes)
        XCTAssertEqual(f.frames.count, frames)
        try f.store.mergeEditorSideEffectChanges(["globalSettings": ["sentinel": "legitimate-setting"]])
        XCTAssertEqual((try raw(f.store)["globalSettings"] as? [String: Any])?["sentinel"] as? String, "legitimate-setting")
        XCTAssertEqual((try raw(f.store)["blockedGroups"] as? [[String: Any]])?.count, 2)
    }
    func testEmptyUnsupportedRegistryStillRefusesOwnedUnlinkedEdit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-editor-future-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BlockerWebStore(shared: SharedAppGroupStore(baseDirectory: root))
        let originalGroup = try group("m1", name: "Unlinked")
        store.save(rawStore: ["blockedGroups": [originalGroup]])
        let future = try StorageSchemaPolicy(format: "hub.clusters", currentSchema: 999).wrap(Data("[]".utf8))
        UserDefaults.standard.set(future, forKey: registryKey)
        let queue = DispatchQueue(label: "NativePreciseEditorTests.empty-outbound")
        let frames = Frames()
        let hub = ConnectionHub(testOutboundQueue: queue, outboundDelivery: { frames.append($0) })
        hub.localWebStore = store
        XCTAssertTrue(hub.linkedLocalGroupIds().isEmpty)
        let bytes = try Data(contentsOf: store.fileURL)
        XCTAssertThrowsError(try store.applyEditorDefinitionRequest(request(before: originalGroup, after: appsEdit(originalGroup))))
        queue.sync {}
        XCTAssertEqual(try Data(contentsOf: store.fileURL), bytes)
        XCTAssertEqual(UserDefaults.standard.data(forKey: registryKey), future)
        XCTAssertEqual(frames.count, 0)
    }
    func testFutureCanonicalStoreRefusesOwnedAndStandaloneEditor() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let ui = try local(f.store)
        let edit = try request(before: ui, after: appsEdit(ui))
        var future = try raw(f.store)
        future["schemaVersion"] = 999
        if var metadata = future["storageMetadata"] as? [String: Any] {
            metadata["schemaVersion"] = 999; future["storageMetadata"] = metadata
        }
        let bytes = try JSONSerialization.data(withJSONObject: future, options: [.sortedKeys])
        try bytes.write(to: f.store.fileURL, options: .atomic)
        let frames = f.frames.count
        XCTAssertThrowsError(try f.store.applyEditorDefinitionRequest(edit))
        let standalone = BlockerWebStore(shared: SharedAppGroupStore(baseDirectory: f.root))
        XCTAssertThrowsError(try standalone.applyEditorDefinitionRequest(edit))
        f.queue.sync {}
        XCTAssertEqual(try Data(contentsOf: f.store.fileURL), bytes)
        XCTAssertEqual(f.frames.count, frames)
    }
    func testCanonicalJSCRefusalReasonsSurviveAndDoNotPoisonSuccessfulRequest() throws {
        do {
            _ = try GroupActionsRuntime.shared.callThrowing("applyEditorRequest", [
                [[String: Any]](), ["changes": [["id": "missing", "fields": ["set": ["name": "Nope"]]]]], "desktop"
            ], module: "CBGroupScopes")
            XCTFail("missing group must refuse")
        } catch let error as GroupStoreError { XCTAssertEqual(error, .invalidInput("group-not-found")) }
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let before = try local(f.store)
        _ = try f.store.applyEditorDefinitionRequest(request(before: before, after: appsEdit(before)))
        f.hub.applySync(program: "chrome", groupId: "c1", contribution: [
            "scalars": ["name": "NewLock", "allowedMinutes": 24, "enabled": false],
            "lock": ["lockVersion": 1, "lockedAtMs": f.now, "lockWaitHours": 1], "lockBase": 0
        ], ts: (Date().timeIntervalSince1970 * 1000).rounded(.down))
        do {
            _ = try f.store.applyEditorDefinitionRequest(request(before: before, after: appsEdit(before)))
            XCTFail("stale lock must refuse")
        } catch let error as GroupStoreError { XCTAssertEqual(error, .invalidInput("group-lock-changed; retry edit")) }
    }
    func testEditorReplyPreservesAdmissionReasonsAndCocoaSaveText() {
        for reason in ["group-lock-changed; retry edit", "cluster-storage-unavailable", "precise-editor-request-required"] {
            XCTAssertEqual(BlockerWebView.Coordinator.editorFailureMessage(GroupStoreError.invalidInput(reason)), reason)
        }
        let saveError = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError,
                                userInfo: [NSLocalizedDescriptionKey: "The file could not be saved."])
        XCTAssertEqual(BlockerWebView.Coordinator.editorFailureMessage(saveError), saveError.localizedDescription)
    }
    func testNativeEditorFrameMustBeExactOwnedMainFrame() {
        XCTAssertTrue(BlockerWebView.Coordinator.isTrustedEditorFrame(isMainFrame: true, url: WebAssetSchemeHandler.indexURL))
        for url in [URL(string: "cbasset://vault/popup.html"), URL(string: "cbasset://app/other.html"), URL(string: "https://app/popup.html"), URL(string: "cbasset://app/popup.html?x=1"), nil] {
            XCTAssertFalse(BlockerWebView.Coordinator.isTrustedEditorFrame(isMainFrame: true, url: url))
        }
        XCTAssertFalse(BlockerWebView.Coordinator.isTrustedEditorFrame(isMainFrame: false, url: WebAssetSchemeHandler.indexURL))
    }
}
