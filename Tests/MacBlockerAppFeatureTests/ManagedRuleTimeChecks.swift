#if os(macOS)
import Foundation
@testable import MacBlockerAppFeature
import MacBlockerCore
import MacBlockerWebUI

// Shared by XCTest and the bounded CLI contract probe on hosts without XCTest.
// Every document/defaults domain is disposable; no listener or app is started.
enum ManagedRuleTimeChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func run(_ report: (String) -> Void) throws {
        func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
            guard try value() else { throw Failure(description: label) }; report(label)
        }
        func object(_ json: String) throws -> [String: Any] { try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any] }
        let suite = "Agentic.ManagedTimeContract." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("managed-time-" + UUID().uuidString)
        defer { try? FileManager.default.setAttributes([.posixPermissions:0o700], ofItemAtPath:directory.path); try? FileManager.default.removeItem(at:directory) }
        let store = BlockerWebStore(shared: SharedAppGroupStore(baseDirectory:directory))
        store.save(rawStore:["blockedGroups":[["id":"m","name":"Mac","groupType":"custom","enabled":true]],"cbRuleState":["other":["sentinel":17]]])
        let runtime = try RuleRuntime()
        let source = #"(on,v)=>{const t=v.timer('clock',{durationMs:60000});const r=v.rolling('budget',{windowMs:120000,limitMs:10000});r.assign({apps:['org.example.game']});on('tick',()=>{v.state.clock=t.snapshot();v.state.budget=r.snapshot();});}"#
        let load = try runtime.load(groupID:"m",source:source,stateJSON:"{}")
        try check(load.ok,"native managed rule loads")
        let seed = try object(load.states["m"]!)["$vaultTime"] as! [String: Any]
        let hub = ConnectionHub(registryDefaults:defaults); hub.hostingLocalHub = true; hub.localWebStore = store
        hub.setRoster(program:"macapp",groups:[["id":"m","name":"Mac","timeState":seed]])
        hub.setRoster(program:"chrome",groups:[["id":"c","name":"Chrome","timeState":seed]])
        try check(hub.linkGroups(program:"macapp",groupId:"m",targetProgram:"chrome",targetGroupId:"c") == nil,"actual Mac hub preflights and links compatible objects")
        let first = hub.syncRuleTime(groupID:"m",seed:seed,commands:[])
        try check(first["ready"] as? Bool == false,"actual Mac hub waits for every fresh member seed")
        let second = hub.syncRuleTime(program:"chrome",groupID:"c",seed:seed,commands:[])
        try check(second["ready"] as? Bool == true,"actual Mac hub opens only after both seeds confirm")
        let cluster = second["clusterId"] as! String
        let at = (Date().timeIntervalSince1970 * 1000).rounded(.down)
        let reset: [String:Any] = ["id":"clock","op":"reset","serial":1,"atMs":at,"scope":cluster]
        let mutation = hub.syncRuleTime(groupID:"m",clusterID:cluster,seed:seed,commands:[reset])
        let replay = hub.syncRuleTime(groupID:"m",clusterID:cluster,seed:seed,commands:[reset])
        func generation(_ frame: [String:Any]) -> Int? { (((frame["state"] as? [String:Any])?["objects"] as? [String:Any])?["clock"] as? [String:Any])?["generation"] as? Int }
        try check(mutation["acknowledgedSerial"] as? Int == 1 && generation(mutation) == 1 && generation(replay) == 1,"actual Mac hub persists replay receipt before acknowledging reset")
        let wrong = hub.syncRuleTime(groupID:"m",clusterID:"different",seed:seed,commands:[reset])
        try check(wrong["ready"] as? Bool == false,"actual Mac hub refuses a stale cluster identity")
        let restored = ConnectionHub(registryDefaults:defaults); restored.hostingLocalHub = true; restored.restoreClustersLocked()
        let reopened = restored.syncRuleTime(groupID:"m",clusterID:cluster,seed:seed,commands:[reset])
        try check(reopened["ready"] as? Bool == true && generation(reopened) == 1,"actual Mac registry restart retains timer and replay receipt")
        try store.commitRuleDispatch(["m":"{\"done\":true}"])
        let saved = try Data(contentsOf:store.fileURL)
        try check(try object(store.ruleState(groupID:"m"))["done"] as? Bool == true,"event state saves through the throwing native writer")
        try FileManager.default.setAttributes([.posixPermissions:0o500], ofItemAtPath:directory.path)
        var refused = false
        do { try store.commitRuleDispatch(["m":"{\"done\":false}"]) } catch { refused = true }
        try check(refused && (try Data(contentsOf:store.fileURL)) == saved,"native event save failure is explicit and preserves saved completion")
        try FileManager.default.setAttributes([.posixPermissions:0o700], ofItemAtPath:directory.path)
        do { try store.commitRuleDispatch(["deleted":"{}"]); throw Failure(description:"deleted group unexpectedly recreated") } catch is GroupStoreError { }
        try check((try Data(contentsOf:store.fileURL)) == saved,"native event state cannot resurrect a deleted group")
        let key = "ConnectionHub.clusters.v2"
        let bytes = defaults.data(forKey:key)!
        var newer = try JSONSerialization.jsonObject(with:bytes) as! [String:Any]
        var metadata = newer["storageMetadata"] as! [String:Any]; metadata["schemaVersion"] = 999; newer["storageMetadata"] = metadata
        let newerBytes = try JSONSerialization.data(withJSONObject:newer)
        defaults.set(newerBytes,forKey:key)
        let unsupported = ConnectionHub(registryDefaults:defaults); unsupported.hostingLocalHub = true; unsupported.restoreClustersLocked()
        let answer = unsupported.syncRuleTime(groupID:"m",seed:seed.merging(["scope":cluster]){ _, new in new },commands:[])
        try check(answer["ready"] as? Bool == false && defaults.data(forKey:key) == newerBytes,"newer registry remains unchanged and cannot grant a local allowance")
    }
}
#endif
