import XCTest
@testable import MacBlockerAppFeature

final class BrowserAppOverlapTests: XCTestCase {
    private func linkedHub(apps: [[String: Any]], program: String = "chrome", rolling: Bool = false) -> ConnectionHub {
        let hub = ConnectionHub()
        hub.setRoster(program: "macapp", groups: [["id": "m", "name": "Focus"]])
        hub.setRoster(program: program, groups: [["id": "b", "name": "Focus"]])
        XCTAssertNil(hub.linkGroups(program: "macapp", groupId: "m", targetProgram: program, targetGroupId: "b"))
        hub.applySync(program: "macapp", groupId: "m", contribution: [
            "scalars": ["mode": "after-minutes", "allowedMinutes": 30, "rollingLimit": rolling],
            "scopes": [["surface": "apps", "apps": apps, "action": "block"]],
            "usageResetAtMs": (Date().timeIntervalSince1970 * 1000).rounded(.down)
        ], ts: 0)
        hub.applySync(program: program, groupId: "b", contribution: [
            "scopes": [["surface": "site", "sites": ["example.com"], "action": "block"]]
        ], ts: 0)
        return hub
    }

    func testLiveWebsiteTimeIsNotAddedToWholeChromeTime() throws {
        let hub = linkedHub(apps: [["id": "com.google.Chrome"]])
        hub.applySync(program: "macapp", groupId: "m", contribution: ["usageDeltaMs": 1_000.0], ts: 0)
        hub.applySync(program: "chrome", groupId: "b", contribution: ["usageDeltaMs": 1_000.0, "usageMs": 1_000.0], ts: 0)
        XCTAssertEqual(try XCTUnwrap(hub.sharedUsage(groupID: "m")).ms, 1_000)
    }

    func testWebsiteFirstDoesNotSeedOrAccrueTheSameLiveSecond() throws {
        let hub = linkedHub(apps: [["id": "com.google.Chrome"]])
        hub.applySync(program: "chrome", groupId: "b", contribution: ["usageDeltaMs": 1_000.0, "usageMs": 1_000.0], ts: 0)
        hub.applySync(program: "macapp", groupId: "m", contribution: ["usageDeltaMs": 1_000.0], ts: 0)
        XCTAssertEqual(try XCTUnwrap(hub.sharedUsage(groupID: "m")).ms, 1_000)
    }

    func testWebsiteTimeStillCountsWithoutItsBrowserAppTarget() throws {
        let hub = linkedHub(apps: [["id": "com.example.Game"]])
        hub.applySync(program: "macapp", groupId: "m", contribution: ["usageDeltaMs": 1_000.0], ts: 0)
        hub.applySync(program: "chrome", groupId: "b", contribution: ["usageDeltaMs": 1_000.0], ts: 0)
        XCTAssertEqual(try XCTUnwrap(hub.sharedUsage(groupID: "m")).ms, 2_000)
    }

    func testOfflineBrowserTimeSurvivesTheNativeAppsCoverage() throws {
        let hub = linkedHub(apps: [["id": "com.google.Chrome"]])
        let anchor = try XCTUnwrap(hub.sharedUsage(groupID: "m")).resetAtMs
        hub.applySync(program: "macapp", groupId: "m", contribution: ["usageDeltaMs": 1_000.0], ts: 0)
        hub.applySync(program: "chrome", groupId: "b", contribution: [
            "usageDeltaMs": 2_000.0, "usageDeltaAnchorMs": anchor,
            "usageTransferId": "offline-1"
        ], ts: 0)
        XCTAssertEqual(try XCTUnwrap(hub.sharedUsage(groupID: "m")).ms, 3_000)
    }

    func testRollingBucketDoesNotDoubleCountCoveredBrowser() throws {
        let hub = linkedHub(apps: [["id": "com.google.Chrome"]], rolling: true)
        let minute = (Date().timeIntervalSince1970 * 1000 / 60_000).rounded(.down) * 60_000
        hub.applySync(program: "macapp", groupId: "m", contribution: ["usageBuckets": [String(Int(minute)): 1_000.0]], ts: 0)
        hub.applySync(program: "chrome", groupId: "b", contribution: ["usageBuckets": [String(Int(minute)): 1_000.0]], ts: 0)
        XCTAssertEqual(try XCTUnwrap(hub.sharedUsage(groupID: "m")).buckets[minute], 1_000)
    }

    func testOnlyItsOwnBrowserProgramIsCoalesced() {
        let chromeLine: [[String: Any]] = [["surface": "apps", "apps": [["id": "com.google.Chrome"]]]]
        XCTAssertTrue(ConnectionHub.countsWholeBrowser(chromeLine, program: "chrome"))
        XCTAssertFalse(ConnectionHub.countsWholeBrowser(chromeLine, program: "edge"))
        XCTAssertFalse(ConnectionHub.countsWholeBrowser(chromeLine, program: "safari"))
        XCTAssertTrue(ConnectionHub.countsWholeBrowser(
            [["surface": "apps", "appsExcept": true, "apps": [["id": "com.example.Editor"]]]], program: "safari"))
    }
}
