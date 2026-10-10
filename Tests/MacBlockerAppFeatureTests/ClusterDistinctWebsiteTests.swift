import XCTest
@testable import MacBlockerAppFeature
import MacBlockerCore
import struct VaultClassifierCore.StorageSchemaPolicy

final class ClusterDistinctWebsiteTests: XCTestCase {
    private let registryKey = "ConnectionHub.clusters.v2"
    private var previousRegistry: Data?
    override func setUp() { super.setUp(); previousRegistry = UserDefaults.standard.data(forKey: registryKey) }
    override func tearDown() {
        if let previousRegistry { UserDefaults.standard.set(previousRegistry, forKey: registryKey) }
        else { UserDefaults.standard.removeObject(forKey: registryKey) }
        super.tearDown()
    }
    private func site(_ target: String, except: Bool = false, action: String = "block", entry: String? = nil) -> [String: Any] {
        var line: [String: Any] = ["id": "site-1", "surface": "site", "platform": NSNull(), "sites": [target], "sitesExcept": except, "action": action]
        if let entry { line["entryID"] = entry }; return line
    }
    private func hub(initiator: String) -> ConnectionHub {
        let h = ConnectionHub(); h.hostingLocalHub = true
        for (p, id) in [("macapp", "m"), ("chrome", "c"), ("edge", "e"), ("safari", "s")] { h.setRoster(program: p, groups: [["id": id, "name": p]]) }
        XCTAssertNil(h.linkGroups(program: initiator, groupId: initiator == "chrome" ? "c" : "e", targetProgram: initiator == "chrome" ? "edge" : "chrome", targetGroupId: initiator == "chrome" ? "e" : "c"))
        XCTAssertNil(h.linkGroups(program: "macapp", groupId: "m", targetProgram: "chrome", targetGroupId: "c"))
        return h
    }
    private func send(_ h: ConnectionHub, _ p: String, _ lines: [[String: Any]], ts: Double = 0, name: String? = nil) {
        h.applySync(program: p, groupId: ["macapp": "m", "chrome": "c", "edge": "e", "safari": "s"][p]!, contribution: ["scopes": lines, "scalars": ["name": name ?? p]], ts: ts)
    }
    private func scopes(_ h: ConnectionHub) throws -> [[String: Any]] {
        let doc = h.overlayShared(onto: ["blockedGroups": [["id": "m"]]])
        return try XCTUnwrap((doc["blockedGroups"] as? [[String: Any]])?.first?["scopes"] as? [[String: Any]])
    }
    private func persistedScopes() throws -> [[String: Any]] {
        let saved = try XCTUnwrap(UserDefaults.standard.data(forKey: registryKey))
        let payload = try StorageSchemaPolicy(format: "hub.clusters").payload(from: saved)
        let registry = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [[String: Any]])
        return try XCTUnwrap(registry.first?["sharedScopes"] as? [[String: Any]])
    }
    func testBothOrdersKeepIncludedAndExcludedOriginalsWithInitiatorBaseAndPolicy() throws {
        for initiator in ["chrome", "edge"] { for order in [["chrome", "edge"], ["edge", "chrome"]] {
            let h = hub(initiator: initiator)
            for p in order { send(h, p, [site(p + ".example", except: p == "edge")]) }
            send(h, "macapp", [["id": "apps-1", "surface": "apps", "apps": [["id": "com.example.Game"]]]])
            let lines = try scopes(h).filter { $0["surface"] as? String == "site" }
            XCTAssertEqual(lines.count, 2)
            XCTAssertEqual(Set(lines.flatMap { $0["sites"] as? [String] ?? [] }), ["chrome.example", "edge.example"])
            XCTAssertEqual(lines.first(where: { ConnectionHub.scopeEntryKey($0) == "site" })?["sites"] as? [String], [initiator + ".example"])
            XCTAssertEqual(lines.first(where: { ($0["sites"] as? [String]) == ["edge.example"] })?["sitesExcept"] as? Bool, true)
            XCTAssertEqual((h.overlayShared(onto: ["blockedGroups": [["id": "m"]]])["blockedGroups"] as? [[String: Any]])?.first?["name"] as? String, initiator)
        } }
    }
    func testActionDifferencesAndTwoDifferentExclusionListsRemainIndependent() {
        for incoming in [site("b.example", action: "pause"), site("b.example", except: true)] {
            let lines = ConnectionHub.unionOriginalScopes([site("a.example", except: true)], incoming: [incoming])
            XCTAssertEqual(lines.count, 2)
            XCTAssertEqual(Set(lines.map(ConnectionHub.scopeEntryKey)).count, 2)
            XCTAssertEqual(lines.last?["sitesExcept"] as? Bool, incoming["sitesExcept"] as? Bool)
            XCTAssertEqual(lines.last?["action"] as? String, incoming["action"] as? String)
        }
    }
    func testOriginalReplayBeforeLateInitiatorCannotReplaceOtherBrowserOriginals() throws {
        let h = hub(initiator: "chrome")
        XCTAssertNil(h.linkGroups(program: "safari", groupId: "s", targetProgram: "chrome", targetGroupId: "c"))
        send(h, "edge", [site("edge.example", except: true)])
        send(h, "safari", [site("safari.example", action: "pause")])
        let firstKeys = Set(try persistedScopes().map(ConnectionHub.scopeEntryKey))
        XCTAssertEqual(firstKeys.count, 2)
        send(h, "edge", [site("edge.example", except: true)])
        XCTAssertEqual(Set(try persistedScopes().map(ConnectionHub.scopeEntryKey)), firstKeys)
        send(h, "chrome", [site("chrome.example")]); send(h, "macapp", [])
        XCTAssertEqual(try scopes(h).count, 3)
        XCTAssertEqual(Set(try scopes(h).flatMap { $0["sites"] as? [String] ?? [] }), ["chrome.example", "edge.example", "safari.example"])
    }
    func testOccupiedAliasIsNeverOverwrittenAndForwardedAliasNeverCloned() {
        let origin = ConnectionHub.scopeOrigin(program: "edge", groupID: "e", entry: "")
        let alias = ConnectionHub.originalScopeAlias(origin: origin + "site")
        var origins: [String: String] = [:]
        let prior = [site("a.example"), site("occupied.example", except: true, entry: alias)]
        let result = ConnectionHub.unionOriginalScopes(prior, incoming: [site("b.example", except: true)], origins: &origins, origin: origin)
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result.last?["entryID"] as? String, alias + "_2")
        let again = ConnectionHub.unionOriginalScopes(result, incoming: result, origins: &origins, origin: origin)
        XCTAssertEqual(again.count, 3)
        XCTAssertEqual(Set(again.map(ConnectionHub.scopeEntryKey)), Set(result.map(ConnectionHub.scopeEntryKey)))
    }
    func testSharedAliasesSurviveRestartUnlinkRelinkAndLaterExplicitDeletion() throws {
        let old = UserDefaults.standard.data(forKey: registryKey)
        defer { if let old { UserDefaults.standard.set(old, forKey: registryKey) } else { UserDefaults.standard.removeObject(forKey: registryKey) } }
        let h = hub(initiator: "chrome")
        send(h, "edge", [site("edge.example", except: true)])
        let restored = ConnectionHub(); restored.hostingLocalHub = true; restored.restoreClustersLocked()
        for (p, id) in [("macapp", "m"), ("chrome", "c"), ("edge", "e")] { restored.setRoster(program: p, groups: [["id": id, "name": p]]) }
        send(restored, "chrome", [site("chrome.example")]); send(restored, "macapp", [])
        let originals = try scopes(restored)
        XCTAssertEqual(originals.count, 2)
        let alias = try XCTUnwrap(originals.first(where: { ConnectionHub.scopeEntryKey($0) != "site" })?["entryID"] as? String)
        XCTAssertEqual(alias, ConnectionHub.originalScopeAlias(origin: ConnectionHub.scopeOrigin(program: "edge", groupID: "e", entry: "site")))
        XCTAssertNil(restored.unlinkGroup(program: "edge", groupId: "e"))
        XCTAssertNil(restored.linkGroups(program: "edge", groupId: "e", targetProgram: "chrome", targetGroupId: "c"))
        send(restored, "edge", originals)
        XCTAssertEqual(Set(try scopes(restored).map(ConnectionHub.scopeEntryKey)), ["site", alias])
        send(restored, "chrome", [site("chrome.example")], ts: Date().timeIntervalSince1970 * 1000 + 10)
        XCTAssertEqual(try scopes(restored).count, 1)
        let latest = try XCTUnwrap(UserDefaults.standard.data(forKey: registryKey))
        let payload = try StorageSchemaPolicy(format: "hub.clusters").payload(from: latest)
        let registry = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [[String: Any]])
        XCTAssertEqual((registry.first?["scopeOrigins"] as? [String: String])?.keys.sorted(), ["site"])
    }
    func testSameExplicitEntryCollisionKeepsIndependentIdentityAndExactDuplicateDeduplicates() {
        let old = site("a.example", except: true, entry: "site:owned")
        let new = site("b.example", except: true, entry: "site:owned")
        let result = ConnectionHub.unionOriginalScopes([old], incoming: [new])
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.first?["entryID"] as? String, "site:owned")
        XCTAssertEqual(ConnectionHub.unionOriginalScopes(result, incoming: [new]).count, 2)
    }
    func testEquivalentWebsiteDefaultsAndExcludedTargetOrderDoNotCreateAnotherEntry() {
        var original = site("a.example", except: true)
        original["sites"] = ["a.example", "b.example"]
        original.removeValue(forKey: "action"); original.removeValue(forKey: "platform")
        var incoming = site("b.example", except: true, entry: "site")
        incoming["sites"] = ["b.example", "a.example", "a.example"]
        let merged = ConnectionHub.unionOriginalScopes([original], incoming: [incoming])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?["sites"] as? [String], ["a.example", "b.example"])
        var implicit = site("a.example")
        implicit.removeValue(forKey: "sitesExcept"); implicit.removeValue(forKey: "action")
        implicit.removeValue(forKey: "platform")
        XCTAssertEqual(ConnectionHub.unionOriginalScopes([implicit], incoming: [site("a.example", entry: "site")]).count, 1)
    }
    func testCanonicalNativeModuleKeepsAliasesAndRefusesForeignWebsiteEdits() throws {
        let alias = "site:linked_0123456789abcdef01234567"
        let group: [String: Any] = ["id": "group", "name": "Linked", "groupType": "youtube", "scopes": [
            ["surface": "items", "platform": "youtube", "sourceMode": "all", "action": "hide"],
            site("a.example"), site("b.example", except: true, entry: alias),
            ["surface": "apps", "apps": [["id": "com.example.Game"]]]]]
        let runtime = GroupActionsRuntime.shared
        let ambiguity = runtime.call("applyToolEdit", [group, ["sites": ["new.example"]], "browser"], module: "CBGroupScopes") as? [String: Any]
        XCTAssertEqual(ambiguity?["error"] as? String, "ambiguous-entry: specify entryID or scopes")
        let edited = try XCTUnwrap(runtime.call("applyToolEdit", [group, ["entryID": alias, "sites": ["new.example"]], "browser"], module: "CBGroupScopes") as? [String: Any])
        let scopes = try XCTUnwrap((edited["group"] as? [String: Any])?["scopes"] as? [[String: Any]])
        XCTAssertEqual(scopes.first(where: { ConnectionHub.scopeEntryKey($0) == alias })?["sites"] as? [String], ["new.example"])
        XCTAssertEqual(scopes.first(where: { ConnectionHub.scopeEntryKey($0) == "site" })?["sites"] as? [String], ["a.example"])
        var document = WebStoreDocument(raw: ["blockedGroups": [group]])
        XCTAssertThrowsError(try document.setGroup(id: "group", patch: ["entryID": alias, "sites": ["native.example"]]))
        try document.setGroup(id: "group", patch: ["name": "Renamed"])
        let retained = try XCTUnwrap(document.group(id: "group")?["scopes"] as? [[String: Any]])
        XCTAssertEqual(retained.filter { $0["surface"] as? String == "site" }.count, 2)
        XCTAssertEqual(retained.first(where: { ConnectionHub.scopeEntryKey($0) == alias })?["sitesExcept"] as? Bool, true)
    }

    func testOldRegistryWithoutOriginsIsSupportedAndMalformedPresentOriginsRefuseWrites() throws {
        let old = UserDefaults.standard.data(forKey: registryKey)
        defer { if let old { UserDefaults.standard.set(old, forKey: registryKey) } else { UserDefaults.standard.removeObject(forKey: registryKey) } }
        let h = hub(initiator: "chrome"); send(h, "edge", [site("edge.example", except: true)])
        let saved = try XCTUnwrap(UserDefaults.standard.data(forKey: registryKey))
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        // Storage schema wraps an array; discover its payload field without altering metadata.
        let payloadKey = try XCTUnwrap(envelope.first(where: { $0.value is [[String: Any]] })?.key)
        var clusters = try XCTUnwrap(envelope[payloadKey] as? [[String: Any]])
        clusters[0].removeValue(forKey: "scopeOrigins"); envelope[payloadKey] = clusters
        UserDefaults.standard.set(try JSONSerialization.data(withJSONObject: envelope), forKey: registryKey)
        let legacy = ConnectionHub(); legacy.restoreClustersLocked()
        let restored = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(legacy.clustersJSON().utf8)) as? [String: Any])
        XCTAssertEqual((restored["clusters"] as? [[String: Any]])?.count, 1)
        legacy.hostingLocalHub = true
        for (p,id) in [("macapp","m"),("chrome","c"),("edge","e")] { legacy.setRoster(program: p, groups: [["id": id,"name": p]]) }
        send(legacy, "chrome", [site("chrome.example")]); send(legacy, "macapp", [])
        XCTAssertEqual(try scopes(legacy).count, 2, "old pending registry still keeps both originals when the initiator arrives")
        let invalidOrigins: [[String: Any]] = [["site": 17], ["apps": "chrome\0c\0site"], ["site": "macapp\0m\0site"], ["site": "chrome\0c"]]
        for invalid in invalidOrigins {
            clusters[0]["scopeOrigins"] = invalid; envelope[payloadKey] = clusters
            let malformed = try JSONSerialization.data(withJSONObject: envelope)
            UserDefaults.standard.set(malformed, forKey: registryKey)
            let refused = ConnectionHub(); refused.restoreClustersLocked()
            refused.setRoster(program: "chrome", groups: [["id": "new", "name": "new"]])
            refused.setRoster(program: "macapp", groups: [["id": "native", "name": "native"]])
            XCTAssertEqual(refused.linkGroups(program: "chrome", groupId: "new", targetProgram: "macapp", targetGroupId: "native"), "unsupported-storage")
            XCTAssertEqual(UserDefaults.standard.data(forKey: registryKey), malformed)
        }
    }
}
