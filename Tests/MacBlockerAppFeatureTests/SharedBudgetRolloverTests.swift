import XCTest
@testable import MacBlockerAppFeature
@testable import MacBlockerCore

/// A clustered fixed budget rolls over from the SHARED anchor, so the Mac can
/// end a period the browser never saw end (and can never wipe a live one).
final class SharedBudgetRolloverTests: XCTestCase {
    private func group(hours: Double, midnight: Bool = false) -> BlockGroup {
        BlockGroup(id: "g", groupType: .app, name: "g", enabled: true, mode: .afterMinutes,
                   allowedMinutes: 30, resetIntervalHours: hours, resetAtMidnight: midnight)
    }

    func testNoRolloverInsideThePeriodOrWithoutAnAnchor() {
        let anchor = 1_000_000.0
        XCTAssertEqual(MacEnforcementBridge.sharedRolloverMs(sharedAnchorMs: anchor, group: group(hours: 1), nowMs: anchor + 30 * 60_000), 0)
        XCTAssertEqual(MacEnforcementBridge.sharedRolloverMs(sharedAnchorMs: 0, group: group(hours: 1), nowMs: anchor * 10), 0,
                       "no shared anchor yet: the Mac never invents one")
    }

    func testRolloverAfterThePeriodIsTheNextGridStart() {
        let anchor = 1_000_000.0
        let hour = 3_600_000.0
        XCTAssertEqual(MacEnforcementBridge.sharedRolloverMs(sharedAnchorMs: anchor, group: group(hours: 1), nowMs: anchor + 2.5 * hour),
                       anchor + 2 * hour, "every member computes the same value from the shared anchor")
    }
}
