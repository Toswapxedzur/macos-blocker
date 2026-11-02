#if os(macOS)
import XCTest
import CryptoKit
@testable import MacBlockerAppFeature

final class RuleAIConversationsTests: XCTestCase {
    func testGlobalHistoryEvictionAndDeletion() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RuleAIConversations(root: directory)
        try await store.append(members: ["mac:a"], name: "topic", model: "chatgpt:first", user: "Mac question", assistant: "Mac answer")
        let initialLimit = try await store.setting(action: "status")
        XCTAssertEqual(initialLimit, 1024)
        let shared = try await store.prepare(members: ["chrome:b"], name: "topic")
        XCTAssertTrue(shared.history.contains("Mac answer"))
        try await store.append(members: ["chrome:b"], name: "topic", model: "api:second", user: "Browser question", assistant: "Browser answer")
        let restarted = RuleAIConversations(root: directory)
        let resumed = try await restarted.prepare(members: ["mac:a"], name: "topic")
        XCTAssertTrue(resumed.history.contains("Browser answer"))
        try RuleAIConversations.copyAllBeforeUnlink(members: ["mac:a", "chrome:b"], root: directory)
        let afterUnlink = try await restarted.prepare(members: ["chrome:b"], name: "topic")
        XCTAssertTrue(afterUnlink.history.contains("Mac answer"))
        try await store.append(members: ["mac:a"], name: "older", model: "chatgpt:first", user: "Old", assistant: String(repeating: "x", count: 600_000))
        try await store.append(members: ["mac:a"], name: "newer", model: "chatgpt:first", user: "New", assistant: String(repeating: "y", count: 600_000))
        let newLimit = try await store.setting(action: "set", mb: 1)
        XCTAssertEqual(newLimit, 1)
        let evicted = try await restarted.prepare(members: ["mac:a"], name: "older")
        XCTAssertEqual(evicted.history, "")
        let retained = try await restarted.prepare(members: ["chrome:b"], name: "newer")
        XCTAssertFalse(retained.history.isEmpty)
        try await store.delete(name: "topic")
        let deleted = try await restarted.prepare(members: ["chrome:b"], name: "topic")
        XCTAssertEqual(deleted.history, "")
        func digest(_ value: String) -> String {
            SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        for (member, value) in [("mac:a", "Mac-only"), ("chrome:b", "Browser-only")] {
            let folder = directory.appendingPathComponent(digest(member), isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let document = RuleAIConversations.Document(name: "legacy", messages: [
                .init(id: UUID().uuidString, role: "assistant", text: value, model: "fixture", at: 1)
            ])
            try JSONEncoder().encode(document).write(to: folder.appendingPathComponent(digest("legacy") + ".json"))
        }
        let imported = try await restarted.prepare(members: ["mac:a"], name: "legacy")
        XCTAssertEqual(imported.preservedNames.count, 1)
        let alias = try await restarted.prepare(members: ["chrome:b"], name: imported.preservedNames[0])
        XCTAssertTrue(alias.history.contains("only"))
    }
}
#endif
