#if os(macOS)
import XCTest
@testable import MacBlockerAppFeature

final class RuleAIConversationsTests: XCTestCase {
    func testLinkedMembersShareHistoryAndKeepDistinctPreexistingNames() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RuleAIConversations(root: directory)
        try await store.append(members: ["mac:a"], name: "topic", model: "chatgpt:first", user: "Mac question", assistant: "Mac answer")
        try await store.append(members: ["chrome:b"], name: "topic", model: "api:second", user: "Browser question", assistant: "Browser answer")
        let linked = ["chrome:b", "mac:a"]
        let before = try await store.prepare(members: linked, name: "topic")
        XCTAssertTrue(before.history.contains("question"))
        XCTAssertEqual(before.preservedNames.count, 1)
        let restarted = RuleAIConversations(root: directory)
        let resumed = try await restarted.prepare(members: linked, name: "topic")
        XCTAssertEqual(resumed.preservedNames, before.preservedNames)
        try await store.append(members: linked, name: "topic", model: "api:third", user: "Shared question", assistant: "Shared answer")
        for member in linked {
            let after = try await store.prepare(members: [member], name: "topic")
            XCTAssertTrue(after.history.contains("Shared answer"), "unlink retains the shared transcript")
            let preserved = try await store.prepare(members: [member], name: before.preservedNames[0])
            XCTAssertTrue(preserved.history.contains("question"))
        }
        let names = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .flatMap { try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) }
            .compactMap { try? JSONDecoder().decode(RuleAIConversations.Document.self, from: Data(contentsOf: $0)).name }
        XCTAssertTrue(names.contains("topic"))
        XCTAssertTrue(names.contains { $0.hasPrefix("topic~") }, "independent same-name histories are preserved")
        try await store.append(members: ["mac:a"], name: "unopened", model: "chatgpt:first", user: "Prior-only question", assistant: "Prior-only answer")
        try RuleAIConversations.copyAllBeforeUnlink(members: linked, root: directory)
        let copied = try await restarted.prepare(members: ["chrome:b"], name: "unopened")
        XCTAssertTrue(copied.history.contains("Prior-only answer"))
    }
}
#endif
