import XCTest
import Network
@testable import MacBlockerAppFeature
import MacBlockerCore

@MainActor
final class RuleAIHubTests: XCTestCase {
    func testSharedRulePromptAndContextValidateInNativeJavaScriptCore() {
        let selection: [String:Any] = ["providerModel":"api:key:model","accountID":"","reasoningEffort":"medium",
                                       "dailyRequestLimit":NSNull(),"prompt":"标签说明 🎮","context":"背景材料"]
        let saved = GroupActionsRuntime.shared.call("normalizeRuleAI",[selection]) as? [String:Any]
        XCTAssertEqual(saved?["prompt"] as? String,"标签说明 🎮")
        XCTAssertEqual(saved?["context"] as? String,"背景材料")
        var oversized = selection
        oversized["context"] = String(repeating:"界",count:5_334)
        XCTAssertNil(GroupActionsRuntime.shared.call("normalizeRuleAI",[oversized]))
    }
    private func peer(_ hub: ConnectionHub, _ program: String, admitted: Bool = true) -> NWConnection {
        let connection = NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
        hub.registerPendingPeer(connection, challenge: "fixture")
        if admitted { XCTAssertNil(hub.admitAuthenticatedPeer(connection, program: program)) }
        return connection
    }
    private func send(_ hub: ConnectionHub, _ peer: NWConnection, _ id: String, operation: String = "generate", payload: String = "{}") throws {
        hub.handleIncoming(peer, key: ObjectIdentifier(peer), data: try JSONSerialization.data(withJSONObject: ["kind":"rule-ai-request","requestID":id,"operation":operation,"groupId":"g","payload":payload]))
    }
    func testRoutingRequiresBrowserAuthenticationAndKeepsRequestIdentity() async throws {
        let queue = DispatchQueue(label: "test.rule-ai.routing")
        var frames = [Data](), calls = [String]()
        let hub = ConnectionHub(testOutboundQueue: queue) { frames.append($0) }
        hub.ruleAIRequest = { operation, program, group, _ in
            calls.append("\(operation):\(program):\(group)"); return ["ok":true,"text":"fixture"]
        }
        let chrome = peer(hub,"chrome"), classifier = peer(hub,"classifier"), pending = peer(hub,"edge",admitted:false)
        queue.sync {}; frames.removeAll()
        try send(hub,pending,"unauthenticated")
        try send(hub,classifier,"wrong-role")
        try send(hub,chrome,"bad-operation",operation:"unknown")
        try send(hub,chrome,"too-large",payload:String(repeating:"x",count:48_001))
        try send(hub,chrome,"correlated")
        for _ in 0..<100 where calls.isEmpty { await Task.yield() }
        queue.sync {}
        XCTAssertEqual(calls,["generate:chrome:g"])
        let replies = frames.compactMap { try? JSONSerialization.jsonObject(with:$0) as? [String:Any] }.filter { $0["kind"] as? String == "rule-ai-response" }
        XCTAssertEqual(replies.count,1); XCTAssertEqual(replies.first?["requestID"] as? String,"correlated")
        XCTAssertEqual((replies.first?["body"] as? [String:Any])?["text"] as? String,"fixture")
    }
    func testRetiredPeerCannotReceiveAnInflightReply() async throws {
        let queue = DispatchQueue(label:"test.rule-ai.retired")
        var frames = [Data](), continuation: CheckedContinuation<[String:Any],Never>?
        let hub = ConnectionHub(testOutboundQueue:queue) { frames.append($0) }
        hub.ruleAIRequest = { _,_,_,_ in await withCheckedContinuation { continuation=$0 } }
        let chrome = peer(hub,"chrome")
        try send(hub,chrome,"old")
        for _ in 0..<100 where continuation == nil { await Task.yield() }
        let waiting = try XCTUnwrap(continuation)
        // A new pending identity on the same transport retires the old peer.
        hub.registerPendingPeer(chrome,challenge:"replacement")
        queue.sync {};frames.removeAll()
        waiting.resume(returning:["ok":true,"text":"late"])
        for _ in 0..<20 { await Task.yield() };queue.sync {}
        XCTAssertFalse(frames.contains { (try? JSONSerialization.jsonObject(with:$0) as? [String:Any])?["kind"] as? String == "rule-ai-response" })
    }
    func testLinkedSelectionIsAuthoritativeIncludingExplicitRemoval() throws {
        let suite = "rule-ai-"+UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        let hub = ConnectionHub(registryDefaults:defaults)
        let local: [String:Any] = ["id":"m","groupType":"custom","enabled":true,"ruleAI":["providerModel":"api:old:model","accountID":"","reasoningEffort":"default"]]
        let browser: [String:Any] = ["id":"b","groupType":"custom","enabled":true,"ruleAI":["providerModel":"api:new:model","accountID":"","reasoningEffort":"default"]]
        XCTAssertNil(hub.setRoster(program:"macapp",groups:[local]));XCTAssertNil(hub.setRoster(program:"chrome",groups:[browser]))
        XCTAssertNil(hub.linkGroups(program:"chrome",groupId:"b",targetProgram:"macapp",targetGroupId:"m"))
        hub.applySync(program:"chrome",groupId:"b",contribution:["scalars":["groupType":"custom","enabled":true,"ruleAI":["providerModel":"api:new:model","accountID":"","reasoningEffort":"default","dailyRequestLimit":7]]],ts:100)
        let native = try XCTUnwrap(hub.ruleAIContext(program:"macapp",groupID:"m"))
        let web = try XCTUnwrap(hub.ruleAIContext(program:"chrome",groupID:"b"))
        XCTAssertEqual(native.configuration,web.configuration);XCTAssertEqual(native.configuration.dailyRequestLimit,7)
        XCTAssertEqual(native.members,["chrome:b","macapp:m"])
        hub.applySync(program:"chrome",groupId:"b",contribution:["scalars":["ruleAI":NSNull()]],ts:200)
        XCTAssertNil(hub.ruleAIContext(program:"macapp",groupID:"m"));XCTAssertNil(hub.ruleAIContext(program:"chrome",groupID:"b"))
        hub.applySync(program:"chrome",groupId:"b",contribution:["scalars":["groupType":"custom","enabled":true,"ruleAI":["providerModel":"api:new:model","accountID":"","reasoningEffort":"default","dailyRequestLimit":7]]],ts:300)
        let restored = try XCTUnwrap(hub.ruleAIContext(program:"macapp",groupID:"m"))
        XCTAssertEqual(restored.configuration,native.configuration)
        XCTAssertNotEqual(restored.revision,native.revision,"restoring the same settings cannot revive a pending response")
    }
}
