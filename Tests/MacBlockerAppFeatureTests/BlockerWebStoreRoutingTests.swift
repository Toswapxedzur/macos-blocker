#if os(macOS)
import XCTest
@testable import MacBlockerCore
import MacBlockerWebUI

/// The editor persists THROUGH GroupStore now (one lock, one plan derivation for
/// both the WebView and MCP writers). These lock in that the editor's save still
/// writes web-store.json and rebuilds the enforcement plan, and that it does NOT
/// self-notify — a re-seed notification is only for out-of-band native writes.
final class BlockerWebStoreRoutingTests: XCTestCase {
    private func makeStore() -> (BlockerWebStore, SharedAppGroupStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("webstore-routing-\(UUID().uuidString)", isDirectory: true)
        let shared = SharedAppGroupStore(baseDirectory: dir)
        return (BlockerWebStore(shared: shared), shared, dir)
    }

    func testSavePersistsAndRebuildsPlanThroughGroupStore() throws {
        let (webStore, shared, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let raw: [String: Any] = [
            "blockedGroups": [
                [
                    "id": "g1", "groupType": "app", "name": "Focus", "enabled": true,
                    "mode": "instant", "apps": [["id": "com.apple.Safari", "name": "Safari"]],
                ],
            ],
        ]
        webStore.save(rawStore: raw)

        // Persisted to the shared web-store.json …
        let json = try XCTUnwrap(webStore.loadRawJSON())
        XCTAssertTrue(json.contains("\"g1\""))
        // … and the enforcement plan was rebuilt under GroupStore and reflects it.
        let plan = try XCTUnwrap(shared.loadEnforcementPlan())
        XCTAssertTrue(plan.entries.contains { $0.groupID == "g1" }, "plan must reflect the saved enabled group")
    }

    func testEditorSaveDoesNotSelfNotify() {
        let (webStore, _, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        var posts = 0
        let token = NotificationCenter.default.addObserver(
            forName: GroupStore.didChangeNotification, object: nil, queue: nil
        ) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        webStore.save(rawStore: ["blockedGroups": [] as [[String: Any]]])
        XCTAssertEqual(posts, 0, "the editor's own persist must not post a re-seed notification")
    }

    func testSaveIgnoresNonObjectPayload() {
        let (webStore, shared, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        // A non-dictionary top-level payload is not a valid store; save is a no-op.
        webStore.save(rawStore: [1, 2, 3])
        XCTAssertNil(shared.readData(SharedAppGroupStore.webStoreFileName), "no file written for a non-object payload")
    }
}
#endif
