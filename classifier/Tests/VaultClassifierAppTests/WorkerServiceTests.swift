import Foundation
import XCTest
import VaultClassifierCore
@testable import VaultClassifierApp

@MainActor
final class WorkerServiceTests: XCTestCase {
    private var directory: URL!
    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("vault-worker-test-\(UUID().uuidString)", isDirectory: true)
    }
    override func tearDown() async throws {
        LocalStateFile.flushAllPendingWrites()
        try? FileManager.default.removeItem(at: directory)
    }
    private func worker() throws -> VaultClassifierWorkerService { try .init(testingDirectory: directory, emit: { _ in }) }
    private func object(_ value: Any) throws -> [String: Any] { try XCTUnwrap(value as? [String: Any]) }
    private func activity(_ service: VaultClassifierWorkerService, _ body: [String: Any]) throws -> [String: Any] {
        try object(service.handle(operation: "activity", data: body))
    }

    func testWorkerUsesExistingActionAndMCPValidationAndPersistsActivation() throws {
        let service = try worker()
        let created = try object(service.handle(operation: "action", data: ["action": "createClassifierType", "data": ["name": "Games", "platformIDs": ["youtube", "reddit"]]]))
        let snapshot = try object(created["snapshot"] as Any), assets = try object(snapshot["assets"] as Any)
        let group = try XCTUnwrap((assets["classifierTypes"] as? [[String: Any]])?.first)
        let id = try XCTUnwrap(group["id"] as? String)
        _ = try service.handle(operation: "mcp", data: ["kind": "action", "action": "setClassifierTypePaused", "data": ["typeID": id, "paused": true]])
        let refused = try object(service.handle(operation: "action", data: ["action": "configureClassifierType", "data": ["typeID": id, "name": "Changed", "applicablePlatformIDs": ["twitter"]]]))
        XCTAssertEqual(refused["issue"] as? String, "Platforms cannot be changed after the group is created.")
        let restored = try worker()
        let restoredAssets = try object(try object(restored.handle(operation: "snapshot", data: [:]))["assets"] as Any)
        let restoredGroup = try XCTUnwrap((restoredAssets["classifierTypes"] as? [[String: Any]])?.first)
        XCTAssertEqual(restoredGroup["isPaused"] as? Bool, true)
        XCTAssertEqual(restoredGroup["applicablePlatformIDs"] as? [String], ["youtube", "reddit"])
    }

    func testWorkerRefusesRetiredActionsOversizedActionsAndUnboundedHubBodies() throws {
        let service = try worker()
        XCTAssertThrowsError(try service.handle(operation: "action", data: ["action": "restoreClassifierType", "data": [:]]))
        let fields = Dictionary(uniqueKeysWithValues: (0..<25).map { ("field\($0)", "value") })
        XCTAssertThrowsError(try service.handle(operation: "action", data: ["action": "state", "data": fields]))
        XCTAssertThrowsError(try service.handle(operation: "hub", data: ["sourcePeerID": "browser", "requestID": "fixture", "operation": "collect", "body": ["payload": String(repeating: "x", count: 88_001)]]))
        XCTAssertThrowsError(try service.handle(operation: "resource", data: ["url": "file:///private/secret.json"]))
    }

    func testActivityKeepsBrowserRecordingOptInAndRejectsForgedNativeRecords() throws {
        let service = try worker()
        let date = Date().timeIntervalSince1970 * 1_000
        let web: [String: Any] = ["id": "visit", "category": "web-visit", "key": "example.test", "label": "example.test", "seconds": 15, "startedAtMs": date]
        XCTAssertEqual(try activity(service, ["kind": "browser-record", "body": ["records": [web]]])["accepted"] as? Int, 0)
        _ = try activity(service, ["kind": "setSettings", "category": "web-visit", "enabled": true])
        XCTAssertEqual(try activity(service, ["kind": "browser-record", "body": ["records": [web]]])["accepted"] as? Int, 1)
        XCTAssertEqual(try activity(service, ["kind": "browser-record", "body": ["records": [web]]])["accepted"] as? Int, 0)
        _ = try activity(service, ["kind": "setSettings", "category": "app-usage", "enabled": true])
        var forged = web; forged["id"] = "forged"; forged["category"] = "app-usage"
        XCTAssertEqual(try activity(service, ["kind": "browser-record", "body": ["records": [forged]]])["accepted"] as? Int, 0)
    }

    func testNativeActivityCreditsPreviousAppAndFlushesBeforeShutdown() throws {
        let service = try worker()
        _ = try activity(service, ["kind": "setSettings", "category": "app-usage", "enabled": true])
        let now = Date().addingTimeInterval(-60).timeIntervalSince1970 * 1_000
        for (index, app) in ["a.exe", "a.exe", "b.exe", "b.exe"].enumerated() {
            _ = try activity(service, ["kind": "native-sample", "appId": app, "name": app, "elapsedMs": 1_000, "atMs": now + Double(index) * 1_000])
        }
        _ = try service.handle(operation: "hostEvent", data: ["kind": "flush"])
        let payload = try activity(service, ["kind": "snapshot"]), dashboard = try object(payload["snapshot"] as Any), apps = try object(dashboard["app"] as Any)
        let bars = try XCTUnwrap(apps["bars"] as? [[String: Any]])
        XCTAssertEqual(bars.first { $0["key"] as? String == "a.exe" }?["seconds"] as? Double, 2)
        XCTAssertEqual(bars.first { $0["key"] as? String == "b.exe" }?["seconds"] as? Double, 1)
    }

    func testActivityGroupConflictAndHistoryUseTheCanonicalStore() throws {
        let service = try worker()
        let first = try activity(service, ["kind": "group-save", "request": "one", "group": ["name": "Work", "merge": true, "members": ["app|a.exe"]]])
        XCTAssertEqual(try object(first["answer"] as Any)["ok"] as? Bool, true)
        let conflict = try activity(service, ["kind": "group-save", "request": "two", "group": ["name": "Other", "merge": true, "members": ["app|a.exe"]]])
        let answer = try object(conflict["answer"] as Any)
        XCTAssertEqual(answer["ok"] as? Bool, false)
        XCTAssertEqual((answer["conflicts"] as? [String: String])?["app|a.exe"], "Work")
        let history = try activity(service, ["kind": "history", "section": "content", "pick": "tag|one,two"])
        XCTAssertEqual(history["kind"] as? String, "history")
        XCTAssertEqual((history["request"] as? [String: String])?["pick"], "tag|one,two")
        XCTAssertTrue(JSONSerialization.isValidJSONObject(history))
    }
}
