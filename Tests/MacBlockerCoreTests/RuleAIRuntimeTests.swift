import XCTest
@testable import MacBlockerCore

final class RuleAIRuntimeTests: XCTestCase {
    private let source = #"(on,v)=>{on("panel",()=>{v.state.request=v.ai({prompt:"Summarize",input:{text:"fixture"}});});on("ai",({data})=>{v.state.answer=data.text;v.log(data.ok,data.text);});}"#
    private func firstAction(_ result: RuleRuntime.DispatchResult) throws -> RuleRuntime.Action {
        try XCTUnwrap(result.actions.first, "rule diagnostics: \(result.diagnostics); resource: \(RuntimeResources.url(name: "rule-core", ext: "js")?.path ?? "missing")")
    }
    func testSavedPromptAndContextReachNativeRuleAndInvalidateOldReplies() throws {
        let runtime = try RuleRuntime()
        let code = #"(on,v)=>{on("panel",()=>v.ai({prompt:v.context.ai.prompt,input:{context:v.context.ai.context}}));on("ai",()=>v.log("accepted"));}"#
        XCTAssertTrue(try runtime.load(groupID:"g",source:code,stateJSON:"{}").ok)
        let request = try firstAction(runtime.dispatch(type:"panel",data:[String:Any](),groupID:"g",contextRevision:"one",aiContext:["prompt":"Saved prompt","context":"Saved background"]))
        XCTAssertEqual(request.payload, #"{"prompt":"Saved prompt","input":{"context":"Saved background"}}"#)
        let oldReply: [String:Any] = ["requestId":request.requestId!,"generation":request.generation!,"ok":true,"text":"Old"]
        XCTAssertTrue(try runtime.dispatch(type:"ai",data:oldReply,groupID:"g",contextRevision:"two").logs.isEmpty)
    }
    func testActualJSCActionAndReplyFollowTheOriginalRuleInstance() throws {
        let runtime = try RuleRuntime()
        XCTAssertTrue(try runtime.load(groupID:"g",source:source,stateJSON:"{}").ok)
        let request = try firstAction(runtime.dispatch(type:"panel",data:[String:Any](),groupID:"g"))
        XCTAssertEqual(request.kind,"ai");XCTAssertNotNil(request.generation)
        let reply: [String:Any] = ["requestId":request.requestId!,"generation":request.generation!,"ok":true,"text":"Summary"]
        XCTAssertEqual(try runtime.dispatch(type:"ai",data:reply,groupID:"g").logs.first?.message,"true Summary")
        // Running the same text creates a fresh instance and cannot reuse a reply.
        XCTAssertTrue(try runtime.load(groupID:"g",source:source,stateJSON:"{}").ok)
        let stale = try runtime.dispatch(type:"ai",data:reply,groupID:"g")
        XCTAssertTrue(stale.logs.isEmpty);XCTAssertTrue(stale.states.isEmpty)
        let next = try firstAction(runtime.dispatch(type:"panel",data:[String:Any](),groupID:"g"))
        runtime.suppress(groupID:"g",true);runtime.suppress(groupID:"g",false)
        let disabled: [String:Any] = ["requestId":next.requestId!,"generation":next.generation!,"ok":true,"text":"Old reply"]
        XCTAssertTrue(try runtime.dispatch(type:"ai",data:disabled,groupID:"g").logs.isEmpty)
    }
    func testRegistrationAndPerCallProviderOverridesAreRefused() throws {
        let runtime=try RuleRuntime()
        XCTAssertFalse(try runtime.load(groupID:"g",source:#"(on,v)=>{v.ai({prompt:"run now"});}"#,stateJSON:"{}").ok)
        XCTAssertTrue(try runtime.load(groupID:"g",source:#"(on,v)=>{on("panel",()=>v.ai({prompt:"x",model:"override"}));}"#,stateJSON:"{}").ok)
        let result=try runtime.dispatch(type:"panel",data:[String:Any](),groupID:"g")
        XCTAssertTrue(result.actions.isEmpty);XCTAssertEqual(result.diagnostics.count,1)
    }
}
