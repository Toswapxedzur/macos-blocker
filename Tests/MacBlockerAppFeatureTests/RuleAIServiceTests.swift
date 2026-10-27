#if os(macOS)
import XCTest
import MacBlockerCore
import VaultClassifierCore
@testable import MacBlockerAppFeature

@MainActor
final class RuleAIServiceTests: XCTestCase {
    func testTimeoutCancelsProviderAndReleasesTheConcurrencySlot() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let context=RuleAIContext(configuration:.init(providerModel:"api:fixture:model"),members:["mac:a"],revision:"one")
        var slow=true,cancelled=false
        let service=RuleAIService(usage:RuleAIUsage(url:directory.appendingPathComponent("usage.json")),context:{_,_ in context},models:{[]},validate:{_ in true},generate:{_,_ in
            if slow {do {try await Task.sleep(nanoseconds:10_000_000_000)} catch {cancelled=true;throw error}}
            return try RuleAIReply(text:"ready")
        },timeoutNanoseconds:10_000_000)
        let first=await service.request(program:"mac",groupID:"a",payload:#"{"prompt":"x"}"#)
        XCTAssertEqual(first["error"] as? String,RuleAIError.timeout.rawValue);XCTAssertTrue(cancelled)
        slow=false
        let second=await service.request(program:"mac",groupID:"a",payload:#"{"prompt":"x"}"#)
        XCTAssertEqual(second["ok"] as? Bool,true)
    }
    func testOnlyTwoCallsCanBeActiveAndBusyDoesNotReserveAllowance() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let url=directory.appendingPathComponent("usage.json")
        let context=RuleAIContext(configuration:.init(providerModel:"api:fixture:model",dailyRequestLimit:2),members:["mac:a"],revision:"one")
        var waits=[CheckedContinuation<RuleAIReply,Error>]()
        let service=RuleAIService(usage:RuleAIUsage(url:url),context:{_,_ in context},models:{[]},validate:{_ in true},generate:{_,_ in try await withCheckedThrowingContinuation {waits.append($0)}})
        let first=Task {await service.request(program:"mac",groupID:"a",payload:#"{"prompt":"x"}"#)}
        let second=Task {await service.request(program:"mac",groupID:"a",payload:#"{"prompt":"x"}"#)}
        for _ in 0..<100 where waits.count < 2 {await Task.yield()}
        XCTAssertEqual(waits.count,2)
        let busy=await service.request(program:"mac",groupID:"a",payload:#"{"prompt":"x"}"#)
        XCTAssertEqual(busy["error"] as? String,RuleAIError.busy.rawValue)
        for continuation in waits {continuation.resume(returning:try RuleAIReply(text:"ok"))}
        let replies=await [first.value,second.value];XCTAssertTrue(replies.allSatisfy {$0["ok"] as? Bool == true})
        let raw=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any])
        XCTAssertEqual((raw["reservations"] as? [[String]])?.count,2)
    }
    func testChangedConfigurationDiscardsReplyAndSharedAllowanceCountsFailure() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        var context=RuleAIContext(configuration:.init(providerModel:"api:fixture:model",dailyRequestLimit:1),members:["mac:a","chrome:b"],revision:"first")
        var continuation: CheckedContinuation<RuleAIReply,Error>?
        let service=RuleAIService(usage:RuleAIUsage(url:directory.appendingPathComponent("usage.json")),context:{_,_ in context},models:{[]},validate:{_ in true},generate:{_,_ in try await withCheckedThrowingContinuation {continuation=$0}})
        let first=Task {await service.request(program:"mac",groupID:"a",payload:#"{"prompt":"summarize"}"#)}
        for _ in 0..<100 where continuation == nil {await Task.yield()}
        let pending=try XCTUnwrap(continuation)
        context.revision="replacement"
        pending.resume(returning:try RuleAIReply(text:"must not be delivered"))
        let discarded=await first.value;XCTAssertEqual(discarded["ok"] as? Bool,false)
        let second=await service.request(program:"chrome",groupID:"b",payload:#"{"prompt":"again"}"#)
        XCTAssertEqual(second["error"] as? String,RuleAIError.usageLimit.rawValue)
    }
    func testInvalidInputAndConfigurationDoNotReserveUsageOrCallProvider() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let url=directory.appendingPathComponent("usage.json")
        var calls=0
        let service=RuleAIService(usage:RuleAIUsage(url:url),context:{_,_ in nil},models:{[]},validate:{_ in false},generate:{_,_ in calls += 1;return try RuleAIReply(text:"unreachable")})
        let invalid=await service.request(program:"browser",groupID:"g",payload:#"{"prompt":"x","model":"override"}"#)
        XCTAssertEqual(invalid["error"] as? String,RuleAIError.invalidInput.rawValue)
        let missing=await service.request(program:"browser",groupID:"g",payload:#"{"prompt":"x"}"#)
        XCTAssertEqual(missing["error"] as? String,RuleAIError.invalidConfiguration.rawValue)
        XCTAssertEqual(calls,0);XCTAssertFalse(FileManager.default.fileExists(atPath:url.path))
        service.shutdown();XCTAssertEqual(service.modelOptions()["ok"] as? Bool,false)
    }
}
#endif
