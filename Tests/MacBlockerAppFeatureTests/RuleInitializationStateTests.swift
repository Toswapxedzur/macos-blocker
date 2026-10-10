#if os(macOS)
import XCTest
@testable import MacBlockerAppFeature
import MacBlockerCore
import MacBlockerWebUI

@MainActor
final class RuleInitializationStateTests: XCTestCase {
    private let source = #"(on,v)=>{v.state.runs=(v.state.runs||0)+1;on("snooze",()=>{v.state.events=(v.state.events||0)+1;});}"#
    private func fixture() -> (MacEnforcementBridge, BlockerWebStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rule-init-\(UUID().uuidString)")
        let store = BlockerWebStore(shared: SharedAppGroupStore(baseDirectory: directory))
        store.save(rawStore: ["blockedGroups": [["id":"g", "name":"Rule", "groupType":"custom", "enabled":false, "scopes":[["surface":"apps", "apps":[]]]]]])
        return (MacEnforcementBridge(webStore: store), store, directory)
    }
    private func object(_ store: BlockerWebStore) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(store.loadRawJSON()).utf8)) as? [String: Any])
    }
    private func state(_ store: BlockerWebStore) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(store.ruleState(groupID:"g").utf8)) as? [String: Any])
    }
    func testTwoRunsBeforeAnyEventPersistInitializationAndSource() throws {
        let (bridge,store,directory)=fixture(); defer { try? FileManager.default.removeItem(at:directory) }
        XCTAssertEqual(bridge.runRule(groupID:"g",source:source)["ok"] as? Bool,true)
        XCTAssertEqual(try state(store)["runs"] as? Int,1)
        XCTAssertEqual(bridge.runRule(groupID:"g",source:source)["ok"] as? Bool,true)
        XCTAssertEqual(try state(store)["runs"] as? Int,2)
        let group=try XCTUnwrap((try object(store)["blockedGroups"] as? [[String:Any]])?.first)
        XCTAssertEqual(group["activeEventSource"] as? String,source)
        XCTAssertEqual(group["enabled"] as? Bool,true)
        bridge.fireSnoozePress(groupID:"g")
        XCTAssertEqual(try state(store)["runs"] as? Int,2)
        XCTAssertEqual(try state(store)["events"] as? Int,1)
    }
    func testNoHandlerStateSurvivesAnotherRunAndEmptySource() throws {
        let (bridge,store,directory)=fixture(); defer { try? FileManager.default.removeItem(at:directory) }
        let initialization=#"(on,v)=>{v.state.error="user data";v.state.n=(v.state.n||0)+1;}"#
        XCTAssertEqual(bridge.runRule(groupID:"g",source:initialization)["ok"] as? Bool,true)
        XCTAssertEqual(try state(store)["n"] as? Int,1)
        XCTAssertEqual(bridge.runRule(groupID:"g",source:initialization)["ok"] as? Bool,true)
        XCTAssertEqual(try state(store)["n"] as? Int,2)
        XCTAssertEqual(try state(store)["error"] as? String,"user data")
        XCTAssertEqual(bridge.runRule(groupID:"g",source:"")["ok"] as? Bool,true)
        XCTAssertEqual(try state(store)["n"] as? Int,2)
    }
    func testEventStateAndNewRuntimeUseThePersistedInitialization() throws {
        let (bridge,store,directory)=fixture(); defer { try? FileManager.default.removeItem(at:directory) }
        _=bridge.runRule(groupID:"g",source:source);bridge.fireSnoozePress(groupID:"g")
        _=bridge.runRule(groupID:"g",source:source);bridge.fireSnoozePress(groupID:"g")
        XCTAssertEqual(try state(store)["runs"] as? Int,2)
        XCTAssertEqual(try state(store)["events"] as? Int,2)
        let reopened=BlockerWebStore(shared:SharedAppGroupStore(baseDirectory:directory))
        let restarted=MacEnforcementBridge(webStore:reopened)
        XCTAssertEqual(restarted.runRule(groupID:"g",source:source)["ok"] as? Bool,true)
        XCTAssertEqual(try state(reopened)["runs"] as? Int,3)
        restarted.fireSnoozePress(groupID:"g")
        XCTAssertEqual(try state(reopened)["events"] as? Int,3)
    }
    func testFailedCompilationRegistrationAndStateValidationPreserveOldRule() throws {
        let (bridge,store,directory)=fixture(); defer { try? FileManager.default.removeItem(at:directory) }
        _=bridge.runRule(groupID:"g",source:source)
        let saved=try Data(contentsOf:store.fileURL)
        for rejected in ["(on,v)=>{", #"(on,v)=>{v.state.runs=999;throw Error("reject");}"#, #"(on,v)=>{v.state.cycle=v.state;}"#, #"(on,v)=>{v.state.payload="x".repeat(70000);}"#, #"(on,v)=>{v.state.payload="界".repeat(24000);}"#, #"(on,v)=>{globalThis.__vaultBeforeRuleCommit('{"g":"{\"runs\":999}"}');}"#, #"(on,v)=>{globalThis.__vaultCaptureRuleLoadRecovery(()=>{});}"#] {
            XCTAssertEqual(bridge.runRule(groupID:"g",source:rejected)["ok"] as? Bool,false)
            XCTAssertEqual(try Data(contentsOf:store.fileURL),saved)
        }
        bridge.fireSnoozePress(groupID:"g")
        XCTAssertEqual(try state(store)["runs"] as? Int,1)
        XCTAssertEqual(try state(store)["events"] as? Int,1)
    }
    func testInstrumentedRegistrationDeadlineDoesNotQuarantineOldHealthyRule() throws {
        let (bridge,store,directory)=fixture(); defer { try? FileManager.default.removeItem(at:directory) }
        _=bridge.runRule(groupID:"g",source:source)
        let saved=try Data(contentsOf:store.fileURL)
        let rejected=bridge.runRule(groupID:"g",source:#"(on,v)=>{while(true){v.log("deadline");}}"#)
        XCTAssertEqual(rejected["ok"] as? Bool,false)
        XCTAssertTrue((rejected["error"] as? String)?.contains("while registering") == true)
        XCTAssertEqual(try Data(contentsOf:store.fileURL),saved)
        bridge.fireSnoozePress(groupID:"g")
        XCTAssertEqual(try state(store)["runs"] as? Int,1)
        XCTAssertEqual(try state(store)["events"] as? Int,1)
    }
    func testTrueVmTerminationRetainsSafetyQuarantine() throws {
        let (bridge,store,directory)=fixture(); defer { try? FileManager.default.removeItem(at:directory) }
        _=bridge.runRule(groupID:"g",source:source)
        let saved=try Data(contentsOf:store.fileURL)
        let rejected=bridge.runRule(groupID:"g",source:"(on,v)=>{while(true){}}")
        XCTAssertEqual(rejected["ok"] as? Bool,false)
        XCTAssertEqual(rejected["error"] as? String,"sandbox-timeout")
        XCTAssertEqual(try Data(contentsOf:store.fileURL),saved)
        bridge.fireSnoozePress(groupID:"g")
        XCTAssertNil(try state(store)["events"])
    }
    func testWriteFailurePreservesPreviousWorkingSourceAndState() throws {
        let (bridge,store,directory)=fixture()
        defer { try? FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:directory.path);try? FileManager.default.removeItem(at:directory) }
        _=bridge.runRule(groupID:"g",source:source)
        let saved=try Data(contentsOf:store.fileURL)
        try FileManager.default.setAttributes([.posixPermissions:0o500],ofItemAtPath:directory.path)
        XCTAssertEqual(bridge.runRule(groupID:"g",source:#"(on,v)=>{v.state.runs=999;on("snooze",()=>{v.state.events=999;});}"#)["ok"] as? Bool,false)
        XCTAssertEqual(try Data(contentsOf:store.fileURL),saved)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:directory.path)
        bridge.fireSnoozePress(groupID:"g")
        XCTAssertEqual(try state(store)["runs"] as? Int,1)
        XCTAssertEqual(try state(store)["events"] as? Int,1)
    }
    func testInvalidSavedStorageRefusesRunWithoutReplacingOldRule() throws {
        let (bridge,store,directory)=fixture(); defer { try? FileManager.default.removeItem(at:directory) }
        _=bridge.runRule(groupID:"g",source:source)
        let saved=try Data(contentsOf:store.fileURL)
        var newer=try object(store);newer["schemaVersion"]=999
        for invalid in [Data("{".utf8),try JSONSerialization.data(withJSONObject:newer)] {
            try invalid.write(to:store.fileURL)
            XCTAssertEqual(bridge.runRule(groupID:"g",source:#"(on,v)=>{v.state.runs=999;}"#)["ok"] as? Bool,false)
            XCTAssertEqual(try Data(contentsOf:store.fileURL),invalid)
        }
        try FileManager.default.removeItem(at:store.fileURL)
        XCTAssertEqual(bridge.runRule(groupID:"g",source:source)["ok"] as? Bool,false)
        XCTAssertFalse(FileManager.default.fileExists(atPath:store.fileURL.path))
        try saved.write(to:store.fileURL)
        bridge.fireSnoozePress(groupID:"g")
        XCTAssertEqual(try state(store)["events"] as? Int,1)
    }
    func testRuleCannotInvokeTheNativeWriterOrNestRegistration() throws {
        let (bridge,store,directory)=fixture(); defer { try? FileManager.default.removeItem(at:directory) }
        let attempt=#"(on,v)=>{v.state.hostWriterVisible=typeof globalThis.__vaultBeforeRuleCommit!=="undefined";v.state.hostRecoveryVisible=typeof globalThis.__vaultCaptureRuleLoadRecovery!=="undefined";const nested=JSON.parse(MacBlockerRuntime.load("g","(on,v)=>{v.state.nested=999;}","{}"));v.state.nestedRefused=nested.ok===false;}"#
        XCTAssertEqual(bridge.runRule(groupID:"g",source:attempt)["ok"] as? Bool,true)
        XCTAssertEqual(try state(store)["hostWriterVisible"] as? Bool,false)
        XCTAssertEqual(try state(store)["hostRecoveryVisible"] as? Bool,false)
        XCTAssertEqual(try state(store)["nestedRefused"] as? Bool,true)
        XCTAssertNil(try state(store)["nested"])
    }
}
#endif
