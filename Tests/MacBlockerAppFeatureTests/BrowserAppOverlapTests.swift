import Foundation
import XCTest
import VaultClassifierBridge
import Network
@testable import MacBlockerAppFeature

final class BrowserAppOverlapTests: XCTestCase {
    private var suites: [String] = []
    override func tearDown() {
        for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
        suites.removeAll()
        super.tearDown()
    }
    private func apply(_ hub: ConnectionHub, program: String, groupId: String, contribution: [String: Any], ts: Double) {
        let app = ["chrome": "com.google.chrome", "edge": "com.microsoft.edgemac", "safari": "com.apple.safari"][program]
        hub.applySync(program: program, groupId: groupId, contribution: contribution, ts: ts,
                      browserIdentity: app.flatMap { BrowserApplicationIdentity(kind: "mac-bundle-id", value: $0) })
    }
    private func linkedHub(apps: [[String: Any]], program: String = "chrome", rolling: Bool = false) -> ConnectionHub {
        let suite = "Agentic.BrowserAppOverlap." + UUID().uuidString
        suites.append(suite)
        let hub = ConnectionHub(registryDefaults: UserDefaults(suiteName: suite)!)
        hub.setRoster(program: "macapp", groups: [["id": "m", "name": "Focus"]])
        hub.setRoster(program: program, groups: [["id": "b", "name": "Focus"]])
        XCTAssertNil(hub.linkGroups(program: "macapp", groupId: "m", targetProgram: program, targetGroupId: "b"))
        apply(hub, program: "macapp", groupId: "m", contribution: [
            "scalars": ["mode": "after-minutes", "allowedMinutes": 30, "rollingLimit": rolling],
            "scopes": [["surface": "apps", "apps": apps, "action": "block"]],
            "usageResetAtMs": (Date().timeIntervalSince1970 * 1000).rounded(.down)
        ], ts: 0)
        apply(hub, program: program, groupId: "b", contribution: [
            "scopes": [["surface": "site", "sites": ["example.com"], "action": "block"]],
            "usageMs": 0.0, "usageBucketsSeed": [String: Double](), "usageResetAtMs": Date().timeIntervalSince1970 * 1000
        ], ts: 0)
        return hub
    }

    func testLiveWebsiteTimeIsNotAddedToWholeChromeTime() throws {
        let hub = linkedHub(apps: [["id": "com.google.Chrome"]])
        apply(hub, program: "macapp", groupId: "m", contribution: ["usageDeltaMs": 1_000.0], ts: 0)
        apply(hub, program: "chrome", groupId: "b", contribution: ["usageDeltaMs": 1_000.0, "usageMs": 1_000.0], ts: 0)
        XCTAssertEqual(try XCTUnwrap(hub.sharedUsage(groupID: "m")).ms, 1_000)
    }

    func testWebsiteFirstDoesNotSeedOrAccrueTheSameLiveSecond() throws {
        let hub = linkedHub(apps: [["id": "com.google.Chrome"]])
        apply(hub, program: "chrome", groupId: "b", contribution: ["usageDeltaMs": 1_000.0, "usageMs": 1_000.0], ts: 0)
        apply(hub, program: "macapp", groupId: "m", contribution: ["usageDeltaMs": 1_000.0], ts: 0)
        XCTAssertEqual(try XCTUnwrap(hub.sharedUsage(groupID: "m")).ms, 1_000)
    }

    func testWebsiteTimeStillCountsWithoutItsBrowserAppTarget() throws {
        let hub = linkedHub(apps: [["id": "com.example.Game"]])
        apply(hub, program: "macapp", groupId: "m", contribution: ["usageDeltaMs": 1_000.0], ts: 0)
        apply(hub, program: "chrome", groupId: "b", contribution: ["usageDeltaMs": 1_000.0], ts: 0)
        XCTAssertEqual(try XCTUnwrap(hub.sharedUsage(groupID: "m")).ms, 2_000)
    }

    func testOfflineBrowserTimeSurvivesTheNativeAppsCoverage() throws {
        let hub = linkedHub(apps: [["id": "com.google.Chrome"]])
        let anchor = try XCTUnwrap(hub.sharedUsage(groupID: "m")).resetAtMs
        apply(hub, program: "macapp", groupId: "m", contribution: ["usageDeltaMs": 1_000.0], ts: 0)
        apply(hub, program: "chrome", groupId: "b", contribution: [
            "usageDeltaMs": 2_000.0, "usageDeltaAnchorMs": anchor,
            "usageTransferId": "offline-1"
        ], ts: 0)
        XCTAssertEqual(try XCTUnwrap(hub.sharedUsage(groupID: "m")).ms, 3_000)
    }

    func testRollingBucketDoesNotDoubleCountCoveredBrowser() throws {
        let hub = linkedHub(apps: [["id": "com.google.Chrome"]], rolling: true)
        let minute = (Date().timeIntervalSince1970 * 1000 / 60_000).rounded(.down) * 60_000
        apply(hub, program: "macapp", groupId: "m", contribution: ["usageBuckets": [String(Int(minute)): 1_000.0]], ts: 0)
        apply(hub, program: "chrome", groupId: "b", contribution: ["usageBuckets": [String(Int(minute)): 1_000.0]], ts: 0)
        XCTAssertEqual(try XCTUnwrap(hub.sharedUsage(groupID: "m")).buckets[minute], 1_000)
    }

    func testOrdinarySafariAssociationCountsOnlyOrdinarySafariWithoutAttestation() throws {
        XCTAssertEqual(ConnectionHub.browserUsageAssociation(program: "safari", browserIdentity: nil), .ordinarySafari)
        XCTAssertNil(ConnectionHub.browserUsageAssociation(program: "chrome", browserIdentity: nil))
        for appID in ["com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.apple.Safari.WebApp.example", "com.example.CustomBrowser", "com.google.Chrome"] {
            let hub = linkedHub(apps: [["id": appID]], program: "safari")
            hub.applySync(program: "macapp", groupId: "m", contribution: ["usageDeltaMs": 1_000.0], ts: 0)
            hub.applySync(program: "safari", groupId: "b", contribution: ["usageDeltaMs": 1_000.0], ts: 0)
            XCTAssertEqual(try XCTUnwrap(hub.sharedUsage(groupID: "m")).ms, appID == "com.apple.Safari" ? 1_000 : 2_000)
        }
        let stp = try XCTUnwrap(BrowserApplicationIdentity(kind: "mac-bundle-id", value: "com.apple.safaritechnologypreview"))
        XCTAssertEqual(ConnectionHub.browserUsageAssociation(program: "safari", browserIdentity: stp), .attested(stp))
        XCTAssertFalse(ConnectionHub.countsWholeBrowser([["surface": "apps", "apps": [["id": "com.apple.Safari"]]]], program: "safari", browserIdentity: stp))
        XCTAssertTrue(ConnectionHub.countsWholeBrowser([["surface": "apps", "apps": [["id": "com.apple.SafariTechnologyPreview"]]]], program: "safari", browserIdentity: stp))
    }

    func testOrdinarySafariAssociationKeepsTaggedOfflineUsageAdditive() throws {
        let hub = linkedHub(apps: [["id": "com.apple.Safari"]], program: "safari")
        let anchor = try XCTUnwrap(hub.sharedUsage(groupID: "m")).resetAtMs
        hub.applySync(program: "macapp", groupId: "m", contribution: ["usageDeltaMs": 1_000.0], ts: 0)
        let transfer: [String: Any] = ["usageDeltaMs": 2_000.0, "usageDeltaAnchorMs": anchor, "usageTransferId": "safari-offline"]
        hub.applySync(program: "safari", groupId: "b", contribution: transfer, ts: 0)
        hub.applySync(program: "safari", groupId: "b", contribution: transfer, ts: 0)
        XCTAssertEqual(try XCTUnwrap(hub.sharedUsage(groupID: "m")).ms, 3_000)
    }

    func testOnlyItsOwnBrowserProgramIsCoalesced() {
        let chromeLine: [[String: Any]] = [["surface": "apps", "apps": [["id": "com.google.Chrome"]]]]
        XCTAssertTrue(ConnectionHub.countsWholeBrowser(chromeLine, browserIdentity: BrowserApplicationIdentity(kind: "mac-bundle-id", value: "com.google.chrome")))
        XCTAssertFalse(ConnectionHub.countsWholeBrowser(chromeLine, browserIdentity: BrowserApplicationIdentity(kind: "mac-bundle-id", value: "com.microsoft.edgemac")))
        XCTAssertFalse(ConnectionHub.countsWholeBrowser(chromeLine, browserIdentity: BrowserApplicationIdentity(kind: "mac-bundle-id", value: "com.apple.safari")))
        XCTAssertTrue(ConnectionHub.countsWholeBrowser(
            [["surface": "apps", "appsExcept": true, "apps": [["id": "com.example.Editor"]]]], browserIdentity: BrowserApplicationIdentity(kind: "mac-bundle-id", value: "com.apple.safari")))
    }

    func testBrowserFamilyDoesNotStandInForItsActualApplication() throws {
        let hub = linkedHub(apps: [["id": "com.brave.Browser"]])
        apply(hub, program: "macapp", groupId: "m", contribution: ["usageDeltaMs": 1_000.0], ts: 0)
        apply(hub, program: "chrome", groupId: "b", contribution: ["usageDeltaMs": 1_000.0], ts: 0)
        XCTAssertEqual(try XCTUnwrap(hub.sharedUsage(groupID: "m")).ms, 2_000)
    }

    func testActualApplicationUsesNativeCaseAndHelperMatching() throws {
        let identity = try XCTUnwrap(BrowserApplicationIdentity(kind: "mac-bundle-id", value: "com.google.chrome"))
        XCTAssertTrue(ConnectionHub.countsWholeBrowser(
            [["surface": "apps", "apps": [["id": "COM.GOOGLE.CHROME"]]]], browserIdentity: identity))
        XCTAssertFalse(ConnectionHub.countsWholeBrowser(
            [["surface": "apps", "apps": [["id": "com.google.Chrome.helper"]]]], browserIdentity: identity))
        XCTAssertFalse(ConnectionHub.countsWholeBrowser(
            [["surface": "apps", "action": "allow", "apps": [["id": "com.google.Chrome"]]]], browserIdentity: identity))
    }

    func testAppsExceptUsesOnlyTheActualBrowser() throws {
        let identity = try XCTUnwrap(BrowserApplicationIdentity(kind: "mac-bundle-id", value: "com.google.chrome"))
        XCTAssertFalse(ConnectionHub.countsWholeBrowser(
            [["surface": "apps", "appsExcept": true, "apps": [["id": "com.google.Chrome"]]]], browserIdentity: identity))
        XCTAssertTrue(ConnectionHub.countsWholeBrowser(
            [["surface": "apps", "appsExcept": true, "apps": [["id": "com.brave.Browser"]]]], browserIdentity: identity))
        XCTAssertFalse(ConnectionHub.countsWholeBrowser(
            [["surface": "apps", "appsExcept": true, "apps": []]], browserIdentity: nil))
    }

    func testUnsupportedPlatformIdentityCannotCoverNativeApps() throws {
        let identity = try XCTUnwrap(BrowserApplicationIdentity(kind: "windows-exe-sha256", value: String(repeating: "a", count: 64)))
        XCTAssertFalse(ConnectionHub.countsWholeBrowser(
            [["surface": "apps", "appsExcept": true, "apps": []]], browserIdentity: identity))
    }

    func testContributionIdentityCannotReplaceAuthenticatedDescriptor() throws {
        let hub = linkedHub(apps: [["id": "com.brave.Browser"]])
        apply(hub, program: "macapp", groupId: "m", contribution: ["usageDeltaMs": 1_000.0], ts: 0)
        apply(hub, program: "chrome", groupId: "b", contribution: [
            "usageDeltaMs": 1_000.0,
            "browserIdentity": ["v": 1, "kind": "mac-bundle-id", "value": "com.brave.browser"]
        ], ts: 0)
        XCTAssertEqual(try XCTUnwrap(hub.sharedUsage(groupID: "m")).ms, 2_000)
    }

    func testOfflineTransferRemainsAdditiveAndDeduplicatedWithActualIdentity() throws {
        let hub = linkedHub(apps: [["id": "com.google.Chrome"]])
        let anchor = try XCTUnwrap(hub.sharedUsage(groupID: "m")).resetAtMs
        let transfer: [String: Any] = ["usageDeltaMs": 2_000.0, "usageDeltaAnchorMs": anchor, "usageTransferId": "offline-exact"]
        apply(hub, program: "macapp", groupId: "m", contribution: ["usageDeltaMs": 1_000.0], ts: 0)
        apply(hub, program: "chrome", groupId: "b", contribution: transfer, ts: 0)
        apply(hub, program: "chrome", groupId: "b", contribution: transfer, ts: 0)
        XCTAssertEqual(try XCTUnwrap(hub.sharedUsage(groupID: "m")).ms, 3_000)
    }

    func testNetworkContributionUsesItsPeerDescriptorAndIgnoresClaimedIdentity() throws {
        let hub = linkedHub(apps: [["id": "com.brave.Browser"]])
        let connection = NWConnection(host: "127.0.0.1", port: 18787, using: .tcp)
        defer { connection.cancel() }
        hub.registerPendingPeer(connection, challenge: String(repeating: "a", count: 43))
        let identity = try XCTUnwrap(BrowserApplicationIdentity(kind: "mac-bundle-id", value: "com.google.chrome"))
        XCTAssertNil(hub.admitAuthenticatedPeer(connection, program: "chrome", browserIdentity: identity))
        let frame: [String: Any] = ["kind": "group-sync", "groupId": "b", "program": "edge", "usageDeltaMs": 1_000.0,
            "browserIdentity": ["v": 1, "kind": "mac-bundle-id", "value": "com.brave.browser"]]
        hub.handleIncoming(connection, key: ObjectIdentifier(connection), data: try JSONSerialization.data(withJSONObject: frame))
        XCTAssertEqual(try XCTUnwrap(hub.sharedUsage(groupID: "m")).ms, 1_000)
    }
}
