import XCTest
@testable import MacBlockerCore

final class EnforcementPlanTests: XCTestCase {
    func testBuilderSplitsTargetsByKindAndSkipsDisabled() throws {
        let groups = [
            BlockGroup(
                id: "g1",
                groupType: .app,
                name: "Social",
                enabled: true,
                mode: .instant,
                targets: [
                    BlockTarget(id: "app1", kind: .application, displayName: "A", normalizedValue: "app1"),
                    BlockTarget(id: "cat1", kind: .category, displayName: "C", normalizedValue: "cat1"),
                    BlockTarget(id: "web1", kind: .webDomain, displayName: "W", normalizedValue: "web1")
                ]
            ),
            BlockGroup(id: "g2", name: "Disabled", enabled: false)
        ]

        let plan = EnforcementPlanBuilder.build(from: groups)

        XCTAssertEqual(plan.entries.count, 1)
        let entry = try XCTUnwrap(plan.entry(forGroupID: "g1"))
        XCTAssertEqual(entry.applicationTargetIDs, ["app1"])
        XCTAssertEqual(entry.categoryTargetIDs, ["cat1"])
        XCTAssertEqual(entry.webDomainTargetIDs, ["web1"])
    }

    func testTimedGroupCarriesThreshold() {
        let group = BlockGroup(
            id: "timed",
            name: "Timed",
            enabled: true,
            mode: .afterMinutes,
            allowedMinutes: 20,
            targets: [BlockTarget(id: "app1", kind: .application, displayName: "A", normalizedValue: "app1")]
        )

        let plan = EnforcementPlanBuilder.build(from: [group])

        XCTAssertEqual(plan.entry(forGroupID: "timed")?.thresholdMinutes, 20)
    }

    func testCustomGroupRequiresHostEvaluation() {
        let group = BlockGroup(id: "c", groupType: .custom, name: "Custom", enabled: true)
        let plan = EnforcementPlanBuilder.build(from: [group])
        XCTAssertEqual(plan.entry(forGroupID: "c")?.requiresHostEvaluation, true)
    }

    func testSharedStorePlanRoundTrip() throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = SharedAppGroupStore(baseDirectory: tempDir)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let plan = EnforcementPlanBuilder.build(from: [
            BlockGroup(id: "g1", name: "G1", enabled: true)
        ])
        store.saveEnforcementPlan(plan)

        let loaded = try XCTUnwrap(store.loadEnforcementPlan())
        XCTAssertEqual(loaded.entries.map(\.groupID), ["g1"])
    }

    func testSnoozeRequestAppendAndClear() {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = SharedAppGroupStore(baseDirectory: tempDir)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        store.appendSnoozeRequest(SnoozeRequest(groupID: "g1", targetKind: .application))
        store.appendSnoozeRequest(SnoozeRequest(groupID: "g2", targetKind: .webDomain))
        XCTAssertEqual(store.loadSnoozeRequests().count, 2)

        store.clearSnoozeRequests()
        XCTAssertTrue(store.loadSnoozeRequests().isEmpty)
    }
}
