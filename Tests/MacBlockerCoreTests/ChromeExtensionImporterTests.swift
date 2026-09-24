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
            "sites": ["https://www.example.com/path"],
            "activeDays": ["monday", "tuesday"],
            "timeWindowsText": "0900-1000"
          }
        ]
        """.data(using: .utf8)!

        let result = try ChromeExtensionImporter.importGroups(from: json)

        XCTAssertEqual(result.groups.count, 1)
        XCTAssertEqual(result.groups[0].targets.first?.normalizedValue, "example.com")
        XCTAssertEqual(result.groups[0].activeDays, [.monday, .tuesday])
        XCTAssertEqual(result.groups[0].timeWindows.count, 1)
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
