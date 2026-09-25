import XCTest
@testable import MacBlockerAppFeature

/// The floating "+" follows the editor's switch and chosen group in the store.
@MainActor
final class QuickAddPanelTests: XCTestCase {
    private func store(enabled: Bool?, groupID: String?, groups: [[String: Any]]) -> [String: Any] {
        var raw: [String: Any] = ["blockedGroups": groups]
        if let enabled { raw["globalSettings"] = ["quickAddEnabled": enabled] }
        if let groupID { raw["quickAddGroupId"] = groupID }
        return raw
    }
    private let groups: [[String: Any]] = [["id": "g1", "groupType": "site"], ["id": "c1", "groupType": "custom"]]

    func testOffByDefault() {
        XCTAssertNil(QuickAddPanel.target(in: store(enabled: nil, groupID: "g1", groups: groups)))
        XCTAssertNil(QuickAddPanel.target(in: store(enabled: false, groupID: "g1", groups: groups)))
    }

    func testNeedsAChosenExistingNormalGroup() {
        XCTAssertEqual(QuickAddPanel.target(in: store(enabled: true, groupID: "g1", groups: groups)), "g1")
        XCTAssertNil(QuickAddPanel.target(in: store(enabled: true, groupID: nil, groups: groups)), "no badge chosen yet")
        XCTAssertNil(QuickAddPanel.target(in: store(enabled: true, groupID: "gone", groups: groups)), "the chosen group was deleted")
        XCTAssertNil(QuickAddPanel.target(in: store(enabled: true, groupID: "c1", groups: groups)), "custom rules have no entries")
    }
}
