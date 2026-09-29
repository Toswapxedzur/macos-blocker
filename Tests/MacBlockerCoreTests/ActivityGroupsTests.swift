import XCTest
@testable import MacBlockerCore

final class ActivityGroupsTests: XCTestCase {
    private var counter = 0
    private func newID() -> String { counter += 1; return "g\(counter)" }

    private func save(_ group: ActivityGroup, _ groups: [ActivityGroup], move: Bool = false) -> Result<(groups: [ActivityGroup], id: String), ActivityGroupRefusal> {
        ActivityGroups.saving(group, into: groups, move: move, newID: newID)
    }

    func testAGroupNeedsANameAndAppOrSiteMembers() {
        XCTAssertEqual(try? save(ActivityGroup(id: "", name: "  ", merge: false, members: []), []).get().id, nil)
        guard case .failure(.badMember("slack")) = save(ActivityGroup(id: "", name: "Work", merge: false, members: ["slack"]), []) else {
            return XCTFail("a member must be app|… or web|…")
        }
        let saved = try? save(ActivityGroup(id: "", name: " Work ", merge: false, members: ["app|a", "web|b.com", "app|a"]), []).get()
        XCTAssertEqual(saved?.id, "g1")
        XCTAssertEqual(saved?.groups.first?.name, "Work")
        XCTAssertEqual(saved?.groups.first?.members, ["app|a", "web|b.com"], "duplicates dropped")
    }

    func testAnItemCanBeInManyViewGroupsButOneMergeGroup() throws {
        var groups = try save(ActivityGroup(id: "", name: "Chat", merge: true, members: ["app|messages", "app|whatsapp"]), []).get().groups
        groups = try save(ActivityGroup(id: "", name: "Evening", merge: false, members: ["app|messages", "web|youtube.com"]), groups).get().groups
        XCTAssertEqual(groups.count, 2, "a view group shares members freely")
        guard case .failure(.inAnotherMergeGroup(let owners)) = save(ActivityGroup(id: "", name: "Social", merge: true, members: ["app|whatsapp", "web|x.com"]), groups) else {
            return XCTFail("a second merge group may not take a member")
        }
        XCTAssertEqual(owners, ["app|whatsapp": "Chat"])
        let moved = try save(ActivityGroup(id: "", name: "Social", merge: true, members: ["app|whatsapp", "web|x.com"]), groups, move: true).get().groups
        XCTAssertEqual(moved.first { $0.name == "Chat" }?.members, ["app|messages"], "moved out of its old merge group")
        XCTAssertEqual(ActivityGroups.mergeOwners(moved)["app|whatsapp"], moved.first { $0.name == "Social" }?.id)
        XCTAssertNil(ActivityGroups.mergeOwners(moved)["web|youtube.com"], "view groups own nothing")
    }

    func testTurningMergeOnChecksTheSameRule() throws {
        var groups = try save(ActivityGroup(id: "", name: "Chat", merge: true, members: ["app|messages"]), []).get().groups
        let saved = try save(ActivityGroup(id: "", name: "Evening", merge: false, members: ["app|messages"]), groups).get()
        groups = saved.groups
        guard case .failure(.inAnotherMergeGroup) = save(ActivityGroup(id: saved.id, name: "Evening", merge: true, members: ["app|messages"]), groups) else {
            return XCTFail("switching a view group to merge must not steal a member")
        }
    }

    func testGroupTimeCountsOverlapsOnce() {
        func record(_ key: String, _ start: Double, _ seconds: Double) -> ActivityRecord {
            ActivityRecord(id: UUID().uuidString, category: .appUsage, startedAt: Date(timeIntervalSince1970: start), seconds: seconds, key: key, label: key)
        }
        // Chrome 0-100 with youtube 10-40 inside it, and Slack 90-150 overlapping Chrome's end.
        let union = ActivityDashboard.union([record("chrome", 0, 100), record("youtube", 10, 30), record("slack", 90, 60), record("mail", 200, 10)])
        XCTAssertEqual(union.map(\.seconds), [150, 10])
    }

    func testStoreKeepsGroupsAndGivesEachAColour() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ActivityStore(directory: directory)
        let id = try store.saveGroup(ActivityGroup(id: "", name: "Work", merge: true, members: ["app|code"])).get()
        XCTAssertEqual(store.groups().map(\.name), ["Work"])
        let snapshot = store.dashboardSnapshot(from: Date().addingTimeInterval(-3600), to: Date())
        XCTAssertEqual(snapshot.groups.map(\.id), [id])
        XCTAssertEqual(store.colorIndices(for: [])["group|" + id], snapshot.groups[0].colorIndex, "a group has a permanent colour")
        XCTAssertTrue(store.deleteGroup(id: id))
        XCTAssertTrue(store.groups().isEmpty)
    }
}
