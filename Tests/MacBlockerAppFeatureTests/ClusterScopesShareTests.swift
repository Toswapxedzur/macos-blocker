import XCTest
@testable import MacBlockerAppFeature
import MacBlockerCore

/// Linked groups share their WHOLE definition (owner 2026-09-24): the policy
/// scalars and every entry's scope lines. A member's first contribution unions
/// its entries into the shared lines; afterwards latest edit wins.
final class ClusterScopesShareTests: XCTestCase {
    private func linkedHub() -> ConnectionHub {
        let hub = ConnectionHub()
        hub.setRoster(program: "macapp", groups: [["id": "m1", "name": "Focus"]])
        hub.setRoster(program: "chrome", groups: [["id": "c1", "name": "Focus"]])
        return hub
    }

    private func keys(_ lines: [[String: Any]]?) -> [String] {
        (lines ?? []).map(ConnectionHub.scopeEntryKey)
    }

    /// The Mac group's shared lines as enforcement reads them (the overlay).
    private func sharedScopes(_ hub: ConnectionHub) -> [[String: Any]]? {
        let document: [String: Any] = ["blockedGroups": [["id": "m1", "name": "Focus"]]]
        let groups = hub.overlayShared(onto: document)["blockedGroups"] as? [[String: Any]]
        return groups?.first?["scopes"] as? [[String: Any]]
    }

    func testGroupsLinkByNameAloneWhateverTheirType() throws {
        let hub = ConnectionHub()
        hub.setRoster(program: "macapp", groups: [["id": "m1", "name": "Focus", "type": "site"]])
        hub.setRoster(program: "chrome", groups: [["id": "c1", "name": "Focus", "type": "youtube"]])
        hub.applySync(program: "chrome", groupName: "Focus", contribution: ["scalars": ["mode": "instant"]], ts: 1)
        let overlaid = hub.overlayShared(onto: ["blockedGroups": [["id": "m1", "name": "Focus", "mode": "after-minutes"]]])
        XCTAssertEqual((overlaid["blockedGroups"] as? [[String: Any]])?.first?["mode"] as? String, "instant",
                       "a cluster formed although the types differ, and the Mac reads its shared policy")
    }

    func testEnforcementReadsTheLiveSharedDefinitionAndNewerSnooze() throws {
        let hub = linkedHub()
        let now = Date().timeIntervalSince1970 * 1000
        hub.applySync(program: "chrome", groupName: "Focus", contribution: [
            "scalars": ["allowedMinutes": 45],
            "scopes": [["id": "apps-1", "surface": "apps", "platform": NSNull(), "action": "block", "apps": [["id": "com.hnc.Discord"]]]],
            "snooze": ["startsAtMs": now, "untilMs": now + 600_000, "cooldownUntilMs": now + 600_000, "changedAtMs": now],
            "snoozeTs": now
        ], ts: 5)
        let stored: [String: Any] = [
            "blockedGroups": [["id": "m1", "name": "Focus", "allowedMinutes": 15]],
            "groupSnoozes": ["m1": ["startsAtMs": now - 5_000, "untilMs": now - 1_000, "cooldownUntilMs": now - 1_000]]
        ]
        let overlaid = hub.overlayShared(onto: stored)
        let group = try XCTUnwrap((overlaid["blockedGroups"] as? [[String: Any]])?.first)
        XCTAssertEqual(group["allowedMinutes"] as? Int, 45, "the shared policy, even with no editor open")
        XCTAssertEqual(keys(group["scopes"] as? [[String: Any]]), ["apps"], "the shared entries")
        let snooze = try XCTUnwrap((overlaid["groupSnoozes"] as? [String: Any])?["m1"] as? [String: Any])
        XCTAssertEqual((snooze["untilMs"] as? NSNumber)?.doubleValue, now + 600_000, "a newer snooze from another device applies")
    }

    func testFirstContributionsUnionEntriesThenLatestEditWins() throws {
        let hub = linkedHub()
        let youtube: [[String: Any]] = [
            ["id": "items-1", "surface": "items", "platform": "youtube", "action": "hide", "form": "all", "sourceMode": "all", "sources": [], "tagFilter": NSNull()],
            ["id": "pages-1", "surface": "pages", "platform": "youtube", "action": "block", "form": "all", "sourceMode": "all", "sources": [], "tagFilter": NSNull()]
        ]
        let apps: [[String: Any]] = [["id": "apps-1", "surface": "apps", "platform": NSNull(), "action": "block", "apps": [["id": "com.apple.Safari", "name": "Safari"]]]]

        hub.applySync(program: "chrome", groupName: "Focus", contribution: ["scalars": ["mode": "instant"], "scopes": youtube], ts: 10)
        XCTAssertEqual(keys(sharedScopes(hub)), ["youtube", "youtube"], "the first member's entries become the shared ones")

        hub.applySync(program: "macapp", groupName: "Focus", contribution: ["scalars": ["mode": "instant"], "scopes": apps], ts: 5)
        XCTAssertEqual(keys(sharedScopes(hub)), ["youtube", "youtube", "apps"], "the Mac's first contribution adds its Apps entry even with an older ts")

        // Chrome adopted the union and now edits it: adds a site line, drops YouTube.
        let edited: [[String: Any]] = apps + [["id": "site-1", "surface": "site", "platform": NSNull(), "action": "block", "sites": ["example.com"], "sitesExcept": false]]
        hub.applySync(program: "chrome", groupName: "Focus", contribution: ["scalars": ["mode": "instant"], "scopes": edited], ts: 20)
        XCTAssertEqual(keys(sharedScopes(hub)), ["apps", "site"], "a later edit replaces the shared lines wholesale (deletions propagate)")

        // A stale edit from the Mac (older ts) does not win.
        hub.applySync(program: "macapp", groupName: "Focus", contribution: ["scalars": ["mode": "instant"], "scopes": youtube], ts: 15)
        XCTAssertEqual(keys(sharedScopes(hub)), ["apps", "site"], "latest edit wins")

        // A usage-only ping never touches the definition.
        hub.applySync(program: "chrome", groupName: "Focus", contribution: ["usageDeltaMs": 1000.0], ts: 30)
        XCTAssertEqual(keys(sharedScopes(hub)), ["apps", "site"])
    }

    func testMacEditorFramesAreKeyedByKind() {
        // The Mac's web editor sends the popup's runtime messages ({type: …});
        // the hub dispatches on `kind`, so its own syncs must be re-keyed.
        let frame = ConnectionHub.bridgeFrame(["type": "group-sync", "groupName": "Focus"])
        XCTAssertEqual(frame["kind"] as? String, "group-sync")
        XCTAssertEqual(ConnectionHub.bridgeFrame(["kind": "group-sync"])["kind"] as? String, "group-sync")
    }

    func testUnionRenumbersLineIdsPerSurface() {
        let existing: [[String: Any]] = [["id": "items-1", "surface": "items", "platform": "youtube"], ["id": "site-1", "surface": "site", "platform": NSNull()]]
        let incoming: [[String: Any]] = [["id": "items-1", "surface": "items", "platform": "reddit"], ["id": "site-1", "surface": "site", "platform": NSNull(), "sites": ["a.com"]]]
        let merged = ConnectionHub.unionScopes(existing, incoming: incoming)
        XCTAssertEqual(merged.map { $0["id"] as? String }, ["items-1", "items-2", "site-1"])
        XCTAssertEqual(ConnectionHub.scopeEntryKey(merged[2]), "site")
        XCTAssertEqual(merged[2]["sites"] as? [String], ["a.com"], "the incoming version of a shared entry wins")
    }
}
