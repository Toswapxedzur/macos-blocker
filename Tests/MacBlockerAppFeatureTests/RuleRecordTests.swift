#if os(macOS)
import XCTest
import MacBlockerCore
import MacBlockerWebUI

final class RuleRecordTests: XCTestCase {
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
