#if os(macOS)
import XCTest
@testable import MacBlockerAppFeature
import MacBlockerCore
import MacBlockerWebUI

final class RuleRecordTests: XCTestCase {
    func testNativeContextRevisionIsStableAndChangesWithConnection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("record-context-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let shared = SharedAppGroupStore(baseDirectory: directory)
        let store = BlockerWebStore(shared: shared)
        store.save(rawStore:["blockedGroups":[["id":"g","groupType":"custom","enabled":true,"ruleAI":["providerModel":"one"]]]])
        let first = store.ruleContextRevision(groupID:"g")
        XCTAssertEqual(first, BlockerWebStore(shared: shared).ruleContextRevision(groupID:"g"))
        store.save(rawStore:["blockedGroups":[["id":"g","groupType":"custom","enabled":true,"ruleAI":["providerModel":"two"]]]])
        XCTAssertNotEqual(first, store.ruleContextRevision(groupID:"g"))
    }
    @MainActor
    func testNativeBridgeDeliversUserOriginAndRecordReply() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("record-bridge-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BlockerWebStore(shared: SharedAppGroupStore(baseDirectory: directory))
        let group: [String: Any] = ["id":"g", "name":"Rule", "groupType":"custom", "enabled":false,
                                    "scopes":[["surface":"apps", "apps":[]]]]
        store.save(rawStore: ["blockedGroups": [group]])
        let bridge = MacEnforcementBridge(webStore: store)
        let source = #"(on,v)=>{on('snooze',ev=>{v.state.snoozeOrigin=ev.origin;v.store({op:'put',key:'one',value:{note:'saved'},ifRevision:null});});on('panel',ev=>{v.state.panelOrigin=ev.origin;});on('record',ev=>{v.state.storeOK=ev.data.ok;v.state.saved=ev.data.record?.value?.note;});}"#
        XCTAssertEqual(bridge.runRule(groupID: "g", source: source)["ok"] as? Bool, true)
        bridge.fireSnoozePress(groupID: "g")
        bridge.firePanelEvent(groupID: "g", data: ["panelId":"p","controlId":"b","eventName":"click"])
        for _ in 0..<50 {
            let state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(store.ruleState(groupID:"g").utf8)) as? [String: Any])
            if state["saved"] as? String == "saved" {
                XCTAssertEqual(state["snoozeOrigin"] as? String,"user")
                XCTAssertEqual(state["panelOrigin"] as? String,"user")
                XCTAssertEqual(state["storeOK"] as? Bool,true)
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Native record reply did not reach the active rule")
    }
    func testNativeRecordsUseTheSharedTransactionsAndPersistSeparatelyFromRuleState() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("records-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let shared = SharedAppGroupStore(baseDirectory: directory), store = BlockerWebStore(shared: shared)
        store.save(rawStore: ["blockedGroups": [["id":"a","groupType":"custom","enabled":true], ["id":"b","groupType":"custom","enabled":true]], "cbRuleState":["a":["keep":true]]])
        func call(_ group: String, _ data: [String:Any]) throws -> [String:Any] {
            let text = String(decoding: try JSONSerialization.data(withJSONObject: data), as: UTF8.self)
            return try store.ruleRecordRequest(groupID: group, payload: text)
        }
        let first = try XCTUnwrap(call("a", ["op":"put","key":"item","value":["answer":"auto"],"ifRevision":NSNull()])["record"] as? [String:Any])
        XCTAssertTrue(try call("b", ["op":"get","key":"item"])["record"] is NSNull)
        _ = try call("a", ["op":"put","key":"item","value":["answer":"user"]])
        XCTAssertEqual(try call("a", ["op":"put","key":"item","value":["answer":"late"],"ifRevision":first["revision"]!])["error"] as? String,"store-conflict")
        let reopened = BlockerWebStore(shared: shared)
        let retained = try reopened.ruleRecordRequest(groupID:"a",payload:#"{"op":"get","key":"item"}"#)
        XCTAssertEqual(((retained["record"] as? [String:Any])?["value"] as? [String:String])?["answer"],"user")
        let raw = try XCTUnwrap(store.loadRawJSON())
        XCTAssertTrue(raw.contains("\"keep\":true"))
        _ = try call("a", ["op":"clear"])
        XCTAssertTrue(try call("a", ["op":"get","key":"item"])["record"] is NSNull)
    }
    func testMalformedRecordDocumentsStayIntactAndOrdinaryStateCanStillBeSaved() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("records-invalid-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BlockerWebStore(shared: SharedAppGroupStore(baseDirectory: directory))
        store.save(rawStore:["blockedGroups":[["id":"a","groupType":"custom","enabled":true]],"cbRuleRecords":["version":999,"groups":["keep":"future"]]])
        XCTAssertThrowsError(try store.ruleRecordRequest(groupID:"a",payload:#"{"op":"put","key":"x","value":1}"#))
        try store.commitRuleDispatch(["a":#"{"ordinary":true}"#])
        let raw = try XCTUnwrap(store.loadRawJSON())
        XCTAssertTrue(raw.contains("future"));XCTAssertTrue(raw.contains("ordinary"))
    }
    func testRuntimeRequestTokensAndContextRevisionsRejectObsoleteReplies() throws {
        let runtime = try RuleRuntime()
        _ = try runtime.load(groupID:"a",source:#"(on,v)=>{on('tick',()=>v.store({op:'get',key:'item'}));on('record',e=>v.log(e.data.ok));}"#,stateJSON:"{}")
        let request = try XCTUnwrap(runtime.dispatch(type:"tick",data:[String:Any](),groupID:"a",contextRevision:"one").actions.first)
        let token = try XCTUnwrap(request.generation)
        XCTAssertTrue(runtime.acceptsRequest(groupID:"a",generation:token))
        _ = try runtime.dispatch(type:"tick",data:[String:Any](),groupID:"a",contextRevision:"two")
        XCTAssertFalse(runtime.acceptsRequest(groupID:"a",generation:token))
        XCTAssertTrue(try runtime.dispatch(type:"record",data:["ok":true,"generation":token],groupID:"a",contextRevision:"two").logs.isEmpty)
    }
}
#endif
