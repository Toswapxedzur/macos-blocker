#if os(macOS)
import Foundation
@testable import MacBlockerAppFeature
import MacBlockerCore
import MacBlockerWebUI

// Shared by XCTest and the bounded CLI contract probe on hosts without XCTest.
// Every document/defaults domain is disposable; no listener or app is started.
private final class ManagedTimeRegistryDefaults: UserDefaults {
    var refuseWrites = false
    override func set(_ value: Any?, forKey defaultName: String) {
        if !refuseWrites { super.set(value, forKey: defaultName) }
    }
    override func synchronize() -> Bool { !refuseWrites && super.synchronize() }
}

enum ManagedRuleTimeChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func run(_ report: (String) -> Void) throws {
        func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
            guard try value() else { throw Failure(description: label) }; report(label)
        }
        func object(_ json: String) throws -> [String: Any] { try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any] }
        let suite = "Agentic.ManagedTimeContract." + UUID().uuidString
        let defaults = ManagedTimeRegistryDefaults(suiteName: suite)!
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
        let browserRuntime = try RuleRuntime()
        let browserLoad = try browserRuntime.load(groupID:"c",source:source.replacingOccurrences(of:"apps:['org.example.game']",with:"websites:['example.com']"),stateJSON:"{}")
        let browserSeed = try object(browserLoad.states["c"]!)["$vaultTime"] as! [String: Any]
        let hub = ConnectionHub(registryDefaults:defaults); hub.hostingLocalHub = true; hub.localWebStore = store
        hub.setRoster(program:"macapp",groups:[["id":"m","name":"Mac","timeState":seed]])
        hub.setRoster(program:"chrome",groups:[["id":"c","name":"Chrome","timeState":browserSeed]])
        try check(hub.linkGroups(program:"macapp",groupId:"m",targetProgram:"chrome",targetGroupId:"c") == nil,"actual Mac hub preflights and links compatible objects")
        let first = hub.syncRuleTime(groupID:"m",seed:seed,commands:[])
        try check(first["ready"] as? Bool == false,"actual Mac hub waits for every fresh member seed")
        let second = hub.syncRuleTime(program:"chrome",groupID:"c",seed:browserSeed,commands:[])
        try check(second["ready"] as? Bool == true,"actual Mac hub opens only after both seeds confirm")
        let cluster = second["clusterId"] as! String
        let at = (Date().timeIntervalSince1970 * 1000).rounded(.down)
        let reset: [String:Any] = ["id":"clock","op":"reset","serial":1,"atMs":at,"scope":cluster]
        let mutation = hub.syncRuleTime(groupID:"m",clusterID:cluster,seed:seed,commands:[reset])
        let replay = hub.syncRuleTime(groupID:"m",clusterID:cluster,seed:seed,commands:[reset])
        func generation(_ frame: [String:Any]) -> Int? { (((frame["state"] as? [String:Any])?["objects"] as? [String:Any])?["clock"] as? [String:Any])?["generation"] as? Int }
        try check(mutation["acknowledgedSerial"] as? Int == 1 && generation(mutation) == 1 && generation(replay) == 1,"actual Mac hub persists replay receipt before acknowledging reset")
        try runtime.setTimeContext(groupID:"m",contextJSON:String(decoding:try JSONSerialization.data(withJSONObject:mutation),as:UTF8.self))
        let linkedTick = try runtime.dispatch(type:"tick",data:[:],groupID:"m")
        try check((try object(linkedTick.states["m"]!)["$vaultTime"] as? [String:Any])?["scope"] as? String == cluster,"live native engine has the linked namespace before unlink")
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
        // The member's disk copy is deliberately older than the shared reset.
        try store.commitRuleDispatch(["m":load.states["m"]!])
        var disabledDocument = try object(store.loadRawJSON()!)
        var disabledGroups = disabledDocument["blockedGroups"] as! [[String:Any]]
        disabledGroups[0]["enabled"] = false; disabledDocument["blockedGroups"] = disabledGroups
        store.save(rawStore:disabledDocument)
        runtime.suppress(groupID:"m",true)
        try check(hub.unlinkGroup(program:"chrome",groupId:"c") == nil,"unlink succeeds with the other member offline")
        try check(hub.activeClusterCount() == 0 && hub.clustersJSON().contains("\"clusters\":[]"),"retained final snapshots do not appear as live links")
        let preserved = try object(store.ruleState(groupID:"m"))["$vaultTime"] as! [String:Any]
        let preservedTimer = (preserved["objects"] as! [String:[String:Any]])["clock"]!
        try check(preservedTimer["generation"] as? Int == 1 && preserved["detachedReceipt"] != nil,"disabled native member saves the final shared timer before unlink")
        // The ordinary preflight runs before dispatch, even for disabled rules.
        // It must not consume the durable handover without updating this engine.
        try RuleTimeContextDelivery.refresh(groupID:"m",runtime:runtime) {
            let savedSeed = try object(store.ruleState(groupID:"m"))["$vaultTime"] as! [String:Any]
            let frame = hub.syncRuleTime(groupID:"m",seed:savedSeed,commands:[])
            if frame["detached"] as? Bool == true, let final = frame["state"] as? [String:Any] {
                try store.commitRuleTimeHandover(groupID:"m",expected:savedSeed,namespace:final)
            }
            return frame
        }
        let afterHandover = try object(store.ruleState(groupID:"m"))["$vaultTime"] as! [String:Any]
        try check(afterHandover["detachedReceipt"] == nil,"native preflight durably acknowledges the final handover")
        try RuleTimeContextDelivery.refresh(groupID:"m",runtime:runtime) {
            hub.syncRuleTime(groupID:"m",seed:afterHandover,commands:[])
        }
        runtime.suppress(groupID:"m",false)
        let localTick = try runtime.dispatch(type:"tick",data:[:],groupID:"m")
        let localState = try object(localTick.states["m"]!)
        let localTime = localState["$vaultTime"] as! [String:Any]
        let localBudget = (localTime["objects"] as! [String:[String:Any]])["budget"]!
        try check(localTime["scope"] is NSNull && (localState["budget"] as? [String:Any])?["ready"] as? Bool == true,"live native engine becomes locally available after preflight consumes unlink")
        try check(localBudget["websites"] as? [String] == [] && localBudget["apps"] as? [String] == ["org.example.game"] && ((localTime["objects"] as? [String:[String:Any]])?["clock"]?["generation"] as? Int) == 1,"native handover restores own targets and preserves the final timer generation")
        let failedDeliveryRuntime = try RuleRuntime()
        _ = try failedDeliveryRuntime.load(groupID:"m",source:source,stateJSON:load.states["m"]!)
        try failedDeliveryRuntime.setTimeContext(groupID:"m",contextJSON:String(decoding:try JSONSerialization.data(withJSONObject:mutation),as:UTF8.self))
        var discardedStaleEngine = false
        do {
            try RuleTimeContextDelivery.refresh(groupID:"m",runtime:failedDeliveryRuntime,deliveryFailed:{
                discardedStaleEngine = true; failedDeliveryRuntime.unload(groupID:"m")
            }) { ["linked":false] }
            throw Failure(description:"stale shared context unexpectedly accepted plain unlink")
        } catch RuleRuntime.RuleRuntimeError.failed(_) { }
        try check(discardedStaleEngine,"failed context delivery discards the stale engine after saved unlink")
        let recovered = try failedDeliveryRuntime.load(groupID:"m",source:source,stateJSON:store.ruleState(groupID:"m"))
        try check(recovered.ok,"ordinary reload accepts the already-saved final handover after delivery failure")
        let recoveredTick = try failedDeliveryRuntime.dispatch(type:"tick",data:[:],groupID:"m")
        let recoveredState = try object(recoveredTick.states["m"]!)
        try check((recoveredState["budget"] as? [String:Any])?["ready"] as? Bool == true && ((recoveredState["$vaultTime"] as? [String:Any])?["scope"] is NSNull),"reloaded member recovers local availability without replaying the failed event")
        var unloadedRefresh = 0
        try RuleTimeContextDelivery.refresh(groupID:"unloaded",runtime:nil) {
            unloadedRefresh += 1; return ["linked":false]
        }
        try check(unloadedRefresh == 1,"unloaded custom members still advance their hub handover")
        var stale = seed; stale["scope"] = cluster
        let handover = hub.syncRuleTime(program:"chrome",groupID:"c",clusterID:cluster,seed:stale,commands:[reset])
        let transferred = handover["state"] as! [String:Any]
        try check(handover["detached"] as? Bool == true && (transferred["pending"] as? [Any])?.isEmpty == true,"offline member receives a final snapshot and stale controls are discarded")
        let lostReply = hub.syncRuleTime(program:"chrome",groupID:"c",clusterID:cluster,seed:stale,commands:[])
        try check(WebStoreDocument.canonicalJSON((lostReply["state"] as? [String:Any])?["detachedReceipt"]) == WebStoreDocument.canonicalJSON(transferred["detachedReceipt"]),"lost transfer replies retain a stable retry receipt")
        let restarted = ConnectionHub(registryDefaults:defaults); restarted.hostingLocalHub = true; restarted.restoreClustersLocked()
        let again = restarted.syncRuleTime(program:"chrome",groupID:"c",clusterID:cluster,seed:stale,commands:[])
        try check(again["detached"] as? Bool == true,"final offline snapshot survives a native hub restart")
        var localAfterTransfer = transferred
        var localObjects = localAfterTransfer["objects"] as! [String:[String:Any]]
        localObjects["clock"]?["generation"] = 7; localAfterTransfer["objects"] = localObjects
        let acknowledged = restarted.syncRuleTime(program:"chrome",groupID:"c",seed:localAfterTransfer,commands:[])
        let acknowledgedState = acknowledged["state"] as! [String:Any]
        try check(((acknowledgedState["objects"] as? [String:[String:Any]])?["clock"]?["generation"] as? Int) == 7 && acknowledgedState["detachedReceipt"] == nil,"handover acknowledgment never overwrites subsequent local timer controls")
        _ = restarted.syncRuleTime(groupID:"m",seed:preserved,commands:[])
        try check(restarted.activeClusterCount() == 0,"both persisted handovers can retire their retained records")

        restarted.setRoster(program:"macapp",groups:[["id":"m","name":"Mac","timeState":seed]])
        restarted.setRoster(program:"chrome",groups:[["id":"c","name":"Chrome","timeState":seed]])
        try check(restarted.linkGroups(program:"macapp",groupId:"m",targetProgram:"chrome",targetGroupId:"c") == nil,"new link admits members after earlier handover")
        _ = restarted.syncRuleTime(groupID:"m",seed:seed,commands:[])
        let newLink = restarted.syncRuleTime(program:"chrome",groupID:"c",seed:seed,commands:[])
        let oldLinkID = newLink["clusterId"] as! String
        try check(restarted.unlinkGroup(program:"chrome",groupId:"c") == nil,"first offline handover retained")
        try check(restarted.linkGroups(program:"macapp",groupId:"m",targetProgram:"chrome",targetGroupId:"c") == nil,"offline member can be relinked before returning")
        let secondLinkID = (try JSONSerialization.jsonObject(with:Data(restarted.clustersJSON().utf8)) as! [String:Any])["clusters"] as! [[String:Any]]
        let newestID = secondLinkID[0]["id"] as! String
        try check(restarted.unlinkGroup(program:"chrome",groupId:"c") == nil,"second offline handover retained")
        let ordered = restarted.syncRuleTime(program:"chrome",groupID:"c",clusterID:newestID,seed:seed,commands:[])
        try check(ordered["clusterId"] as? String == oldLinkID && ordered["handoverPending"] as? Bool == true,"oldest pending handover precedes a requested newer snapshot")
        let oldAck = restarted.syncRuleTime(program:"chrome",groupID:"c",seed:ordered["state"] as? [String:Any],commands:[])
        try check((oldAck["state"] as? [String:Any])?["detachedReceipt"] == nil && oldAck["handoverPending"] as? Bool == true,"old transfer is acknowledged while newer handover remains unavailable")
        let newest = restarted.syncRuleTime(program:"chrome",groupID:"c",seed:oldAck["state"] as? [String:Any],commands:[])
        try check(newest["clusterId"] as? String == newestID,"next transfer cannot revert to an older link")
        _ = restarted.syncRuleTime(program:"chrome",groupID:"c",seed:newest["state"] as? [String:Any],commands:[])
        // Report a real API-level write refusal without broadcasting unlink success.
        let failureHub = ConnectionHub(registryDefaults:defaults); failureHub.hostingLocalHub = true
        failureHub.setRoster(program:"chrome",groups:[["id":"x","name":"X","timeState":seed]])
        failureHub.setRoster(program:"safari",groups:[["id":"y","name":"Y","timeState":seed]])
        try check(failureHub.linkGroups(program:"chrome",groupId:"x",targetProgram:"safari",targetGroupId:"y") == nil,"storage failure fixture linked")
        _ = failureHub.syncRuleTime(program:"chrome",groupID:"x",seed:seed,commands:[])
        _ = failureHub.syncRuleTime(program:"safari",groupID:"y",seed:seed,commands:[])
        let beforeFailedUnlink = defaults.data(forKey:"ConnectionHub.clusters.v2")
        defaults.refuseWrites = true
        let refusal = failureHub.unlinkGroup(program:"chrome",groupId:"x")
        try check(refusal == "local-storage-unavailable" && failureHub.activeClusterCount() == 1 && defaults.data(forKey:"ConnectionHub.clusters.v2") == beforeFailedUnlink,"failed registry save preserves membership and refuses unlink success")
        defaults.refuseWrites = false
        let failedLinkHub = ConnectionHub(registryDefaults:defaults); failedLinkHub.hostingLocalHub = true
        failedLinkHub.setRoster(program:"chrome",groups:[["id":"new-x","name":"X","timeState":seed]])
        failedLinkHub.setRoster(program:"safari",groups:[["id":"new-y","name":"Y","timeState":seed]])
        defaults.refuseWrites = true
        let failedLink = failedLinkHub.linkGroups(program:"chrome",groupId:"new-x",targetProgram:"safari",targetGroupId:"new-y")
        try check(failedLink == "local-storage-unavailable" && failedLinkHub.activeClusterCount() == 0 && defaults.data(forKey:"ConnectionHub.clusters.v2") == beforeFailedUnlink,"failed registry save cannot announce a new link or overwrite the old registry")
        defaults.refuseWrites = false

        let key = "ConnectionHub.clusters.v2"
        let bytes = defaults.data(forKey:key)!
        var newer = try JSONSerialization.jsonObject(with:bytes) as! [String:Any]
        var metadata = newer["storageMetadata"] as! [String:Any]; metadata["schemaVersion"] = 999; newer["storageMetadata"] = metadata
        let newerBytes = try JSONSerialization.data(withJSONObject:newer)
        defaults.set(newerBytes,forKey:key)
        let unsupported = ConnectionHub(registryDefaults:defaults); unsupported.hostingLocalHub = true; unsupported.restoreClustersLocked()
        let answer = unsupported.syncRuleTime(groupID:"m",seed:seed.merging(["scope":cluster]){ _, new in new },commands:[])
        try check(answer["ready"] as? Bool == false && defaults.data(forKey:key) == newerBytes,"newer registry remains unchanged and cannot grant a local allowance")
        try NamedBrowserOverlapChecks.run(report)
    }
}

private enum NamedBrowserOverlapChecks {
 struct Failure:Error,CustomStringConvertible {let description:String}
 static func run(_ report:(String)->Void)throws {
  func need(_ yes:Bool,_ label:String)throws {guard yes else{throw Failure(description:label)};report(label)}
  func object(_ text:String)throws->[String:Any]{try JSONSerialization.jsonObject(with:Data(text.utf8)) as! [String:Any]}
  let actualName="Agentic.NamedBrowserActual."+UUID().uuidString
  let actualDefaults=UserDefaults(suiteName:actualName)!
  defer {actualDefaults.removePersistentDomain(forName:actualName)}
  let dir=FileManager.default.temporaryDirectory.appendingPathComponent("named-browser-overlap-"+UUID().uuidString)
  defer {try? FileManager.default.removeItem(at:dir)}
  let store=BlockerWebStore(shared:SharedAppGroupStore(baseDirectory:dir))
  store.save(rawStore:["blockedGroups":[["id":"m","name":"Mac","groupType":"custom","enabled":true]],"cbRuleState":[:]])
  let native=try RuleRuntime(), browser=try RuleRuntime()
  let source=#"(on,v)=>{const p=v.rolling('pool',{windowMs:20000,limitMs:3000});p.assign({apps:['com.google.Chrome']});const s=v.rolling('separate',{windowMs:20000,limitMs:3000});s.assign({apps:['com.apple.calculator']});on('tick',()=>{v.state.pool=p.snapshot();v.state.separate=s.snapshot();});}"#
  let browserSource=source.replacingOccurrences(of:"apps:['com.google.Chrome']",with:"websites:['example.com']").replacingOccurrences(of:"apps:['com.apple.calculator']",with:"websites:['example.org']")
  let nr=try native.load(groupID:"m",source:source,stateJSON:"{}"),br=try browser.load(groupID:"c",source:browserSource,stateJSON:"{}")
  guard nr.ok,br.ok else{throw Failure(description:"Named overlap source failed to load")}
  let ns=try object(nr.states["m"]!)["$vaultTime"] as! [String:Any],bs=try object(br.states["c"]!)["$vaultTime"] as! [String:Any]
  let hub=ConnectionHub(registryDefaults:actualDefaults);hub.hostingLocalHub=true;hub.localWebStore=store
  hub.setRoster(program:"macapp",groups:[["id":"m","name":"Mac","groupType":"custom","timeState":ns]])
  hub.setRoster(program:"chrome",groups:[["id":"c","name":"Chrome","groupType":"custom","timeState":bs]])
  guard hub.linkGroups(program:"macapp",groupId:"m",targetProgram:"chrome",targetGroupId:"c")==nil else{throw Failure(description:"Named overlap link failed")}
  hub.applySync(program:"macapp",groupId:"m",contribution:["scopes":[["surface":"apps","apps":[["id":"com.google.Chrome"]],"action":"block"]]],ts:0)
  hub.applySync(program:"chrome",groupId:"c",contribution:["scopes":[["surface":"site","sites":["example.com"],"action":"block"]]],ts:0)
  _=hub.syncRuleTime(groupID:"m",seed:ns,commands:[])
  let ready=hub.syncRuleTime(program:"chrome",groupID:"c",seed:bs,commands:[])
  guard ready["ready"] as? Bool==true,let cluster=ready["clusterId"] as? String else{throw Failure(description:"Named overlap fresh seeds not ready")}
  // Actual hub wall time remains unchanged. Only this pure test waits for a
  // four-second history interval after the fresh seeds' reset anchors.
  Thread.sleep(forTimeInterval:4.1)
  let at=(Date().timeIntervalSince1970*1000).rounded(.down)
  _=hub.syncRuleTime(groupID:"m",clusterID:cluster,seed:ns,commands:[],usage:["type":"tick","now":at-1000,"data":["usageAppId":"com.google.Chrome","elapsedMs":3000]])
  let shared=hub.syncRuleTime(program:"chrome",groupID:"c",clusterID:cluster,seed:bs,commands:[],usage:["type":"visible","now":at,"data":["url":"https://example.com/","elapsedMs":3000]])
  guard shared["ready"] as? Bool==true,let state=shared["state"] as? [String:Any] else{throw Failure(description:"Named overlap usage refused")}
  func used(_ frame:[String:Any],_ time:Double)throws->[(Double,Double)] {
   var results:[(Double,Double)]=[]
   let data=try JSONSerialization.data(withJSONObject:frame),text=String(decoding:data,as:UTF8.self)
   for (runtime,id) in [(native,"m"),(browser,"c")] {
    try runtime.setTimeContext(groupID:id,contextJSON:text)
    let tick=try runtime.dispatch(type:"tick",data:[:],groupID:id,now:Date(timeIntervalSince1970:time/1000))
    let saved=try object(tick.states[id]!),p=saved["pool"] as! [String:Any],s=saved["separate"] as! [String:Any]
    guard p["ready"] as? Bool==true,s["ready"] as? Bool==true else{throw Failure(description:"Named overlap snapshot unavailable")}
    results.append(((p["usedMs"] as! NSNumber).doubleValue,(s["usedMs"] as! NSNumber).doubleValue))
   }
   return results
  }
  try need(try used(shared,at).allSatisfy{$0.0==4000 && $0.1==0},"actual native JSC/hub Chrome-App plus partially overlapping website intervals union once; neither contribution is dropped and separate remains zero")
  func atTime(_ time:Double)throws->[String:Any] {
   guard let result=GroupActionsRuntime.shared.call("reduceTime",[state,["member":"macapp/m","commands":[],"nowMs":time]],module:"RuleCore") as? [String:Any],result["ok"] as? Bool==true,let reduced=result["state"] as? [String:Any] else{throw Failure(description:"Named overlap explicit timestamp reduction refused")}
   return ["linked":true,"ready":true,"clusterId":cluster,"state":reduced]
  }
  try need(try used(atTime(at+19999),at+19999).allSatisfy{$0.0==1 && $0.1==0},"actual JSC named interval retains exactly one millisecond before expiry")
  try need(try used(atTime(at+20000),at+20000).allSatisfy{$0.0==0 && $0.1==0},"actual JSC named interval expires exactly at original twenty-second boundary")
 }
}
#endif
