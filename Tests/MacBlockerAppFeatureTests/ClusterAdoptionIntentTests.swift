import XCTest
@testable import MacBlockerAppFeature
import MacBlockerCore
import MacBlockerWebUI

/// Native linked definitions use real canonical store writes, no production hooks.
/// The first control should distinguish the current echo bug. The stale-capture
/// control prevents a naive adoption marker from introducing a new overwrite.
final class ClusterAdoptionIntentTests: XCTestCase {
    private struct Fixture {
        let hub: ConnectionHub
        let store: BlockerWebStore
        let native: GroupStore
        let root: URL
        let now: Double
    }
    private let registryKey = "ConnectionHub.clusters.v2"
    private var previousRegistry: Any?
    private var registryWasBackedUp = false
    override func setUpWithError() throws {
        try super.setUpWithError()
        // Integration runs use an isolated XCTest process domain. Reject any
        // accidental real-app host before backing up its registry key.
        guard Bundle.main.bundleIdentifier?.hasPrefix("com.adamancia.vault.") != true else {
            throw NSError(domain: "AdoptionFixture", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "tests must not use a real Vault preference domain"])
        }
        previousRegistry = UserDefaults.standard.object(forKey: registryKey)
        registryWasBackedUp = true
    }
    override func tearDownWithError() throws {
        if registryWasBackedUp {
            if let previousRegistry { UserDefaults.standard.set(previousRegistry, forKey: registryKey) }
            else { UserDefaults.standard.removeObject(forKey: registryKey) }
        }
        if registryWasBackedUp {
            let actual = UserDefaults.standard.object(forKey: registryKey)
            XCTAssertTrue(NSDictionary(dictionary: ["value": actual ?? NSNull()]).isEqual(to: ["value": previousRegistry ?? NSNull()]), "exact prior test-domain registry restored")
            XCTAssertTrue(UserDefaults.standard.synchronize(), "flush own test-domain preference restoration")
        }
        try super.tearDownWithError()
    }
    private let apps: [[String: Any]] = [["id": "apps-1", "surface": "apps", "platform": NSNull(), "action": "block", "apps": [["id": "com.example.Dummy"]], "appsExcept": false]]
    private let sites: [[String: Any]] = [["id": "site-1", "surface": "site", "platform": NSNull(), "action": "block", "sites": ["example.com"], "sitesExcept": false]]

    @MainActor
    func testProductionTickAndEditorAdoptThroughTheHubOwnedStore() {
        let previousOverlay = GroupStore.sharedOverlay
        let previousSnoozePress = VaultMCPTools.snoozePress
        let previousRunRule = VaultMCPTools.runRule
        defer {
            GroupStore.sharedOverlay = previousOverlay
            VaultMCPTools.snoozePress = previousSnoozePress
            VaultMCPTools.runRule = previousRunRule
        }
        // Constructing the process-wide bridge does not start its timer, load
        // the canonical file, or show a panel. It verifies real owner wiring:
        // the separate tick adoption boundary must not use an unowned store.
        let bridge = MacEnforcementBridge.shared
        XCTAssertTrue(ConnectionHub.shared.localWebStore === bridge.webStore)
    }

    private func raw(_ store: BlockerWebStore) throws -> [String: Any] {
        let text = try XCTUnwrap(store.loadRawJSON())
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("adoption-intent-\(UUID().uuidString)")
        let shared = SharedAppGroupStore(baseDirectory: root)
        let store = BlockerWebStore(shared: shared)
        let now = (Date().timeIntervalSince1970 * 1000).rounded(.down)
        store.save(rawStore: ["blockedGroups": [["id": "m1", "name": "NativeOriginal", "enabled": false,
            "mode": "after-minutes", "allowedMinutes": 40, "resetIntervalHours": 24, "scopes": apps],
            ["id": "other", "name": "UnlinkedSentinel", "enabled": false]], "globalSettings": ["sentinel": 7]])
        let hub = ConnectionHub(); hub.hostingLocalHub = true; hub.localWebStore = store
        hub.setRoster(program: "macapp", groups: [["id": "m1", "name": "NativeOriginal"], ["id": "other", "name": "UnlinkedSentinel"]])
        hub.setRoster(program: "chrome", groups: [["id": "c1", "name": "Browser20"]])
        XCTAssertNil(hub.linkGroups(program: "chrome", groupId: "c1", targetProgram: "macapp", targetGroupId: "m1"))
        hub.contributeLocalDefinitions(document: try raw(store), nowMs: now)
        browser(hub, name: "Browser20", allowance: 20, ts: 0)
        return Fixture(hub: hub, store: store, native: GroupStore(shared: shared), root: root, now: now)
    }
    private func browser(_ hub: ConnectionHub, name: String, allowance: Int, ts: Double) {
        hub.applySync(program: "chrome", groupId: "c1", contribution: ["scalars": ["name": name, "enabled": false,
            "mode": "after-minutes", "allowedMinutes": allowance, "resetIntervalHours": 24], "scopes": sites], ts: ts)
    }
    private func group(_ hub: ConnectionHub, store: BlockerWebStore) throws -> [String: Any] {
        let overlaid = hub.overlayShared(onto: try raw(store))
        return try XCTUnwrap((overlaid["blockedGroups"] as? [[String: Any]])?.first { ($0["id"] as? String) == "m1" })
    }
    private func expect(_ f: Fixture, name: String, allowance: Int, file: StaticString = #filePath, line: UInt = #line) throws {
        let g = try group(f.hub, store: f.store)
        XCTAssertEqual(g["name"] as? String, name, file: file, line: line)
        XCTAssertEqual((g["allowedMinutes"] as? NSNumber)?.intValue, allowance, file: file, line: line)
    }

    func testOldSharedAdoptionIsNotFreshNativeIntentWhenBrowserEditsBeforeNextTick() throws {
        let previousOverlay = GroupStore.sharedOverlay
        let f = try fixture()
        defer { GroupStore.sharedOverlay = previousOverlay; try? FileManager.default.removeItem(at: f.root) }
        GroupStore.sharedOverlay = { f.hub.overlayShared(onto: $0) }
        XCTAssertTrue(f.store.adoptShared()) // persisted Browser20, not a native UI/MCP edit
        browser(f.hub, name: "Browser24", allowance: 24, ts: f.now + 100)
        f.hub.contributeLocalDefinitions(document: try raw(f.store), nowMs: f.now + 200)
        try expect(f, name: "Browser24", allowance: 24)
    }

    func testTickSnapshotCapturedBeforeNewerAdoptionCannotBecomeAnEditAfterIt() throws {
        let previousOverlay = GroupStore.sharedOverlay
        let f = try fixture()
        defer { GroupStore.sharedOverlay = previousOverlay; try? FileManager.default.removeItem(at: f.root) }
        GroupStore.sharedOverlay = { f.hub.overlayShared(onto: $0) }
        XCTAssertTrue(f.store.adoptShared())
        let captured20 = try raw(f.store)
        f.hub.contributeLocalDefinitions(document: captured20, nowMs: f.now + 50)
        browser(f.hub, name: "Browser24", allowance: 24, ts: f.now + 100)
        XCTAssertTrue(f.store.adoptShared())
        // Existing API deliberately models a load-before-write, contribute-after-write boundary.
        f.hub.contributeLocalDefinitions(document: captured20, nowMs: f.now + 200)
        try expect(f, name: "Browser24", allowance: 24)
    }

    func testGenuineNativeMCPMutationStillPublishesAfterSharedAdoption() throws {
        let previousOverlay = GroupStore.sharedOverlay
        let f = try fixture()
        defer { GroupStore.sharedOverlay = previousOverlay; try? FileManager.default.removeItem(at: f.root) }
        GroupStore.sharedOverlay = { f.hub.overlayShared(onto: $0) }
        XCTAssertTrue(f.store.adoptShared())
        f.hub.contributeLocalDefinitions(document: try raw(f.store), nowMs: f.now + 50)
        try f.native.mutate { try $0.setGroup(id: "m1", patch: ["name": "ActualNative30", "allowedMinutes": 30]) }
        f.hub.contributeLocalDefinitions(document: try raw(f.store), nowMs: f.now + 200)
        try expect(f, name: "ActualNative30", allowance: 30)
        let unchanged = try XCTUnwrap((try raw(f.store)["blockedGroups"] as? [[String: Any]])?.first { ($0["id"] as? String) == "other" })
        XCTAssertEqual(unchanged["name"] as? String, "UnlinkedSentinel")
    }

    func testNativeAppsEnableOrderAndDeleteRemainRealMutations() throws {
        let previousOverlay = GroupStore.sharedOverlay
        let f = try fixture()
        defer { GroupStore.sharedOverlay = previousOverlay; try? FileManager.default.removeItem(at: f.root) }
        GroupStore.sharedOverlay = { f.hub.overlayShared(onto: $0) }
        XCTAssertTrue(f.store.adoptShared())
        f.hub.contributeLocalDefinitions(document: try raw(f.store), nowMs: f.now + 50)
        try f.native.mutate {
            try $0.addApplication(id: "m1", bundleID: "com.example.ActualNewTarget", name: "Actual native addition")
            try $0.setGroup(id: "m1", patch: ["enabled": true])
            try $0.moveGroup(id: "other", to: 0)
        }
        f.hub.contributeLocalDefinitions(document: try raw(f.store), nowMs: f.now + 200)
        let g = try group(f.hub, store: f.store)
        XCTAssertEqual(g["enabled"] as? Bool, true)
        XCTAssertTrue(WebStoreDocument.apps(of: g).contains { ($0["id"] as? String) == "com.example.ActualNewTarget" })
        XCTAssertEqual((try raw(f.store)["blockedGroups"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, ["other", "m1"])
        try f.native.mutate { try $0.deleteGroup(id: "m1") }
        f.hub.contributeLocalDefinitions(document: try raw(f.store), nowMs: f.now + 300)
        XCTAssertEqual(f.hub.activeClusterCount(), 0)
        XCTAssertEqual((try raw(f.store)["blockedGroups"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, ["other"])
    }
    func testFailedAtomicAdoptionDoesNotAcknowledgeAnUnwrittenDefinition() throws {
        let previousOverlay = GroupStore.sharedOverlay
        let f = try fixture()
        defer {
            GroupStore.sharedOverlay = previousOverlay
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.root.path)
            try? FileManager.default.removeItem(at: f.root)
        }
        GroupStore.sharedOverlay = { f.hub.overlayShared(onto: $0) }
        let before = try Data(contentsOf: f.store.fileURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: f.root.path)
        XCTAssertFalse(f.store.adoptShared(), "a refused atomic write is not a persisted adoption")
        XCTAssertEqual(try Data(contentsOf: f.store.fileURL), before)
        browser(f.hub, name: "Browser24", allowance: 24, ts: f.now + 100)
        f.hub.contributeLocalDefinitions(document: try raw(f.store), nowMs: f.now + 200)
        try expect(f, name: "Browser24", allowance: 24)
    }

    func testRemoteSyncProgressesWhileCanonicalStoreLockIsHeld() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let fileHeld = DispatchSemaphore(value: 0)
        let remoteDone = DispatchSemaphore(value: 0)
        let writerDone = expectation(description: "file-lock then hub read completes")
        let remoteFinished = expectation(description: "remote sync has no hub-to-file-lock inversion")
        DispatchQueue(label: "adoption-intent-owned-file").async {
            do {
                try f.store.withLockedDocument(notify: false) { document, _ in
                    fileHeld.signal()
                    // Timeout must release the file lock instead of entering a known
                    // deadlock; the assertion below records failure without leaking jobs.
                    let progressed = remoteDone.wait(timeout: .now() + 2) == .success
                    if progressed, let document { _ = f.hub.overlayShared(onto: document) }
                    XCTAssertTrue(progressed, "remote applySync must not hold hub lock while waiting for file lock")
                }
            } catch { XCTFail("unexpected store read error: \(error)") }
            writerDone.fulfill()
        }
        DispatchQueue(label: "adoption-intent-owned-remote").async {
            guard fileHeld.wait(timeout: .now() + 2) == .success else {
                XCTFail("owned file barrier did not begin"); remoteDone.signal(); remoteFinished.fulfill(); return
            }
            self.browser(f.hub, name: "Browser24", allowance: 24, ts: f.now + 100)
            remoteDone.signal(); remoteFinished.fulfill()
        }
        wait(for: [writerDone, remoteFinished], timeout: 5)
        try expect(f, name: "Browser24", allowance: 24)
    }


    func testEnabledAndAppsOnlyMutationUsesLatestSharedScalarsInsteadOfLaggingFile() throws {
        let previousOverlay = GroupStore.sharedOverlay
        let f = try fixture()
        defer { GroupStore.sharedOverlay = previousOverlay; try? FileManager.default.removeItem(at: f.root) }
        GroupStore.sharedOverlay = { f.hub.overlayShared(onto: $0) }
        XCTAssertTrue(f.store.adoptShared())
        f.hub.contributeLocalDefinitions(document: try raw(f.store), nowMs: f.now + 50)
        browser(f.hub, name: "Browser24", allowance: 24, ts: f.now + 100)
        // A real field-surgical mutation touches no name/allowance field. It
        // must retain the newest shared values rather than republish raw20.
        try f.native.mutate {
            try $0.setGroup(id: "m1", patch: ["enabled": true])
            try $0.addApplication(id: "m1", bundleID: "com.example.NewAppsOnly", name: "Apps-only change")
        }
        f.hub.contributeLocalDefinitions(document: try raw(f.store), nowMs: f.now + 200)
        try expect(f, name: "Browser24", allowance: 24)
        let g = try group(f.hub, store: f.store)
        XCTAssertEqual(g["enabled"] as? Bool, true)
        XCTAssertTrue(WebStoreDocument.apps(of: g).contains { ($0["id"] as? String) == "com.example.NewAppsOnly" })
    }

    private func policyTimestamp(_ hub: ConnectionHub) throws -> Double {
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(hub.clustersJSON().utf8)) as? [String: Any])
        let cluster = try XCTUnwrap((response["clusters"] as? [[String: Any]])?.first)
        let shared = try XCTUnwrap(cluster["shared"] as? [String: Any])
        return try XCTUnwrap((shared["ts"] as? NSNumber)?.doubleValue)
    }

    func testFutureSchemaRefusesAdoptionAndContributionWithoutTimestampAdvance() throws {
        let previousOverlay = GroupStore.sharedOverlay
        let f = try fixture()
        defer { GroupStore.sharedOverlay = previousOverlay; try? FileManager.default.removeItem(at: f.root) }
        GroupStore.sharedOverlay = { f.hub.overlayShared(onto: $0) }
        let supported = try raw(f.store)
        var future = supported
        var metadata = future["storageMetadata"] as? [String: Any] ?? [:]
        metadata["schemaVersion"] = 999; future["storageMetadata"] = metadata
        let bytes = try JSONSerialization.data(withJSONObject: future, options: [.sortedKeys])
        try bytes.write(to: f.store.fileURL, options: [.atomic])
        let before = try policyTimestamp(f.hub)
        XCTAssertFalse(f.store.adoptShared())
        XCTAssertEqual(try Data(contentsOf: f.store.fileURL), bytes)
        f.hub.contributeLocalDefinitions(document: future, nowMs: f.now + 200)
        XCTAssertEqual(try policyTimestamp(f.hub), before)
        XCTAssertEqual(try Data(contentsOf: f.store.fileURL), bytes)
        // Return to the earlier supported original document through the normal
        // fixture file boundary. A refused future adoption must not have marked
        // its never-persisted overlay as local intent.
        try JSONSerialization.data(withJSONObject: supported, options: [.sortedKeys]).write(to: f.store.fileURL, options: [.atomic])
        browser(f.hub, name: "Browser24", allowance: 24, ts: f.now + 300)
        f.hub.contributeLocalDefinitions(document: try raw(f.store), nowMs: f.now + 400)
        try expect(f, name: "Browser24", allowance: 24)
    }

    func testUnchangedAdoptionAndRepeatedTickDoNotAdvancePolicyTimestamp() throws {
        let previousOverlay = GroupStore.sharedOverlay
        let f = try fixture()
        defer { GroupStore.sharedOverlay = previousOverlay; try? FileManager.default.removeItem(at: f.root) }
        GroupStore.sharedOverlay = { f.hub.overlayShared(onto: $0) }
        let before = try policyTimestamp(f.hub)
        XCTAssertTrue(f.store.adoptShared())
        for tick in 1...3 {
            f.hub.contributeLocalDefinitions(document: try raw(f.store), nowMs: f.now + Double(tick * 100))
            XCTAssertFalse(f.store.adoptShared())
        }
        XCTAssertEqual(try policyTimestamp(f.hub), before)
    }


    func testSequentialNativeMutationsBeforeNextTickRetainEarlierAllowanceIntent() throws {
        let previousOverlay = GroupStore.sharedOverlay
        let f = try fixture()
        defer { GroupStore.sharedOverlay = previousOverlay; try? FileManager.default.removeItem(at: f.root) }
        GroupStore.sharedOverlay = { f.hub.overlayShared(onto: $0) }
        XCTAssertTrue(f.store.adoptShared())
        f.hub.contributeLocalDefinitions(document: try raw(f.store), nowMs: f.now + 50)
        try f.native.mutate { try $0.setGroup(id: "m1", patch: ["allowedMinutes": 30]) }
        try f.native.mutate {
            try $0.setGroup(id: "m1", patch: ["enabled": true])
            try $0.addApplication(id: "m1", bundleID: "com.example.SequentialApps", name: "Second edit")
        }
        f.hub.contributeLocalDefinitions(document: try raw(f.store), nowMs: f.now + 200)
        try expect(f, name: "Browser20", allowance: 30)
        let g = try group(f.hub, store: f.store)
        XCTAssertEqual(g["enabled"] as? Bool, true)
        XCTAssertTrue(WebStoreDocument.apps(of: g).contains { ($0["id"] as? String) == "com.example.SequentialApps" })
    }

    func testNativeMutationBetweenContributionAndAdoptionIsNotDiscarded() throws {
        let previousOverlay = GroupStore.sharedOverlay
        let f = try fixture()
        defer { GroupStore.sharedOverlay = previousOverlay; try? FileManager.default.removeItem(at: f.root) }
        GroupStore.sharedOverlay = { f.hub.overlayShared(onto: $0) }
        XCTAssertTrue(f.store.adoptShared())
        f.hub.contributeLocalDefinitions(document: try raw(f.store), nowMs: f.now + 50)
        // Models the currently separate calls: a normal successful write can
        // occur after tick contribution and before shared adoption.
        try f.native.mutate { try $0.setGroup(id: "m1", patch: ["allowedMinutes": 30]) }
        f.store.adoptShared()
        let persisted = try XCTUnwrap((try raw(f.store)["blockedGroups"] as? [[String: Any]])?.first { ($0["id"] as? String) == "m1" })
        XCTAssertEqual((persisted["allowedMinutes"] as? NSNumber)?.intValue, 30)
        f.hub.contributeLocalDefinitions(document: try raw(f.store), nowMs: f.now + 200)
        try expect(f, name: "Browser20", allowance: 30)
    }


    func testReassigningStoreCannotReconcileTheNewStoreThroughTheOldCallback() throws {
        let previousOverlay = GroupStore.sharedOverlay
        let f = try fixture()
        defer { GroupStore.sharedOverlay = previousOverlay; try? FileManager.default.removeItem(at: f.root) }
        GroupStore.sharedOverlay = { $0 } // no generic shared overlay for old store
        let otherShared = SharedAppGroupStore(baseDirectory: f.root.appendingPathComponent("replacement"))
        let replacement = BlockerWebStore(shared: otherShared)
        replacement.save(rawStore: ["blockedGroups": [["id": "replacement", "name": "Replacement", "enabled": false]]])
        let before = try Data(contentsOf: replacement.fileURL)
        f.hub.localWebStore = replacement
        XCTAssertFalse(f.store.adoptShared())
        XCTAssertEqual(try Data(contentsOf: replacement.fileURL), before)
        XCTAssertEqual(f.hub.activeClusterCount(), 1, "old store callback must not publish replacement roster")
    }

    func testFailedNativeMutationDoesNotPublishOrAcknowledgeChanges() throws {
        let previousOverlay = GroupStore.sharedOverlay
        let f = try fixture()
        defer { GroupStore.sharedOverlay = previousOverlay; try? FileManager.default.removeItem(at: f.root) }
        GroupStore.sharedOverlay = { f.hub.overlayShared(onto: $0) }
        f.store.adoptShared()
        let before = try Data(contentsOf: f.store.fileURL)
        XCTAssertThrowsError(try f.native.mutate { try $0.setGroup(id: "missing", patch: ["allowedMinutes": 30]) })
        XCTAssertEqual(try Data(contentsOf: f.store.fileURL), before)
        browser(f.hub, name: "Browser24", allowance: 24, ts: f.now + 100)
        f.hub.contributeLocalDefinitions(document: try raw(f.store), nowMs: f.now + 200)
        try expect(f, name: "Browser24", allowance: 24)
    }

    func testMalformedCanonicalGroupsCannotRemoveRosterOrPublishFallbackDocument() throws {
        let previousOverlay = GroupStore.sharedOverlay
        let f = try fixture()
        defer { GroupStore.sharedOverlay = previousOverlay; try? FileManager.default.removeItem(at: f.root) }
        GroupStore.sharedOverlay = { f.hub.overlayShared(onto: $0) }
        let supported = try raw(f.store)
        var malformed = supported; malformed["blockedGroups"] = "not-an-array"
        let bytes = try JSONSerialization.data(withJSONObject: malformed, options: [.sortedKeys])
        try bytes.write(to: f.store.fileURL, options: [.atomic])
        let before = try policyTimestamp(f.hub)
        XCTAssertFalse(f.store.adoptShared())
        f.hub.contributeLocalDefinitions(document: supported, nowMs: f.now + 200)
        XCTAssertEqual(f.hub.activeClusterCount(), 1)
        XCTAssertEqual(try policyTimestamp(f.hub), before)
        XCTAssertEqual(try Data(contentsOf: f.store.fileURL), bytes)
        try JSONSerialization.data(withJSONObject: supported, options: [.sortedKeys]).write(to: f.store.fileURL, options: [.atomic])
        f.hub.contributeLocalDefinitions(document: supported, nowMs: f.now + 300)
        try expect(f, name: "Browser20", allowance: 20)
    }

    func testRestartFirstSightDoesNotPublishStaleStoredDefinitionAsNewIntent() throws {
        let previousOverlay = GroupStore.sharedOverlay
        let f = try fixture()
        defer { GroupStore.sharedOverlay = previousOverlay; try? FileManager.default.removeItem(at: f.root) }
        f.store.adoptShared()
        browser(f.hub, name: "Browser24", allowance: 24, ts: f.now + 100)
        let restored = ConnectionHub(); restored.hostingLocalHub = true; restored.restoreClustersLocked()
        restored.localWebStore = f.store
        GroupStore.sharedOverlay = { restored.overlayShared(onto: $0) }
        restored.contributeLocalDefinitions(document: try raw(f.store), nowMs: f.now + 200)
        let g = try group(restored, store: f.store)
        XCTAssertEqual(g["name"] as? String, "Browser24")
        XCTAssertEqual((g["allowedMinutes"] as? NSNumber)?.intValue, 24)
    }

    func testExplicitNativeEditAfterOwnershipBeforeFirstReconcileSurvivesRestart() throws {
        let previousOverlay = GroupStore.sharedOverlay
        let f = try fixture()
        defer { GroupStore.sharedOverlay = previousOverlay; try? FileManager.default.removeItem(at: f.root) }
        f.store.adoptShared()
        browser(f.hub, name: "Browser24", allowance: 24, ts: f.now + 100)
        let restored = ConnectionHub(); restored.hostingLocalHub = true; restored.restoreClustersLocked()
        restored.localWebStore = f.store // observe the untouched stale20, without publishing/adopting it
        GroupStore.sharedOverlay = { restored.overlayShared(onto: $0) }
        try f.native.mutate { try $0.setGroup(id: "m1", patch: ["allowedMinutes": 30]) }
        restored.contributeLocalDefinitions(document: try raw(f.store), nowMs: f.now + 200)
        let g = try group(restored, store: f.store)
        XCTAssertEqual(g["name"] as? String, "Browser24")
        XCTAssertEqual((g["allowedMinutes"] as? NSNumber)?.intValue, 30)
    }

    func testSameStoreAssignmentDoesNotErasePendingNativeIntent() throws {
        let previousOverlay = GroupStore.sharedOverlay
        let f = try fixture()
        defer { GroupStore.sharedOverlay = previousOverlay; try? FileManager.default.removeItem(at: f.root) }
        GroupStore.sharedOverlay = { f.hub.overlayShared(onto: $0) }
        f.store.adoptShared()
        try f.native.mutate { try $0.setGroup(id: "m1", patch: ["allowedMinutes": 30]) }
        f.hub.localWebStore = f.store
        f.hub.contributeLocalDefinitions(document: try raw(f.store), nowMs: f.now + 200)
        try expect(f, name: "Browser20", allowance: 30)
    }

    func testMalformedNestedScopesPreserveCanonicalBytesAndHubState() throws {
        let previousOverlay = GroupStore.sharedOverlay
        let f = try fixture()
        defer { GroupStore.sharedOverlay = previousOverlay; try? FileManager.default.removeItem(at: f.root) }
        GroupStore.sharedOverlay = { f.hub.overlayShared(onto: $0) }
        f.store.adoptShared()
        let supported = try raw(f.store)
        let beforeHub = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(f.hub.clustersJSON().utf8)) as? [String: Any])
        for malformed in ["not-an-array" as Any, NSNull(), [42] as Any, [["surface": "apps"], "not-a-line"] as [Any]] {
            var document = supported
            var groups = try XCTUnwrap(document["blockedGroups"] as? [[String: Any]])
            groups[0]["scopes"] = malformed; document["blockedGroups"] = groups
            let bytes = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
            try bytes.write(to: f.store.fileURL, options: [.atomic])
            XCTAssertFalse(f.store.adoptShared())
            f.hub.contributeLocalDefinitions(document: supported, nowMs: f.now + 200)
            XCTAssertEqual(try Data(contentsOf: f.store.fileURL), bytes)
            let afterHub = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(f.hub.clustersJSON().utf8)) as? [String: Any])
            XCTAssertTrue(NSDictionary(dictionary: afterHub).isEqual(to: beforeHub), "every Hub value and array order remains unchanged")
        }
        try JSONSerialization.data(withJSONObject: supported, options: [.sortedKeys]).write(to: f.store.fileURL, options: [.atomic])
        browser(f.hub, name: "Browser24", allowance: 24, ts: f.now + 300)
        f.hub.contributeLocalDefinitions(document: supported, nowMs: f.now + 400)
        try expect(f, name: "Browser24", allowance: 24)
    }

    private func establishUnlockedVersionThree(_ f: Fixture) throws {
        let unit = try XCTUnwrap(GroupActionsRuntime.shared.call("normalizeLock", [["lockVersion": 3]]) as? [String: Any])
        f.hub.applySync(program: "chrome", groupId: "c1", contribution: ["scalars": ["name": "Browser20", "enabled": false,
            "mode": "after-minutes", "allowedMinutes": 20, "resetIntervalHours": 24], "lock": unit, "lockBase": 0], ts: f.now + 10)
        f.store.adoptShared()
        XCTAssertEqual((try group(f.hub, store: f.store)["lockVersion"] as? NSNumber)?.intValue, 3)
    }

    func testPendingNativeLockUsesItsMatchingCASBaseDuringAdoption() throws {
        let previousOverlay = GroupStore.sharedOverlay
        let f = try fixture()
        defer { GroupStore.sharedOverlay = previousOverlay; try? FileManager.default.removeItem(at: f.root) }
        GroupStore.sharedOverlay = { f.hub.overlayShared(onto: $0) }
        try establishUnlockedVersionThree(f)
        try f.native.mutate {
            XCTAssertEqual(try $0.lockGroup(id: "m1", waitHours: 1, now: Date(timeIntervalSince1970: f.now / 1_000)), .done)
        }
        f.store.adoptShared()
        let g = try group(f.hub, store: f.store)
        XCTAssertEqual((g["lockVersion"] as? NSNumber)?.intValue, 4)
        XCTAssertEqual((g["lockSyncedVersion"] as? NSNumber)?.intValue, 4)
        XCTAssertTrue(WebStoreDocument.isLocked(g))
        XCTAssertEqual((g["lockWaitHours"] as? NSNumber)?.intValue, 1)
    }

    func testPendingNativeLockCannotReplacePeerVersionAdvancedPastItsCASBase() throws {
        let previousOverlay = GroupStore.sharedOverlay
        let f = try fixture()
        defer { GroupStore.sharedOverlay = previousOverlay; try? FileManager.default.removeItem(at: f.root) }
        GroupStore.sharedOverlay = { f.hub.overlayShared(onto: $0) }
        try establishUnlockedVersionThree(f)
        try f.native.mutate {
            XCTAssertEqual(try $0.lockGroup(id: "m1", waitHours: 1, now: Date(timeIntervalSince1970: f.now / 1_000)), .done)
        }
        let unit = try XCTUnwrap(GroupActionsRuntime.shared.call("normalizeLock", [["lockVersion": 5]]) as? [String: Any])
        f.hub.applySync(program: "chrome", groupId: "c1", contribution: ["scalars": ["name": "Browser24", "enabled": false,
            "mode": "after-minutes", "allowedMinutes": 24, "resetIntervalHours": 24], "lock": unit, "lockBase": 3], ts: f.now + 100)
        f.store.adoptShared()
        let g = try group(f.hub, store: f.store)
        XCTAssertEqual((g["lockVersion"] as? NSNumber)?.intValue, 5)
        XCTAssertEqual((g["lockSyncedVersion"] as? NSNumber)?.intValue, 5)
        XCTAssertFalse(WebStoreDocument.isLocked(g))
        try expect(f, name: "Browser24", allowance: 24)
    }

    func testNativeExplicitClearKeepsNewRemoteScalarsAndUnknownStoredFields() throws {
        let previousOverlay = GroupStore.sharedOverlay
        let f = try fixture()
        defer { GroupStore.sharedOverlay = previousOverlay; try? FileManager.default.removeItem(at: f.root) }
        GroupStore.sharedOverlay = { f.hub.overlayShared(onto: $0) }
        f.store.adoptShared()
        var document = try raw(f.store)
        var groups = try XCTUnwrap(document["blockedGroups"] as? [[String: Any]])
        groups[0]["localUnknown"] = ["preserved": 7]
        document["blockedGroups"] = groups; document["unknownRoot"] = "preserved"
        f.store.save(rawStore: document)
        browser(f.hub, name: "Browser24", allowance: 24, ts: f.now + 100)
        try f.native.mutate { try $0.removeApplication(id: "m1", bundleID: "com.example.Dummy") }
        f.hub.contributeLocalDefinitions(document: try raw(f.store), nowMs: f.now + 200)
        try expect(f, name: "Browser24", allowance: 24)
        let saved = try raw(f.store)
        let g = try XCTUnwrap((saved["blockedGroups"] as? [[String: Any]])?.first { ($0["id"] as? String) == "m1" })
        XCTAssertTrue(WebStoreDocument.apps(of: g).isEmpty)
        XCTAssertEqual(g["localUnknown"] as? [String: Int], ["preserved": 7])
        XCTAssertEqual(saved["unknownRoot"] as? String, "preserved")
    }

}
