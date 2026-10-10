import Foundation
import XCTest
import VaultClassifierCore
import VaultActivityCore
@testable import VaultClassifierApp

@MainActor
final class ActivityMCPWorkerTests: XCTestCase {
    private var directory: URL!
    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("vault-activity-mcp-\(UUID().uuidString)")
    }
    override func tearDown() async throws {
        LocalStateFile.flushAllPendingWrites()
        try? FileManager.default.removeItem(at: directory)
    }
    private var activityDirectory: URL { directory.appendingPathComponent("Activity") }
    private var groupFile: URL { activityDirectory.appendingPathComponent("groups.json") }
    private func worker(emit: @escaping ([String: Any]) -> Void = { _ in }) throws -> VaultClassifierWorkerService {
        try .init(testingDirectory: directory, emit: emit)
    }
    private func call(_ service: VaultClassifierWorkerService, _ tool: String, _ arguments: [String: Any] = [:]) async throws -> Any {
        try await service.handle(operation: "activity", data: ["kind": "mcp", "tool": tool, "arguments": arguments])
    }
    private func object(_ value: Any) throws -> [String: Any] { try XCTUnwrap(value as? [String: Any]) }
    private func groups(_ service: VaultClassifierWorkerService) async throws -> [[String: Any]] {
        let value = try object(await call(service, "list_activity_groups"))
        return try XCTUnwrap(value["groups"] as? [[String: Any]])
    }
    private func save(_ service: VaultClassifierWorkerService, _ name: String, _ members: [String], merge: Bool = false, move: Bool = false, id: String? = nil) async throws -> String {
        var arguments: [String: Any] = ["name": name, "members": members, "merge": merge, "move": move]
        if let id { arguments["id"] = id }
        let answer = try object(await call(service, "save_activity_group", arguments))
        XCTAssertEqual(Set(answer.keys), ["id"])
        return try XCTUnwrap(answer["id"] as? String)
    }
    private func refuses(_ service: VaultClassifierWorkerService, _ tool: String, _ args: [String: Any], contains: String? = nil) async {
        do { _ = try await call(service, tool, args); XCTFail("Expected refusal for \(tool)") }
        catch { if let contains { XCTAssertTrue(error.localizedDescription.contains(contains), error.localizedDescription) } }
    }

    func testGroupCRUDSharesTheUIStoreAndPersistsAcrossWorkerRestart() async throws {
        let service = try worker()
        let id = try await save(service, "  学习  ", ["app|test.exe", "web|example.com", "web|example.com"])
        let listed = try await groups(service)
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(Set(listed[0].keys), ["id", "name", "merge", "members"])
        XCTAssertEqual(listed[0]["name"] as? String, "学习")
        XCTAssertEqual(listed[0]["merge"] as? Bool, false)
        XCTAssertEqual(listed[0]["members"] as? [String], ["app|test.exe", "web|example.com"])
        XCTAssertEqual(ActivityStore(directory: activityDirectory).groups().first?.id, id)
        let edited = try await save(service, "Edited", ["web|example.org"], id: id)
        XCTAssertEqual(edited, id)
        let restarted = try worker()
        let reopened = try await groups(restarted)
        XCTAssertEqual(reopened.first?["name"] as? String, "Edited")
        let deleted = try await call(restarted, "delete_activity_group", ["id": id, "merge": 1])
        XCTAssertEqual(deleted as? String, "Deleted.")
        let remaining = try await groups(try worker())
        XCTAssertTrue(remaining.isEmpty)
    }

    func testCanonicalInvalidNameAndMemberRefusalsLeaveSavedBytesUnchanged() async throws {
        let service = try worker()
        _ = try await save(service, "Existing", ["app|test.exe"])
        let before = try Data(contentsOf: groupFile)
        await refuses(service, "save_activity_group", ["name": "  ", "members": []], contains: "Enter a group name")
        await refuses(service, "save_activity_group", ["name": "Bad", "members": ["group|not-a-member"]], contains: "not an app or a website")
        await refuses(service, "save_activity_group", ["name": "Bad", "members": ["web|"]])
        await refuses(service, "save_activity_group", ["name": "Bad", "members": ["app|" + String(repeating: "x", count: 253)]])
        XCTAssertEqual(try Data(contentsOf: groupFile), before)
        let id = try await save(service, String(repeating: "A", count: 70), [])
        let listed = try await groups(service)
        XCTAssertEqual(listed.first { $0["id"] as? String == id }?["name"] as? String, String(repeating: "A", count: 60))
    }

    func testMergeConflictAndMoveUseCanonicalExclusivityWithoutChangingViews() async throws {
        let service = try worker()
        let first = try await save(service, "First", ["web|example.com", "app|test.exe"], merge: true)
        let view = try await save(service, "View", ["web|example.com"])
        let before = try Data(contentsOf: groupFile)
        await refuses(service, "save_activity_group", ["name": "Second", "members": ["web|example.com"], "merge": true], contains: "First")
        XCTAssertEqual(try Data(contentsOf: groupFile), before)
        let second = try await save(service, "Second", ["web|example.com"], merge: true, move: true)
        let listed = try await groups(service)
        XCTAssertEqual(listed.first { $0["id"] as? String == first }?["members"] as? [String], ["app|test.exe"])
        XCTAssertEqual(listed.first { $0["id"] as? String == second }?["members"] as? [String], ["web|example.com"])
        XCTAssertEqual(listed.first { $0["id"] as? String == view }?["members"] as? [String], ["web|example.com"])
    }

    func testMissingDeleteRefusesAndDeletingGroupDoesNotDeleteHistoryOrSettings() async throws {
        let service = try worker(), store = ActivityStore(directory: activityDirectory)
        var settings = store.loadSettings(); settings.set(.init(enabled: true), for: .appUsage); store.saveSettings(settings)
        XCTAssertTrue(store.record(.init(id: "one", category: .appUsage, startedAt: Date().addingTimeInterval(-60), seconds: 10, key: "test.exe", label: "Test")))
        let id = try await save(service, "History", ["app|test.exe"])
        let before = try Data(contentsOf: groupFile)
        await refuses(service, "delete_activity_group", ["id": "missing"], contains: "no such group")
        XCTAssertEqual(try Data(contentsOf: groupFile), before)
        let records = store.records(category: .appUsage, from: Date().addingTimeInterval(-3600), to: Date())
        _ = try await call(service, "delete_activity_group", ["id": id])
        XCTAssertEqual(store.records(category: .appUsage, from: Date().addingTimeInterval(-3600), to: Date()), records)
        XCTAssertEqual(store.loadSettings(), settings)
    }

    func testKnownItemsFollow180DayWindowMostUsedTop300AndIntegerSeconds() async throws {
        let service = try worker(), store = ActivityStore(directory: activityDirectory)
        var settings = store.loadSettings(); settings.set(.init(enabled: true), for: .appUsage); settings.set(.init(enabled: true), for: .webVisit); store.saveSettings(settings)
        let now = Date(), cal = Calendar.current
        for index in 0..<305 {
            XCTAssertTrue(store.record(.init(id: "item\(index)", category: .appUsage, startedAt: now.addingTimeInterval(-1000), seconds: Double(index) + 1.75, key: "app\(index).exe", label: "App \(index)")))
        }
        let cutoff = try XCTUnwrap(cal.date(byAdding: .day, value: -180, to: cal.startOfDay(for: now)))
        XCTAssertTrue(store.record(.init(id: "boundary", category: .webVisit, startedAt: cutoff.addingTimeInterval(60), seconds: 999, key: "boundary.test", label: "Boundary")))
        XCTAssertTrue(store.record(.init(id: "old", category: .webVisit, startedAt: cutoff.addingTimeInterval(-1200), seconds: 1000, key: "old.test", label: "Old")))
        let value = try object(await call(service, "list_activity_groups"))
        XCTAssertEqual(Set(value.keys), ["groups", "items"])
        let items = try XCTUnwrap(value["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 300)
        XCTAssertEqual(items.first?["id"] as? String, "web|boundary.test")
        XCTAssertEqual(items[1]["seconds"] as? Int, 305)
        XCTAssertFalse(items.contains { $0["id"] as? String == "web|old.test" })
        XCTAssertTrue(zip(items, items.dropFirst()).allSatisfy { ($0["seconds"] as? Int ?? 0) >= ($1["seconds"] as? Int ?? 0) })
        XCTAssertEqual(Set(items[0].keys), ["id", "label", "seconds"])
    }

    func testUnsupportedSavedStorageRefusesWritesAndPreservesExactBytes() async throws {
        let service = try worker()
        let data = try JSONSerialization.data(withJSONObject: ["storageMetadata": ["format": "activity.groups", "schemaVersion": 999, "product": "mac", "writtenByAppVersion": "2.2.7"], "value": [["id": "future", "name": "Preserved", "merge": false, "members": ["web|example.com"]]]], options: [.sortedKeys])
        try data.write(to: groupFile)
        await refuses(service, "save_activity_group", ["name": "New", "members": []], contains: "preserved")
        await refuses(service, "delete_activity_group", ["id": "future"])
        _ = try await call(service, "list_activity_groups")
        XCTAssertEqual(try Data(contentsOf: groupFile), data)
    }

    func testFailedDestinationWriteRefusesSaveWithoutReplacingExistingData() async throws {
        let service = try worker()
        try FileManager.default.createDirectory(at: groupFile, withIntermediateDirectories: true)
        let marker = groupFile.appendingPathComponent("retained.txt")
        let bytes = Data("Retained destination".utf8)
        try bytes.write(to: marker)
        await refuses(service, "save_activity_group", ["name": "New", "members": []], contains: "preserved")
        XCTAssertEqual(try Data(contentsOf: marker), bytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: groupFile.path))
    }

    func testTypedArgumentsAndUnknownToolsAreRefusedWithoutMutation() async throws {
        let service = try worker()
        _ = try await save(service, "Existing", [])
        let before = try Data(contentsOf: groupFile)
        for args: [String: Any] in [["members": []], ["name": "Bad"], ["name": "Bad", "members": [5]], ["name": "Bad", "members": [], "merge": 1], ["name": "Bad", "members": [], "move": "true"], ["name": "Bad", "members": [], "id": 5], ["name": "Bad", "members": [], "merge": NSNull()], ["name": "Bad", "members": [], "id": NSNull()]] {
            await refuses(service, "save_activity_group", args)
        }
        await refuses(service, "delete_activity_group", [:])
        await refuses(service, "delete_activity_group", ["id": 5])
        await refuses(service, "unknown_tool", [:])
        XCTAssertEqual(try Data(contentsOf: groupFile), before)
    }

    func testSuccessfulEditsRefreshAnAlreadyLoadedActivityPage() async throws {
        var events: [[String: Any]] = []
        let service = try worker { events.append($0) }
        _ = try await service.handle(operation: "activity", data: ["kind": "ready"])
        let id = try await save(service, "Visible", [])
        for _ in 0..<100 where !events.contains(where: { $0["event"] as? String == "activity" }) { try await Task.sleep(nanoseconds: 5_000_000) }
        let first = try XCTUnwrap(events.last { $0["event"] as? String == "activity" })
        let snapshot = try object(try object(first["value"] as Any)["snapshot"] as Any)
        XCTAssertEqual((snapshot["groups"] as? [[String: Any]])?.first?["id"] as? String, id)
        events.removeAll()
        _ = try await call(service, "delete_activity_group", ["id": id])
        for _ in 0..<100 where !events.contains(where: { $0["event"] as? String == "activity" }) { try await Task.sleep(nanoseconds: 5_000_000) }
        let last = try XCTUnwrap(events.last { $0["event"] as? String == "activity" })
        XCTAssertTrue((try object(try object(last["value"] as Any)["snapshot"] as Any)["groups"] as? [[String: Any]])?.isEmpty == true)
    }
}
