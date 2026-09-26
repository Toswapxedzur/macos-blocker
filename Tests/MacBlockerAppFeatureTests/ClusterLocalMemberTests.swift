import XCTest
@testable import MacBlockerAppFeature

/// Mac Vault takes part in its links itself, editor window or not (found live on
/// mini1 2026-09-26: with the window closed, linking dropped the Mac's Apps entry
/// and the Mac stopped blocking the app).
final class ClusterLocalMemberTests: XCTestCase {
    private func linkedHub() -> ConnectionHub {
        let hub = ConnectionHub()
        hub.hostingLocalHub = true // this Mac hosts the hub, as in the app
        hub.setRoster(program: "macapp", groups: [["id": "m1", "name": "Focus"]])
        hub.setRoster(program: "chrome", groups: [["id": "c1", "name": "Focus"]])
        return hub
    }
    private let appsLine: [String: Any] = ["id": "apps-1", "surface": "apps", "platform": NSNull(), "action": "block",
                                            "apps": [["id": "com.example.App"]], "appsExcept": false]
    private let siteLine: [String: Any] = ["id": "site-1", "surface": "site", "platform": NSNull(), "action": "block",
                                            "sites": ["example.com"], "sitesExcept": false]
    private func document(_ scopes: [[String: Any]], minutes: Int = 15) -> [String: Any] {
        ["blockedGroups": [["id": "m1", "name": "Focus", "allowedMinutes": minutes, "scopes": scopes]]]
    }
    private func sharedSurfaces(_ hub: ConnectionHub) -> [String] {
        let group = (hub.overlayShared(onto: document([]))["blockedGroups"] as? [[String: Any]])?.first
        return ((group?["scopes"] as? [[String: Any]]) ?? []).compactMap { $0["surface"] as? String }.sorted()
    }

    func testTheSharedFieldListMatchesTheExtensions() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MacBlockerWebUI/WebAssets/group-scopes.js"), encoding: .utf8)
        let block = try XCTUnwrap(source.range(of: "SYNC_SCALAR_FIELDS = Object.freeze([").flatMap { start in
            source.range(of: "]);", range: start.upperBound..<source.endIndex).map { String(source[start.upperBound..<$0.lowerBound]) }
        })
        let fields = block.split(separator: "\"").enumerated().filter { $0.offset % 2 == 1 }.map { String($0.element) }
        XCTAssertEqual(fields, ConnectionHub.syncScalarFields)
    }

    func testJoiningContributesTheMacEntriesWithoutTheEditor() {
        let hub = linkedHub()
        hub.applySync(program: "chrome", groupName: "Focus", contribution: ["scalars": ["allowedMinutes": 30], "scopes": [siteLine]], ts: 50)
        hub.contributeLocalDefinitions(document: document([appsLine]), nowMs: 100)
        XCTAssertEqual(sharedSurfaces(hub), ["apps", "site"], "the Mac's Apps entry joins the shared lines")
        let group = (hub.overlayShared(onto: document([appsLine]))["blockedGroups"] as? [[String: Any]])?.first
        XCTAssertEqual(group?["allowedMinutes"] as? Int, 30, "joining never overrides a newer setting")
    }

    func testOnlyARealMacEditIsSentAndALaggingCopyNever() {
        let hub = linkedHub()
        hub.applySync(program: "chrome", groupName: "Focus", contribution: ["scalars": ["allowedMinutes": 30], "scopes": [siteLine]], ts: 50)
        hub.contributeLocalDefinitions(document: document([appsLine]), nowMs: 100)
        // Chrome edits later; the Mac file still holds its old copy: nothing is sent.
        hub.applySync(program: "chrome", groupName: "Focus", contribution: ["scalars": ["allowedMinutes": 45], "scopes": [siteLine, appsLine]], ts: 200)
        hub.contributeLocalDefinitions(document: document([appsLine]), nowMs: 300)
        XCTAssertEqual((hub.overlayShared(onto: document([]))["blockedGroups"] as? [[String: Any]])?.first?["allowedMinutes"] as? Int, 45)
        // A real Mac edit (the file changes) is sent and wins.
        hub.contributeLocalDefinitions(document: document([appsLine, siteLine], minutes: 60), nowMs: 400)
        XCTAssertEqual((hub.overlayShared(onto: document([]))["blockedGroups"] as? [[String: Any]])?.first?["allowedMinutes"] as? Int, 60)
    }
}
