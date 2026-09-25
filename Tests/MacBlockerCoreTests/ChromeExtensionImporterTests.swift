import XCTest
@testable import MacBlockerCore

final class ChromeExtensionImporterTests: XCTestCase {
    func testImportsSiteGroup() throws {
        let json = """
        [
          {
            "id": "group-1",
            "groupType": "site",
            "name": "Blocked Sites",
            "enabled": true,
            "mode": "instant",
            "sites": ["https://www.example.com/", "https://www.example.com/docs"],
            "activeDays": ["monday", "tuesday"],
            "timeWindowsText": "0900-1000"
          }
        ]
        """.data(using: .utf8)!

        let result = try ChromeExtensionImporter.importGroups(from: json)

        XCTAssertEqual(result.groups.count, 1)
        XCTAssertEqual(result.groups[0].targets.map(\.normalizedValue), ["example.com"], "the path-scoped entry is skipped, not widened to its host")
        XCTAssertTrue(result.warnings.contains { $0.contains("path-scoped") && $0.contains("example.com/docs") })
        XCTAssertEqual(result.groups[0].activeDays, [.monday, .tuesday])
        XCTAssertEqual(result.groups[0].timeWindows.count, 1)
    }

    func testImportsSiteLineFromScopes() throws {
        // The scoped shape (policy + lines): the site list lives in a "site" line
        // and the group may name platforms as well.
        let json = """
        [
          {
            "id": "group-2",
            "groupType": "youtube",
            "name": "Union",
            "enabled": true,
            "mode": "instant",
            "scopes": [
              {"id": "items-1", "surface": "items", "platform": "youtube", "action": "hide", "form": "all", "sourceMode": "all", "sources": [], "tagFilter": null},
              {"id": "site-1", "surface": "site", "platform": null, "action": "block", "sites": ["example.com", "news.ycombinator.com/best"], "sitesExcept": false}
            ]
          }
        ]
        """.data(using: .utf8)!

        let result = try ChromeExtensionImporter.importGroups(from: json)

        XCTAssertEqual(result.groups.count, 1)
        XCTAssertEqual(result.groups[0].targets.map(\.normalizedValue), ["example.com"])
        XCTAssertTrue(result.warnings.contains { $0.contains("path-scoped") })
    }

    func testAPausedWebsiteListIsNotEnforcedNatively() throws {
        let json = """
        [
          {
            "id": "group-3",
            "groupType": "site",
            "name": "Pause news",
            "enabled": true,
            "mode": "instant",
            "scopes": [
              {"id": "site-1", "surface": "site", "platform": null, "action": "pause", "sites": ["news.example.com"], "sitesExcept": false}
            ]
          }
        ]
        """.data(using: .utf8)!

        let result = try ChromeExtensionImporter.importGroups(from: json)

        XCTAssertEqual(result.groups[0].targets.count, 0, "a pause action is browser-only; the Mac must not hard-block the site")
        XCTAssertTrue(result.warnings.contains { $0.contains("pause") })
    }

    func testImportsAppsEverythingExcept() throws {
        let json = """
        [
          {
            "id": "group-4",
            "name": "Deep work",
            "enabled": true,
            "mode": "instant",
            "scopes": [
              {"id": "apps-1", "surface": "apps", "platform": null, "action": "block", "apps": [{"id": "com.example.Editor", "name": "Editor"}], "appsExcept": true}
            ]
          }
        ]
        """.data(using: .utf8)!

        let result = try ChromeExtensionImporter.importGroups(from: json)

        XCTAssertTrue(result.groups[0].applicationAllowlist)
        XCTAssertEqual(result.groups[0].targets.map(\.id), ["com.example.Editor"], "the listed apps are the allowed ones")
    }

    func testImportsFractionalIntervalAndResetFlags() throws {
        let json = """
        [{"id": "g", "groupType": "site", "mode": "after-minutes", "allowedMinutes": 7.5,
          "resetIntervalHours": 2.5, "resetAtMidnight": true, "rollingLimit": true,
          "timeWindowsText": "2300-0100"}]
        """.data(using: .utf8)!

        let group = try XCTUnwrap(ChromeExtensionImporter.importGroups(from: json).groups.first)

        XCTAssertEqual(group.resetIntervalHours, 2.5, "2.5 h must not truncate to 2")
        XCTAssertEqual(group.allowedMinutes, 7.5)
        XCTAssertTrue(group.resetAtMidnight)
        XCTAssertTrue(group.rollingLimit)
        XCTAssertEqual(group.timeWindows.count, 1, "a window crossing midnight survives import")
    }
}
