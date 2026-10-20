#if os(macOS)
import Foundation
import Network
import XCTest
import MacBlockerCore
import MacBlockerWebUI
import VaultClassifierBridge
@testable import MacBlockerAppFeature

final class BrowserIdentityRuntimeTests: XCTestCase {
    private var suites: [String] = []
    private var connections: [NWConnection] = []
    override func tearDown() {
        for connection in connections { connection.cancel() }
        for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
        connections = []; suites = []
        super.tearDown()
    }

    private final class Frames {
        let queue = DispatchQueue(label: "Agentic.IdentityRuntime.Frames")
        var values: [[String: Any]] = []
        func append(_ data: Data) { values.append((try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]) }
        func latestCluster() -> [String: Any]? {
            queue.sync {
                values.reversed().compactMap { frame in
                    (frame["cluster"] as? [String: Any]) ?? (frame["clusters"] as? [[String: Any]])?.first
                }.first
            }
        }
        func status() throws -> [String: Any] {
            try XCTUnwrap((latestCluster()?["shared"] as? [String: Any])?["browserIdentityStatus"] as? [String: Any])
        }
        func all() -> [[String: Any]] { queue.sync { values } }
        func latestRequest() throws -> [String: Any] { try XCTUnwrap(all().last { $0["kind"] as? String == "browser-request" }) }
    }

    private func hub(narrow: Bool = false) -> (ConnectionHub, Frames, UserDefaults) {
        let name = "Agentic.IdentityRuntime." + UUID().uuidString
        suites.append(name)
        let defaults = UserDefaults(suiteName: name)!
        let frames = Frames()
        let hub = ConnectionHub(testOutboundQueue: frames.queue, registryDefaults: defaults, browserIdentityBudgetPredicate: { scalars, scopes, _ in
            if narrow { return BrowserIdentityBudgetPolicy.affects(scalars, scopes: scopes, browserBundleIDs: ["com.google.chrome"]) }
            return (scalars["mode"] as? String) == "after-minutes" && (scalars["groupType"] as? String) != "custom"
                && scopes.contains { ($0["surface"] as? String) == "apps" && (($0["appsExcept"] as? Bool) == true
                    || (($0["apps"] as? [[String: Any]]) ?? []).contains { ($0["id"] as? String) == "com.google.Chrome" }) }
        }, outboundDelivery: { frames.append($0) })
        return (hub, frames, defaults)
    }

    private func linked(_ hub: ConnectionHub, browserContributed: Bool = true, nativeEnabled: Bool = true,
                        apps: [[String: Any]] = [["id": "com.google.Chrome"]], custom: Bool = false) throws {
        hub.setRoster(program: "macapp", groups: [["id": "m", "name": "Focus"]])
        hub.setRoster(program: "chrome", groups: [["id": "b", "name": "Focus"]])
        XCTAssertNil(hub.linkGroups(program: "macapp", groupId: "m", targetProgram: "chrome", targetGroupId: "b"))
        hub.applySync(program: "macapp", groupId: "m", contribution: [
            "scalars": ["groupType": custom ? "custom" : "site", "mode": "after-minutes", "enabled": nativeEnabled, "allowedMinutes": 30],
            "scopes": [["surface": "apps", "apps": apps]], "usageMs": 5_000.0,
            "usageResetAtMs": (Date().timeIntervalSince1970 * 1000).rounded(.down)
        ], ts: 0)
        if browserContributed {
            hub.applySync(program: "chrome", groupId: "b", contribution: ["scopes": [["surface": "site", "sites": ["example.com"]]]], ts: 0)
        }
    }

    private func peer(_ hub: ConnectionHub, program: String = "chrome", identity: Bool = false) throws -> NWConnection {
        let connection = NWConnection(host: "127.0.0.1", port: 18787, using: .tcp)
        connections.append(connection)
        hub.registerPendingPeer(connection, challenge: String(repeating: "a", count: 43))
        let appID = ["chrome": "com.google.chrome", "edge": "com.microsoft.edgemac", "safari": "com.apple.safari"][program] ?? "com.example.browser"
        let app = identity ? try XCTUnwrap(BrowserApplicationIdentity(kind: "mac-bundle-id", value: appID)) : nil
        XCTAssertNil(hub.admitAuthenticatedPeer(connection, program: program, browserIdentity: app))
        return connection
    }

    private func sync(_ hub: ConnectionHub, _ connection: NWConnection, _ fields: [String: Any], generation: String? = nil, groupID: String = "b") throws {
        var frame = fields
        frame["kind"] = "group-sync"; frame["groupId"] = groupID
        if let generation { frame["browserIdentitySnapshotApplied"] = ["generation": generation] }
        hub.handleIncoming(connection, key: ObjectIdentifier(connection), data: try JSONSerialization.data(withJSONObject: frame))
    }

    private func canonical(_ hub: ConnectionHub) throws -> [String: Any] {
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(hub.clustersJSON().utf8)) as? [String: Any])
        let cluster = try XCTUnwrap((object["clusters"] as? [[String: Any]])?.first)
        return try XCTUnwrap(cluster["shared"] as? [String: Any])
    }

    private func acknowledge(_ hub: ConnectionHub, _ frames: Frames, _ connection: NWConnection, groupID: String = "b") throws -> String {
        hub.sendClustersSnapshot(connection)
        let generation = try XCTUnwrap(try frames.status()["generation"] as? String)
        try sync(hub, connection, [:], generation: generation, groupID: groupID)
        return generation
    }

    func testLegacyPauseProjectsWireAndRuntimeWithoutChangingCanonicalState() throws {
        let (hub, frames, defaults) = hub(); try linked(hub)
        _ = try peer(hub)
        let status = try frames.status()
        XCTAssertEqual(status["state"] as? String, "upgrade-required")
        XCTAssertEqual(status["canonicalEnabled"] as? Bool, true)
        XCTAssertEqual(((frames.latestCluster()?["shared"] as? [String: Any])?["scalars"] as? [String: Any])?["enabled"] as? Bool, false)
        XCTAssertEqual((try canonical(hub)["scalars"] as? [String: Any])?["enabled"] as? Bool, true)
        let group = BlockGroup(id: "m", groupType: .site, name: "Focus", enabled: true, mode: .afterMinutes, allowedMinutes: 30)
        XCTAssertFalse(try XCTUnwrap(hub.runtimeGroups([group]).first).enabled)
        XCTAssertTrue(group.enabled)
        hub.reportLocalUsage(groupID: "m", deltaMs: 900, resetAtMs: 0)
        hub.applySync(program: "chrome", groupId: "b", contribution: ["usageDeltaMs": 800.0], ts: 0)
        XCTAssertEqual(try XCTUnwrap(hub.sharedUsage(groupID: "m")).ms, 5_000)
        XCTAssertFalse(String(describing: defaults.dictionaryRepresentation()).contains("browserIdentityStatus"))
        XCTAssertFalse(String(describing: defaults.dictionaryRepresentation()).contains("com.google.chrome"))
    }

    func testLegacyEffectiveDisabledEchoCannotOverwriteCanonicalEnabled() throws {
        let (hub, _, _) = hub(); try linked(hub)
        let connection = try peer(hub)
        try sync(hub, connection, ["scalars": ["mode": "after-minutes", "enabled": false, "allowedMinutes": 1], "scopes": [], "ts": Date().timeIntervalSince1970 * 1000])
        let shared = try canonical(hub)
        XCTAssertEqual((shared["scalars"] as? [String: Any])?["enabled"] as? Bool, true)
        XCTAssertEqual((shared["scalars"] as? [String: Any])?["allowedMinutes"] as? Int, 30)
        XCTAssertEqual((shared["scopes"] as? [[String: Any]])?.count, 2)
    }

    func testUnrelatedAppsAndCustomRulesRemainAvailableToLegacyPeer() throws {
        for custom in [false, true] {
            let (hub, frames, _) = hub()
            try linked(hub, apps: custom ? [["id": "com.google.Chrome"]] : [["id": "com.example.Editor"]], custom: custom)
            _ = try peer(hub)
            XCTAssertEqual(try frames.status()["state"] as? String, "ready")
            hub.applySync(program: "chrome", groupId: "b", contribution: ["usageDeltaMs": 700.0], ts: 0)
            XCTAssertEqual(try XCTUnwrap(hub.sharedUsage(groupID: "m")).ms, 5_700)
        }
    }

    func testDisconnectRestoresRuntimeAndKeepsOfflineHandoverAdditive() throws {
        let (hub, frames, _) = hub(); try linked(hub)
        let connection = try peer(hub)
        let pausedGeneration = try XCTUnwrap(try frames.status()["generation"] as? String)
        hub.removePeer(ObjectIdentifier(connection))
        // A second updated peer observes ready. The original legacy descriptor
        // was transient, so no cached identity is needed for offline accounting.
        _ = try peer(hub, identity: true)
        XCTAssertEqual(try frames.status()["state"] as? String, "ready")
        XCTAssertFalse(try frames.status()["generation"] as? String == pausedGeneration)
        let group = BlockGroup(id: "m", groupType: .site, name: "Focus", enabled: true, mode: .afterMinutes, allowedMinutes: 30)
        XCTAssertTrue(try XCTUnwrap(hub.runtimeGroups([group]).first).enabled)
        let anchor = try XCTUnwrap(hub.sharedUsage(groupID: "m")).resetAtMs
        hub.applySync(program: "chrome", groupId: "b", contribution: ["usageDeltaMs": 1_000.0, "usageDeltaAnchorMs": anchor, "usageTransferId": "pre-pause"], ts: 0)
        XCTAssertEqual(try XCTUnwrap(hub.sharedUsage(groupID: "m")).ms, 6_000)
    }

    func testUpdatedReconnectRequiresItsOwnExactSnapshotGeneration() throws {
        let (hub, frames, _) = hub(); try linked(hub)
        let legacy = try peer(hub)
        let oldGeneration = try XCTUnwrap(try frames.status()["generation"] as? String)
        hub.removePeer(ObjectIdentifier(legacy))
        let updated = try peer(hub, identity: true)
        let generation = try XCTUnwrap(try frames.status()["generation"] as? String)
        let edit: [String: Any] = ["scalars": ["mode": "after-minutes", "enabled": false, "allowedMinutes": 20], "ts": Date().timeIntervalSince1970 * 1000]
        try sync(hub, updated, edit)
        try sync(hub, updated, edit, generation: oldGeneration)
        XCTAssertEqual((try canonical(hub)["scalars"] as? [String: Any])?["enabled"] as? Bool, true)
        try sync(hub, updated, edit, generation: generation)
        XCTAssertEqual((try canonical(hub)["scalars"] as? [String: Any])?["enabled"] as? Bool, false)
        hub.applySync(program: "macapp", groupId: "m", contribution: ["usageDeltaMs": 100.0], ts: 0)
        XCTAssertEqual(try frames.status()["generation"] as? String, generation)
    }

    func testFirstOriginalAfterRecoveryRetainsScopesAndCanonicalEnable() throws {
        let (hub, frames, _) = hub(); try linked(hub, browserContributed: false, nativeEnabled: false)
        let legacy = try peer(hub)
        XCTAssertEqual(try frames.status()["state"] as? String, "upgrade-required")
        hub.removePeer(ObjectIdentifier(legacy))
        let updated = try peer(hub, identity: true)
        let generation = try XCTUnwrap(try frames.status()["generation"] as? String)
        try sync(hub, updated, ["scalars": ["mode": "after-minutes", "enabled": true, "allowedMinutes": 1],
            "scopes": [["surface": "site", "sites": ["original.example"]]], "usageMs": 8_000.0, "ts": 0.0], generation: generation)
        let shared = try canonical(hub)
        XCTAssertEqual((shared["scalars"] as? [String: Any])?["enabled"] as? Bool, false)
        XCTAssertEqual((shared["scopes"] as? [[String: Any]])?.count, 2)
        XCTAssertTrue(String(describing: shared["scopes"]).contains("original.example"))
        XCTAssertEqual(try XCTUnwrap(hub.sharedUsage(groupID: "m")).ms, 8_000)
    }

    func testNarrowCandidatePolicyRecognizesCustomRegisteredBrowsersAndExclusions() {
        let scalars: [String: Any] = ["groupType": "site", "mode": "after-minutes"]
        let candidates: Set<String> = ["com.google.chrome", "com.example.registered-browser"]
        let website: [String: Any] = ["surface": "site", "sites": ["example.com"]]
        func affected(_ apps: [String], except: Bool = false, policy: [String: Any]? = nil, includeWebsite: Bool = true) -> Bool {
            let scopes: [[String: Any]] = [["surface": "apps", "appsExcept": except, "apps": apps.map { ["id": $0] }]]
                + (includeWebsite ? [website] : [])
            return BrowserIdentityBudgetPolicy.affects(policy ?? scalars, scopes: scopes, browserBundleIDs: candidates)
        }
        XCTAssertTrue(affected(["com.example.registered-browser"]))
        XCTAssertTrue(affected(["COM.GOOGLE.CHROME"]))
        XCTAssertFalse(affected(["com.example.Editor"]))
        XCTAssertFalse(affected(["com.google.chrome"], includeWebsite: false))
        XCTAssertFalse(affected(["com.google.chrome"], policy: ["mode": "instant"]))
        XCTAssertFalse(affected(["com.google.chrome"], policy: ["groupType": "custom", "mode": "after-minutes"]))
        XCTAssertFalse(affected(Array(candidates), except: true))
        XCTAssertTrue(affected(["com.google.chrome"], except: true))
        XCTAssertTrue(affected([], except: true))
    }

    func testPausedCanonicalFileEditorRefusalAndUnlinkRetainSettingsAndUsage() throws {
        let (hub, frames, _) = hub(); try linked(hub)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Agentic.IdentityRuntime." + UUID().uuidString)
        defer { hub.localWebStore = nil; try? FileManager.default.removeItem(at: directory) }
        let store = BlockerWebStore(shared: SharedAppGroupStore(baseDirectory: directory))
        var group = try XCTUnwrap((try GroupActionsRuntime.shared.callThrowing("createToolGroup", [[[String: Any]](), "site", ["name": "Focus"], "desktop"], module: "CBGroupScopes") as? [String: Any])?["group"] as? [String: Any])
        group["id"] = "m"; group["enabled"] = true; group["mode"] = "after-minutes"; group["allowedMinutes"] = 30
        group["scopes"] = [["id": "apps-1", "entryID": "apps", "surface": "apps", "action": "block", "apps": [["id": "com.google.Chrome"]]]]
        let anchor = try XCTUnwrap(hub.sharedUsage(groupID: "m")).resetAtMs
        store.save(rawStore: ["blockedGroups": [group], "usageTimersMs": ["m": 5_000.0], "usageResetAtMs": ["m": anchor]])
        hub.localWebStore = store
        hub.contributeLocalDefinitions(document: [:], nowMs: Date().timeIntervalSince1970 * 1000)
        let legacy = try peer(hub)
        let generation = try XCTUnwrap(try frames.status()["generation"] as? String)
        store.adoptShared()
        let beforeJSON = try XCTUnwrap(store.loadRawJSON())
        let before = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(beforeJSON.utf8)) as? [String: Any])
        let saved = try XCTUnwrap((before["blockedGroups"] as? [[String: Any]])?.first)
        XCTAssertEqual(saved["enabled"] as? Bool, true)
        var after = saved; after["allowedMinutes"] = 20
        let change = try GroupActionsRuntime.shared.callThrowing("editorChange", [saved, after, "desktop"], module: "CBGroupScopes")
        var refused = false
        do { _ = try store.applyEditorDefinitionRequest(["intent": "edit", "changes": [change]]) }
        catch { refused = String(describing: error).contains("browser-upgrade-required") }
        XCTAssertTrue(refused)
        XCTAssertEqual(try XCTUnwrap(store.loadRawJSON()), beforeJSON)
        XCTAssertEqual(try frames.status()["generation"] as? String, generation)
        let deletion = try GroupActionsRuntime.shared.callThrowing("editorChange", [saved, NSNull(), "desktop"], module: "CBGroupScopes")
        var deleteRefused = false
        do { _ = try store.applyEditorDefinitionRequest(["intent": "edit", "changes": [deletion]]) }
        catch { deleteRefused = String(describing: error).contains("browser-upgrade-required") }
        XCTAssertTrue(deleteRefused)
        XCTAssertEqual(try XCTUnwrap(store.loadRawJSON()), beforeJSON)
        let oldGate = GroupStore.sharedMutationRefusal
        GroupStore.sharedMutationRefusal = { hub.mutationRefusal(before: $0, after: $1) }
        defer { GroupStore.sharedMutationRefusal = oldGate }
        for operation in [
            { try store.mergeEditorSideEffectChanges(["groupSnoozes": ["m": ["startsAtMs": 1, "untilMs": 9_999_999_999_999]]]) },
            { try store.resetRuntime(groupID: "m") },
            { _ = try GroupStore(shared: SharedAppGroupStore(baseDirectory: directory)).mutate { _ = try $0.lockGroup(id: "m", waitHours: 1) } },
            { _ = try GroupStore(shared: SharedAppGroupStore(baseDirectory: directory)).mutate { try $0.deleteGroup(id: "m") } }
        ] {
            var denied = false
            do { try operation() } catch { denied = String(describing: error).contains("browser-upgrade-required") }
            XCTAssertTrue(denied)
            XCTAssertEqual(try XCTUnwrap(store.loadRawJSON()), beforeJSON)
        }
        XCTAssertEqual(hub.unlinkGroup(program: "macapp", groupId: "m"), "browser-upgrade-required")
        XCTAssertEqual(try XCTUnwrap(store.loadRawJSON()), beforeJSON)
        hub.removePeer(ObjectIdentifier(legacy))
        XCTAssertEqual(hub.unlinkGroup(program: "macapp", groupId: "m"), "browser-connect-required")
        let updated = try peer(hub, identity: true)
        XCTAssertEqual(hub.unlinkGroup(program: "macapp", groupId: "m"), "browser-sync-required")
        _ = try acknowledge(hub, frames, updated)
        let beforeUnlinkFrame = frames.all().count
        XCTAssertNil(hub.unlinkGroup(program: "macapp", groupId: "m"))
        let unlinked = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(store.loadRawJSON()).utf8)) as? [String: Any])
        XCTAssertEqual(((unlinked["blockedGroups"] as? [[String: Any]])?.first)?["enabled"] as? Bool, true)
        XCTAssertEqual((unlinked["usageTimersMs"] as? [String: Any])?["m"] as? Double, 5_000)
        XCTAssertFalse(String(describing: unlinked).contains("browserIdentityStatus"))
        // A ready updated peer uses normal serialized unlink; no legacy repair
        // definition is emitted before the membership removal.
        XCTAssertFalse(frames.all().dropFirst(beforeUnlinkFrame).contains { frame in
            guard let cluster = frame["cluster"] as? [String: Any] else { return false }
            return (cluster["members"] as? [[String: Any]])?.contains { $0["program"] as? String == "chrome" } == true
        })
    }

    func testPausedStandaloneSnoozeFrameIsRefusedAndPreservesHistory() throws {
        let (hub, frames, _) = hub(); try linked(hub)
        let connection = try peer(hub)
        try sync(hub, connection, ["snooze": ["kind": "time", "startsAtMs": 1, "untilMs": 9_999_999_999_999],
            "snoozeTs": Date().timeIntervalSince1970 * 1000])
        XCTAssertEqual(try canonical(hub)["snoozeTs"] as? Double, 0)
        XCTAssertTrue(frames.all().contains { $0["kind"] as? String == "group-sync-refused" && $0["reason"] as? String == "browser-upgrade-required" })
        XCTAssertEqual(try XCTUnwrap(hub.sharedUsage(groupID: "m")).ms, 5_000)
    }

    func testLegacyAndOfflineAffectedUnlinkRefuseWithoutRepairFrames() throws {
        let (hub, frames, defaults) = hub(); try linked(hub)
        let legacy = try peer(hub)
        let registry = defaults.data(forKey: "ConnectionHub.clusters.v2")
        let shared = try canonical(hub)
        let count = frames.all().count
        XCTAssertEqual(hub.unlinkGroup(program: "chrome", groupId: "b"), "browser-upgrade-required")
        XCTAssertEqual(hub.setRoster(program: "chrome", groups: []), "browser-upgrade-required")
        XCTAssertEqual(frames.all().count, count)
        XCTAssertEqual(defaults.data(forKey: "ConnectionHub.clusters.v2"), registry)
        XCTAssertEqual(hub.activeClusterCount(), 1)
        hub.removePeer(ObjectIdentifier(legacy))
        let offlineFrames = frames.all().count
        XCTAssertEqual(hub.unlinkGroup(program: "macapp", groupId: "m"), "browser-connect-required")
        XCTAssertEqual(frames.all().count, offlineFrames)
        XCTAssertEqual(defaults.data(forKey: "ConnectionHub.clusters.v2"), registry)
        let after = try canonical(hub)
        for field in ["scalars", "usageMs", "usageResetAtMs", "usageBuckets", "snooze", "snoozeTs"] {
            XCTAssertEqual(WebStoreDocument.canonicalJSON(after[field]), WebStoreDocument.canonicalJSON(shared[field]))
        }
    }

    func testAffectedUnlinkRequiresExactCurrentPeerGenerationAcknowledgement() throws {
        let (hub, frames, defaults) = hub(); try linked(hub)
        let original = try peer(hub, identity: true)
        let oldGeneration = try acknowledge(hub, frames, original)
        hub.removePeer(ObjectIdentifier(original))
        let current = try peer(hub, identity: true)
        let registry = defaults.data(forKey: "ConnectionHub.clusters.v2")
        try sync(hub, current, [:], generation: oldGeneration)
        XCTAssertEqual(hub.unlinkGroup(program: "macapp", groupId: "m"), "browser-sync-required")
        hub.sendClustersSnapshot(current)
        let generation = try XCTUnwrap(try frames.status()["generation"] as? String)
        try sync(hub, current, [:], generation: generation, groupID: "unrelated")
        XCTAssertEqual(hub.unlinkGroup(program: "chrome", groupId: "b"), "browser-sync-required")
        XCTAssertEqual(defaults.data(forKey: "ConnectionHub.clusters.v2"), registry)
        _ = try acknowledge(hub, frames, current)
        XCTAssertEqual(hub.unlinkGroup(program: "chrome", groupId: "b", requestingPeerKey: ObjectIdentifier(original)), "browser-unavailable")
        XCTAssertEqual(hub.activeClusterCount(), 1)
        XCTAssertNil(hub.unlinkGroup(program: "chrome", groupId: "b", requestingPeerKey: ObjectIdentifier(current)))
        XCTAssertEqual(hub.activeClusterCount(), 0)
    }

    func testFirstOriginalAckDoesNotAuthorizeUnlinkBeforeFullUnionAck() throws {
        let (hub, frames, _) = hub(narrow: true)
        try linked(hub, browserContributed: false)
        let connection = try peer(hub, identity: true)
        let originalGeneration = try acknowledge(hub, frames, connection)
        try sync(hub, connection, ["scopes": [["surface": "site", "sites": ["example.com"]]], "ts": 0.0], generation: originalGeneration)
        let fullGeneration = try XCTUnwrap(try frames.status()["generation"] as? String)
        XCTAssertFalse(fullGeneration == originalGeneration)
        XCTAssertEqual(hub.unlinkGroup(program: "chrome", groupId: "b"), "browser-sync-required")
        try sync(hub, connection, [:], generation: originalGeneration)
        XCTAssertEqual(hub.unlinkGroup(program: "macapp", groupId: "m"), "browser-sync-required")
        _ = try acknowledge(hub, frames, connection)
        XCTAssertNil(hub.unlinkGroup(program: "chrome", groupId: "b"))
    }

    func testAffectedPartialAndFinalUnlinkRequireEveryBrowserReady() throws {
        let (hub, frames, _) = hub(); try linked(hub)
        hub.setRoster(program: "edge", groups: [["id": "e", "name": "Edge"]])
        XCTAssertNil(hub.linkGroups(program: "macapp", groupId: "m", targetProgram: "edge", targetGroupId: "e"))
        hub.applySync(program: "edge", groupId: "e", contribution: ["scopes": [["surface": "site", "sites": ["edge.example"]]]], ts: 0)
        let chrome = try peer(hub, identity: true)
        let edge = try peer(hub, program: "edge", identity: true)
        _ = try acknowledge(hub, frames, chrome)
        XCTAssertEqual(hub.unlinkGroup(program: "macapp", groupId: "m"), "browser-sync-required")
        _ = try acknowledge(hub, frames, edge, groupID: "e")
        XCTAssertNil(hub.unlinkGroup(program: "edge", groupId: "e"))
        XCTAssertEqual(hub.activeClusterCount(), 1)
        XCTAssertNil(hub.unlinkGroup(program: "macapp", groupId: "m"))
        XCTAssertEqual(hub.activeClusterCount(), 0)
    }

    func testUnaffectedBudgetKindsKeepOfflineUnlink() throws {
        let cases: [([String: Any], [[String: Any]], [[String: Any]])] = [
            (["mode": "after-minutes"], [["surface": "apps", "apps": [["id": "com.google.Chrome"]]]], []),
            (["mode": "after-minutes"], [], [["surface": "site", "sites": ["example.com"]]]),
            (["mode": "after-minutes"], [["surface": "apps", "apps": [["id": "com.example.Editor"]]]], [["surface": "site", "sites": ["example.com"]]]),
            (["mode": "after-minutes"], [["surface": "apps", "apps": [["id": "com.google.Chrome"]]]], [["surface": "site", "sites": [], "sitesExcept": false]]),
            (["groupType": "custom", "mode": "after-minutes"], [["surface": "apps", "apps": [["id": "com.google.Chrome"]]]], [["surface": "site", "sites": ["example.com"]]])
        ]
        for (policy, apps, websites) in cases {
            let (hub, _, _) = hub(narrow: true)
            hub.setRoster(program: "macapp", groups: [["id": "m", "name": "Focus"]])
            hub.setRoster(program: "chrome", groups: [["id": "b", "name": "Focus"]])
            XCTAssertNil(hub.linkGroups(program: "macapp", groupId: "m", targetProgram: "chrome", targetGroupId: "b"))
            hub.applySync(program: "macapp", groupId: "m", contribution: ["scalars": policy.merging(["enabled": true]) { a, _ in a }, "scopes": apps], ts: 0)
            hub.applySync(program: "chrome", groupId: "b", contribution: ["scopes": websites], ts: 0)
            XCTAssertNil(hub.unlinkGroup(program: "macapp", groupId: "m"))
            XCTAssertEqual(hub.activeClusterCount(), 0)
        }
    }

    func testCorrelatedUnlinkReceiptFollowsCommittedRemovalAndReportsRefusal() throws {
        let (hub, frames, _) = hub(); try linked(hub)
        let connection = try peer(hub, identity: true)
        func request(_ id: String) throws {
            let frame: [String: Any] = ["kind": "group-unlink", "groupId": "b", "requestID": id]
            hub.handleIncoming(connection, key: ObjectIdentifier(connection), data: try JSONSerialization.data(withJSONObject: frame))
        }
        try request("pending")
        let denied = try XCTUnwrap(frames.all().last { $0["requestID"] as? String == "pending" })
        XCTAssertEqual(denied["ok"] as? Bool, false)
        XCTAssertEqual(denied["error"] as? String, "browser-sync-required")
        XCTAssertEqual(hub.activeClusterCount(), 1)
        _ = try acknowledge(hub, frames, connection)
        let start = frames.all().count
        try request("ready")
        let sent = Array(frames.all().dropFirst(start))
        let receipt = try XCTUnwrap(sent.last)
        XCTAssertEqual(receipt["kind"] as? String, "group-unlink-response")
        XCTAssertEqual(receipt["requestID"] as? String, "ready")
        XCTAssertEqual(receipt["ok"] as? Bool, true)
        XCTAssertTrue(sent.dropLast().contains { ($0["cluster"] as? [String: Any])?["members"] as? [[String: Any]] != nil })
        XCTAssertEqual(hub.activeClusterCount(), 0)
    }

    func testUnlinkSaveFailureHasFailureReceiptAndKeepsCanonicalBytes() throws {
        let (hub, frames, defaults, store, directory, legacy) = try preflightFixture()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            hub.localWebStore = nil; try? FileManager.default.removeItem(at: directory)
        }
        hub.removePeer(ObjectIdentifier(legacy))
        hub.setRoster(program: "chrome", groups: [["id": "b", "name": "Browser"]])
        XCTAssertNil(hub.linkGroups(program: "macapp", groupId: "m", targetProgram: "chrome", targetGroupId: "b"))
        hub.applySync(program: "chrome", groupId: "b", contribution: ["scopes": [["surface": "site", "sites": ["example.com"]]]], ts: 0)
        hub.contributeLocalDefinitions(document: [:], nowMs: Date().timeIntervalSince1970 * 1000)
        let connection = try peer(hub, identity: true)
        _ = try acknowledge(hub, frames, connection)
        let before = store.loadRawJSON(), registry = defaults.data(forKey: "ConnectionHub.clusters.v2")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        let request: [String: Any] = ["kind": "group-unlink", "groupId": "b", "requestID": "save-failure"]
        hub.handleIncoming(connection, key: ObjectIdentifier(connection), data: try JSONSerialization.data(withJSONObject: request))
        let receipt = try XCTUnwrap(frames.all().last { $0["requestID"] as? String == "save-failure" })
        XCTAssertEqual(receipt["ok"] as? Bool, false)
        XCTAssertEqual(receipt["error"] as? String, "local-storage-unavailable")
        XCTAssertEqual(store.loadRawJSON(), before)
        XCTAssertEqual(defaults.data(forKey: "ConnectionHub.clusters.v2"), registry)
        XCTAssertEqual(hub.activeClusterCount(), 1)
    }

    private func preflightFixture(nativeMode: String = "after-minutes") throws -> (ConnectionHub, Frames, UserDefaults, BlockerWebStore, URL, NWConnection) {
        let (hub, frames, defaults) = hub(narrow: true)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Agentic.LinkPreflight." + UUID().uuidString)
        let store = BlockerWebStore(shared: SharedAppGroupStore(baseDirectory: directory))
        store.save(rawStore: ["blockedGroups": [["id": "m", "name": "Native", "groupType": "site", "mode": nativeMode, "enabled": true,
            "allowedMinutes": 30, "scopes": [["surface": "apps", "apps": [["id": "com.google.Chrome"]]]]]], "usageTimersMs": ["m": 5_000.0]])
        hub.localWebStore = store; hub.hostingLocalHub = true
        hub.contributeLocalDefinitions(document: [:], nowMs: Date().timeIntervalSince1970 * 1000)
        let connection = try peer(hub)
        hub.setRoster(program: "chrome", groups: [["id": "b", "name": "Browser"]])
        return (hub, frames, defaults, store, directory, connection)
    }

    private func browserResponse(_ hub: ConnectionHub, _ connection: NWConnection, request: [String: Any], scopes: [[String: Any]], mode: String = "after-minutes") throws {
        let response: [String: Any] = ["kind": "browser-response", "operation": "settings-get", "requestID": try XCTUnwrap(request["requestID"] as? String),
            "body": ["groups": [["id": "b", "name": "Browser", "groupType": "site", "mode": mode, "enabled": true, "allowedMinutes": 30, "scopes": scopes]]]]
        hub.handleIncoming(connection, key: ObjectIdentifier(connection), data: try JSONSerialization.data(withJSONObject: response))
    }

    func testLegacyFirstLinkReadsRealScopesAndKeepsNoWebsiteGroupWorking() throws {
        let cases: [([[String: Any]], Bool)] = [
            ([], false),
            ([["surface": "site", "sites": [], "sitesExcept": false, "action": "block"]], false),
            ([["surface": "site", "sites": [" ", "https://"], "sitesExcept": false, "action": "block"]], false),
            ([["surface": "site", "sites": ["example.com"], "sitesExcept": false, "action": "block"]], true),
            ([["surface": "site", "sites": [], "sitesExcept": true, "action": "block"]], true),
            ([["surface": "site", "sites": ["example.com"], "sitesExcept": false, "action": "pause"]], true)
        ]
        for (scopes, hasWebsite) in cases {
            let (hub, frames, _, store, directory, connection) = try preflightFixture()
            defer { hub.localWebStore = nil; try? FileManager.default.removeItem(at: directory) }
            let before = store.loadRawJSON()
            let signal = DispatchSemaphore(value: 0); var result: String?
            hub.linkGroupsWithBrowserIdentityPreflight(program: "macapp", groupId: "m", targetProgram: "chrome", targetGroupId: "b") { result = $0; signal.signal() }
            let request = try frames.latestRequest()
            XCTAssertEqual(hub.activeClusterCount(), 0)
            try browserResponse(hub, connection, request: request, scopes: scopes)
            XCTAssertEqual(signal.wait(timeout: .now() + 3), .success)
            XCTAssertEqual(result, hasWebsite ? "browser-upgrade-required" : nil)
            XCTAssertEqual(hub.activeClusterCount(), hasWebsite ? 0 : 1)
            XCTAssertEqual(store.loadRawJSON(), before)
        }
    }

    func testEmptyNormalizedSiteScopesDoNotRequireIdentity() {
        let scalars: [String: Any] = ["groupType": "site", "mode": "after-minutes"]
        let apps: [String: Any] = ["surface": "apps", "apps": [["id": "com.google.Chrome"]]]
        func affected(_ line: [String: Any]) -> Bool {
            BrowserIdentityBudgetPolicy.affects(scalars, scopes: [apps, line], browserBundleIDs: ["com.google.chrome"])
        }
        XCTAssertFalse(affected(["surface": "site", "sites": [], "sitesExcept": false]))
        XCTAssertFalse(affected(["surface": "site", "sites": [" ", "https://", "not a host"], "sitesExcept": false]))
        XCTAssertTrue(affected(["surface": "site", "sites": [], "sitesExcept": true]))
        XCTAssertTrue(affected(["surface": "site", "sites": [" https://www.Example.com/path/?query=yes#part "], "sitesExcept": false]))
        XCTAssertTrue(affected(["surface": "site", "sites": ["example.com"], "action": "pause"]))
        // Platform content filtering remains conservative: an empty include
        // filter is not assumed to make every platform surface ineligible.
        XCTAssertTrue(affected(["surface": "items", "platform": "youtube", "sources": [], "sourceMode": "include"]))
    }

    func testBrowserInitiatorUsesItsActualBudgetInLegacyPreflight() throws {
        let (hub, frames, _, store, directory, connection) = try preflightFixture(nativeMode: "instant")
        defer { hub.localWebStore = nil; try? FileManager.default.removeItem(at: directory) }
        let signal = DispatchSemaphore(value: 0); var result: String?
        hub.linkGroupsWithBrowserIdentityPreflight(program: "chrome", groupId: "b", targetProgram: "macapp", targetGroupId: "m") { result = $0; signal.signal() }
        try browserResponse(hub, connection, request: frames.latestRequest(), scopes: [["surface": "site", "sites": ["example.com"]]])
        XCTAssertEqual(signal.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(result, "browser-upgrade-required")
        XCTAssertEqual(hub.activeClusterCount(), 0)
        XCTAssertNotNil(store.loadRawJSON())
    }

    func testStaleRosterDisconnectTimeoutAndSaveFailureCannotCreateLink() throws {
        for failure in ["roster", "disconnect", "timeout", "storage", "native-definition"] {
            let (hub, frames, defaults, store, directory, connection) = try preflightFixture()
            defer { hub.localWebStore = nil; try? FileManager.default.removeItem(at: directory) }
            let original = store.loadRawJSON()
            let signal = DispatchSemaphore(value: 0); var result: String?
            hub.linkGroupsWithBrowserIdentityPreflight(program: "macapp", groupId: "m", targetProgram: "chrome", targetGroupId: "b") { result = $0; signal.signal() }
            let request = try frames.latestRequest()
            if failure == "roster" { hub.setRoster(program: "chrome", groups: [["id": "b", "name": "Changed"]]) }
            if failure == "storage" { defaults.set(Data("unsupported".utf8), forKey: "ConnectionHub.clusters.v2") }
            if failure == "native-definition" {
                var raw = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(original).utf8)) as? [String: Any])
                var groups = try XCTUnwrap(raw["blockedGroups"] as? [[String: Any]]); groups[0]["allowedMinutes"] = 40; raw["blockedGroups"] = groups
                store.save(rawStore: raw)
            }
            let beforeReply = store.loadRawJSON()
            if failure == "disconnect" { hub.removePeer(ObjectIdentifier(connection)) }
            else if failure == "timeout" { hub.expireBrowserRequest(try XCTUnwrap(request["requestID"] as? String)) }
            else { try browserResponse(hub, connection, request: request, scopes: []) }
            XCTAssertEqual(signal.wait(timeout: .now() + 3), .success)
            XCTAssertNotNil(result)
            XCTAssertEqual(hub.activeClusterCount(), 0)
            XCTAssertEqual(store.loadRawJSON(), beforeReply)
        }
    }
}
#endif
