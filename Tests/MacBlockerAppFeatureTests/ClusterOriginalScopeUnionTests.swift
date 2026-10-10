import XCTest
@testable import MacBlockerAppFeature

final class ClusterOriginalScopeUnionTests: XCTestCase {
    private func site(_ value: String) -> [String: Any] {
        ["id": "site-1", "surface": "site", "platform": NSNull(), "action": "block", "sites": [value], "sitesExcept": false]
    }
    func testThirdBrowsersOriginalSiteJoinsExistingSiteAndLaterEditCanDelete() throws {
        let hub = ConnectionHub(); hub.hostingLocalHub = true
        for (program, id) in [("macapp", "m"), ("chrome", "c"), ("edge", "e")] {
            hub.setRoster(program: program, groups: [["id": id, "name": program]])
        }
        XCTAssertNil(hub.linkGroups(program: "chrome", groupId: "c", targetProgram: "macapp", targetGroupId: "m"))
        hub.applySync(program: "chrome", groupId: "c", contribution: ["scalars": ["name": "Chrome", "allowedMinutes": 20], "scopes": [site("example.com")]], ts: 0)
        hub.applySync(program: "macapp", groupId: "m", contribution: ["scalars": ["allowedMinutes": 10], "scopes": [["surface": "apps", "id": "apps-1", "apps": [["id": "com.example.App"]]]]], ts: 0)
        XCTAssertNil(hub.linkGroups(program: "chrome", groupId: "c", targetProgram: "edge", targetGroupId: "e"))
        hub.applySync(program: "edge", groupId: "e", contribution: ["scalars": ["allowedMinutes": 30], "scopes": [site("example.org")]], ts: 0)
        func joinedSites() throws -> [String] {
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(hub.clustersJSON().utf8)) as? [String: Any])
            let shared = try XCTUnwrap((root["clusters"] as? [[String: Any]])?.first?["shared"] as? [String: Any])
            return (shared["scopes"] as? [[String: Any]] ?? []).flatMap { $0["sites"] as? [String] ?? [] }
        }
        XCTAssertEqual(try joinedSites(), ["example.com", "example.org"])
        hub.applySync(program: "edge", groupId: "e", contribution: ["scopes": [site("example.org")]], ts: Date().timeIntervalSince1970 * 1000 + 100)
        XCTAssertEqual(try joinedSites(), ["example.org"], "normal acknowledged edits replace instead of resurrecting a deleted target")
    }
    func testCompatibleAppsAndSitesDeduplicateTargetsOnOriginalJoin() {
        let sites = ConnectionHub.unionOriginalScopes([site("example.com")], incoming: [site("example.com")])
        XCTAssertEqual(sites.first?["sites"] as? [String], ["example.com"])
        let a: [String: Any] = ["id": "apps-1", "surface": "apps", "action": "block", "appsExcept": false, "apps": [["id": "one"], ["id": "two"]]]
        let b: [String: Any] = ["id": "apps-1", "surface": "apps", "action": "block", "appsExcept": false, "apps": [["id": "two"], ["id": "three"]]]
        let apps = ConnectionHub.unionOriginalScopes([a], incoming: [b])
        XCTAssertEqual((apps.first?["apps"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, ["one", "two", "three"])
    }
}
