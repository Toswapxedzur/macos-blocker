#if os(macOS)
import XCTest
@testable import MacBlockerCore
import MacBlockerWebUI

/// The editor persists THROUGH GroupStore (one lock for both the WebView and
/// MCP writers). These lock in that the editor's save writes web-store.json and
/// does NOT self-notify — a re-seed notification is only for out-of-band
/// native writes.
final class BlockerWebStoreRoutingTests: XCTestCase {
    private func makeStore() -> (BlockerWebStore, SharedAppGroupStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("webstore-routing-\(UUID().uuidString)", isDirectory: true)
        let shared = SharedAppGroupStore(baseDirectory: dir)
        return (BlockerWebStore(shared: shared), shared, dir)
    }

    func testSavePersistsThroughGroupStore() throws {
        let (webStore, _, dir) = makeStore()
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
    }

    /// Found live on mini1 2026-09-26: the usage writer read the file THROUGH
    /// the shared overlay and wrote it back, baking another device's incomplete
    /// copy into this Mac's group (its Apps entry was lost).
    func testUsageWritesNeverPersistTheSharedOverlay() throws {
        let (webStore, _, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        webStore.save(rawStore: ["blockedGroups": [["id": "g1", "name": "Focus", "enabled": true, "mode": "instant",
            "scopes": [["id": "apps-1", "surface": "apps", "action": "block", "apps": [["id": "com.example.App"]]]]]]])
        defer { GroupStore.sharedOverlay = nil }
        GroupStore.sharedOverlay = { document in
            var overlaid = document
            overlaid["blockedGroups"] = [["id": "g1", "name": "Focus", "scopes": [] as [[String: Any]]]]
            return overlaid
        }
        webStore.writeUsage(timersMs: ["g1": 1_000], resetAtMs: ["g1": 1])
        let json = try XCTUnwrap(webStore.loadRawJSON())
        XCTAssertTrue(json.contains("com.example.App"), "the stored Apps entry survives a usage write")
        XCTAssertEqual(webStore.importedGroups().first?.targets.count ?? -1, 0, "enforcement still reads the overlay")
    }

    func testTheTickReadsOnceAndCountsAFinishedSnoozeOnce() throws {
        let (webStore, _, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        webStore.save(rawStore: ["blockedGroups": [["id": "g1", "name": "Focus"]],
                                 "globalSettings": ["quitRetryMinutes": 3],
                                 "usageTimersMs": ["g1": 5_000],
                                 "groupSnoozes": ["g1": ["startsAtMs": 1_000, "untilMs": 61_000]]])
        let first = webStore.loadForTick(nowMs: 100_000)
        XCTAssertEqual(((first["groupSnoozeTotalsMs"] as? [String: Any])?["g1"] as? NSNumber)?.doubleValue, 60_000)
        let again = webStore.loadForTick(nowMs: 200_000)
        XCTAssertEqual(((again["groupSnoozeTotalsMs"] as? [String: Any])?["g1"] as? NSNumber)?.doubleValue, 60_000, "counted once")
        let view = BlockerWebStore.enforcementView(of: again)
        XCTAssertEqual(view.groups.map(\.id), ["g1"])
        XCTAssertEqual(view.usage.timersMs["g1"], 5_000)
        XCTAssertEqual(view.quitRetryMinutes, 3)
        XCTAssertNotNil(view.snoozes["g1"]?.until)
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
