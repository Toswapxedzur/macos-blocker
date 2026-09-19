import XCTest
@testable import MacBlockerCore

final class ActivityUsageAccumulatorTests: XCTestCase {
    private var seq = 0
    private func acc(maxStep: Double = 60) -> ActivityUsageAccumulator {
        seq = 0
        return ActivityUsageAccumulator(maxStepSeconds: maxStep, makeID: { self.seq += 1; return "id\(self.seq)" })
    }
    private func sample(_ t: Double, app: String?, active: Bool = true, label: String = "L") -> ActivitySample {
        ActivitySample(monotonic: t, wall: Date(timeIntervalSince1970: 1_600_000_000 + t), appKey: app, appLabel: label, active: active)
    }

    func testAccruesTimeForAFocusedApp() {
        let a = acc()
        XCTAssertNil(a.sample(sample(0, app: "chrome")))
        XCTAssertNil(a.sample(sample(20, app: "chrome")))
        XCTAssertNil(a.sample(sample(40, app: "chrome")))
        let r = a.flush()
        XCTAssertEqual(r?.key, "chrome")
        XCTAssertEqual(r?.seconds, 40)
        XCTAssertEqual(r?.category, .appUsage)
    }

    func testAppSwitchEmitsPreviousBucketCreditingTheInterval() {
        let a = acc()
        _ = a.sample(sample(0, app: "chrome"))
        _ = a.sample(sample(20, app: "chrome"))
        let switched = a.sample(sample(30, app: "code"))
        // the 20->30 interval belonged to chrome
        XCTAssertEqual(switched?.key, "chrome")
        XCTAssertEqual(switched?.seconds, 30)
        _ = a.sample(sample(50, app: "code"))
        XCTAssertEqual(a.flush()?.seconds, 20)
        XCTAssertEqual(a.flush()?.seconds, nil)
    }

    func testInactivityClosesBucketAndDropsTrailingInterval() {
        let a = acc()
        _ = a.sample(sample(0, app: "chrome"))
        _ = a.sample(sample(20, app: "chrome"))
        let closed = a.sample(sample(40, app: "chrome", active: false))
        XCTAssertEqual(closed?.seconds, 20, "the 20->40 idle interval is dropped, not credited")
        // returning to activity starts a fresh bucket
        XCTAssertNil(a.sample(sample(60, app: "chrome")))
        _ = a.sample(sample(80, app: "chrome"))
        XCTAssertEqual(a.flush()?.seconds, 20)
    }

    func testNoFocusedAppAccruesNothing() {
        let a = acc()
        XCTAssertNil(a.sample(sample(0, app: nil)))
        XCTAssertNil(a.sample(sample(20, app: nil)))
        XCTAssertNil(a.flush())
    }

    func testLongGapIsCappedAtMaxStep() {
        let a = acc(maxStep: 60)
        _ = a.sample(sample(0, app: "chrome"))
        // a 1-hour gap (sleep / suspended timer) must not credit an hour
        _ = a.sample(sample(3600, app: "chrome"))
        XCTAssertEqual(a.flush()?.seconds, 60)
    }

    func testZeroLengthBucketEmitsNothing() {
        let a = acc()
        _ = a.sample(sample(0, app: "chrome"))
        XCTAssertNil(a.sample(sample(0, app: "code")), "an instant switch with no elapsed time emits no record")
    }
}
