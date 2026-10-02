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
    private func activity(_ service: VaultClassifierWorkerService, _ body: [String: Any]) async throws -> [String: Any] {
        try object(await service.handle(operation: "activity", data: body))
    }

    private func assertRefuses(_ service: VaultClassifierWorkerService, operation: String, data: [String: Any], file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await service.handle(operation: operation, data: data); XCTFail("Expected refusal", file: file, line: line) }
        catch { }
    }
    private func assertAccepted(_ service: VaultClassifierWorkerService, _ body: [String: Any], _ expected: Int, file: StaticString = #filePath, line: UInt = #line) async throws {
        let answer = try await activity(service, body)
        XCTAssertEqual(answer["accepted"] as? Int, expected, file: file, line: line)
    }

    func testWorkerUsesExistingActionAndMCPValidationAndPersistsActivation() async throws {
        let service = try worker()
        let created = try object(await service.handle(operation: "action", data: ["action": "createClassifierType", "data": ["name": "Games", "platformIDs": ["youtube", "reddit"]]]))
        let snapshot = try object(created["snapshot"] as Any), assets = try object(snapshot["assets"] as Any)
        let group = try XCTUnwrap((assets["classifierTypes"] as? [[String: Any]])?.first)
        let id = try XCTUnwrap(group["id"] as? String)
        _ = try await service.handle(operation: "mcp", data: ["kind": "action", "action": "setClassifierTypePaused", "data": ["typeID": id, "paused": true]])
        let refused = try object(await service.handle(operation: "action", data: ["action": "configureClassifierType", "data": ["typeID": id, "name": "Changed", "applicablePlatformIDs": ["twitter"]]]))
        XCTAssertEqual(refused["issue"] as? String, "Platforms cannot be changed after the group is created.")
        let restored = try worker()
        let restoredAssets = try object(try object(await restored.handle(operation: "snapshot", data: [:]))["assets"] as Any)
        let restoredGroup = try XCTUnwrap((restoredAssets["classifierTypes"] as? [[String: Any]])?.first)
        XCTAssertEqual(restoredGroup["isPaused"] as? Bool, true)
        XCTAssertEqual(restoredGroup["applicablePlatformIDs"] as? [String], ["youtube", "reddit"])
    }

    func testWorkerRefusesRetiredActionsOversizedActionsAndUnboundedHubBodies() async throws {
        let service = try worker()
        await assertRefuses(service, operation: "action", data: ["action": "restoreClassifierType", "data": [:]])
        let fields = Dictionary(uniqueKeysWithValues: (0..<25).map { ("field\($0)", "value") })
        await assertRefuses(service, operation: "action", data: ["action": "state", "data": fields])
        await assertRefuses(service, operation: "hub", data: ["sourcePeerID": "browser", "requestID": "fixture", "operation": "collect", "body": ["payload": String(repeating: "x", count: 88_001)]])
        await assertRefuses(service, operation: "resource", data: ["url": "file:///private/secret.json"])
    }

    func testActivityKeepsBrowserRecordingOptInAndRejectsForgedNativeRecords() async throws {
        let service = try worker()
        let date = Date().timeIntervalSince1970 * 1_000
        let web: [String: Any] = ["id": "visit", "category": "web-visit", "key": "example.test", "label": "example.test", "seconds": 15, "startedAtMs": date]
        try await assertAccepted(service, ["kind": "browser-record", "body": ["records": [web]]], 0)
        _ = try await activity(service, ["kind": "setSettings", "category": "web-visit", "enabled": true])
        let icon = "data:image/png;base64,fixture"
        try await assertAccepted(service, ["kind": "browser-record", "body": ["records": [web], "icons": ["example.test": icon]]], 1)
        let iconPayload = try object(try await activity(service, ["kind": "snapshot"])["icons"] as Any)
        XCTAssertEqual(iconPayload["example.test"] as? String, icon)
        try await assertAccepted(service, ["kind": "browser-record", "body": ["records": [web]]], 0)
        _ = try await activity(service, ["kind": "setSettings", "category": "app-usage", "enabled": true])
        var forged = web; forged["id"] = "forged"; forged["category"] = "app-usage"
        try await assertAccepted(service, ["kind": "browser-record", "body": ["records": [forged]]], 0)
    }

    func testNativeActivityCreditsPreviousAppAndFlushesBeforeShutdown() async throws {
        let service = try worker()
        _ = try await activity(service, ["kind": "setSettings", "category": "app-usage", "enabled": true])
        let now = Date().addingTimeInterval(-60).timeIntervalSince1970 * 1_000
        for (index, app) in ["a.exe", "a.exe", "b.exe", "b.exe"].enumerated() {
            _ = try await activity(service, ["kind": "native-sample", "appId": app, "name": app, "elapsedMs": 1_000, "atMs": now + Double(index) * 1_000])
        }
        _ = try await service.handle(operation: "hostEvent", data: ["kind": "flush"])
        let payload = try await activity(service, ["kind": "snapshot"]), dashboard = try object(payload["snapshot"] as Any), apps = try object(dashboard["app"] as Any)
        let bars = try XCTUnwrap(apps["bars"] as? [[String: Any]])
        XCTAssertEqual(bars.first { $0["key"] as? String == "a.exe" }?["seconds"] as? Double, 2)
        XCTAssertEqual(bars.first { $0["key"] as? String == "b.exe" }?["seconds"] as? Double, 1)
    }

    func testActivityGroupConflictAndHistoryUseTheCanonicalStore() async throws {
        let service = try worker()
        let first = try await activity(service, ["kind": "group-save", "request": "one", "group": ["name": "Work", "merge": true, "members": ["app|a.exe"]]])
        XCTAssertEqual(try object(first["answer"] as Any)["ok"] as? Bool, true)
        let conflict = try await activity(service, ["kind": "group-save", "request": "two", "group": ["name": "Other", "merge": true, "members": ["app|a.exe"]]])
        let answer = try object(conflict["answer"] as Any)
        XCTAssertEqual(answer["ok"] as? Bool, false)
        XCTAssertEqual((answer["conflicts"] as? [String: String])?["app|a.exe"], "Work")
        let history = try await activity(service, ["kind": "history", "section": "content", "pick": "tag|one,two"])
        XCTAssertEqual(history["kind"] as? String, "history")
        XCTAssertEqual((history["request"] as? [String: String])?["pick"], "tag|one,two")
        XCTAssertTrue(JSONSerialization.isValidJSONObject(history))
        let usageHistory = try await activity(service, ["kind": "history", "section": "usage", "pick": "app|a.exe", "barDays": 7])
        let request = try object(usageHistory["request"] as Any)
        XCTAssertEqual(request["pick"] as? String, "app|a.exe")
        XCTAssertEqual(request["barDays"] as? Int, 7)
        let usage = try object(usageHistory["value"] as Any), map = try object(usage["map"] as Any)
        XCTAssertEqual((map["dayStartsMs"] as? [Double])?.count, 365)
        XCTAssertEqual((usage["days"] as? [[String: Any]])?.count, 7)
    }

    func testActivitySceneReceivesFullSearchAndPagingCatalogWithAllNativeIcons() async throws {
        let service = try worker()
        _ = try await activity(service, ["kind": "setSettings", "category": "app-usage", "enabled": true])
        let now = Date().addingTimeInterval(-60).timeIntervalSince1970 * 1_000
        let records: [[String: Any]] = (0..<512).map {
            ["id": "fixture-\($0)", "key": "app-\($0).exe", "label": "App \($0)", "seconds": 1, "startedAtMs": now]
        }
        let icon = "data:image/png;base64,fixture"
        let icons = Dictionary(uniqueKeysWithValues: (0..<512).map { ("app-\($0).exe", icon) })
        try await assertAccepted(service, ["kind": "native-record", "records": records, "icons": icons], 512)
        let known = try await activity(service, ["kind": "known-items"])
        let items = try XCTUnwrap(known["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 512)
        XCTAssertTrue(items.contains { $0["id"] as? String == "app|app-511.exe" })
        XCTAssertEqual((known["icons"] as? [String: String])?.count, 512)
        let snapshot = try await activity(service, ["kind": "ready"])
        let app = try object(try object(snapshot["snapshot"] as Any)["app"] as Any)
        XCTAssertEqual((app["bars"] as? [[String: Any]])?.count, 512)
        XCTAssertEqual((snapshot["icons"] as? [String: String])?["app-511.exe"], icon)
        let content = try await activity(service, ["kind": "range", "section": "content", "range": "7d"])
        XCTAssertNotNil(content["contentSnapshot"] as? [String: Any])
    }

    func testActivityTagCatalogKeepsParentsAndUniqueIDsAcrossAssignedPlatforms() async throws {
        let service = try worker()
        let created = try object(await service.handle(operation: "action", data: ["action": "createClassifierType", "data": ["name": "Video", "platformIDs": ["youtube", "reddit"]]]))
        let assets = try object(try object(created["snapshot"] as Any)["assets"] as Any)
        let group = try XCTUnwrap((assets["classifierTypes"] as? [[String: Any]])?.first)
        let treeID = try XCTUnwrap(group["treeID"] as? String)
        _ = try await service.handle(operation: "action", data: ["action": "addTag", "data": ["treeID": treeID, "name": "Parent", "positionX": 0, "positionY": 0]])
        let first = try await activity(service, ["kind": "ready"])
        let parent = try XCTUnwrap((first["tags"] as? [[String: String]])?.first { $0["name"] == "Parent" })
        let parentID = try XCTUnwrap(parent["id"])
        _ = try await service.handle(operation: "action", data: ["action": "addTag", "data": ["treeID": treeID, "name": "Child", "parentID": parentID, "positionX": 1, "positionY": 1]])
        let value = try await activity(service, ["kind": "snapshot"])
        let tags = try XCTUnwrap(value["tags"] as? [[String: String]])
        XCTAssertEqual(tags.count, 2)
        XCTAssertEqual(Set(tags.compactMap { $0["id"] }).count, 2)
        XCTAssertEqual(tags.first { $0["name"] == "Child" }?["parentID"], parentID)
    }
}
