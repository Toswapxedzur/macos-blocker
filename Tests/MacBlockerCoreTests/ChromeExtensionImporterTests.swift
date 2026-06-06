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
}
