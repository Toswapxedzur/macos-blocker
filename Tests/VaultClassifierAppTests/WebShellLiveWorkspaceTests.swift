import Foundation
import XCTest
@testable import VaultClassifierApp

final class WebShellLiveWorkspaceTests: XCTestCase {
    func testBundledShellContainsOnlyLiveWorkspacesAndActions() throws {
        let appURL = try XCTUnwrap(VaultClassifierWebShell.bundledWebAssetURL(named: "app", extension: "js"))
        let script = try String(contentsOf: appURL, encoding: .utf8)

        for liveWorkspace in ["tagTree", "localModel", "llmAssist", "browserBridge", "classificationData"] {
            XCTAssertTrue(script.contains(liveWorkspace))
        }
        for retired in [
            "recordCreatorClassification", "classifyWithLLM", "markCorrection",
            "clearCorrection", "storeTraining", "retrain", "activityWorkspace",
            "inspectWorkspace", "trainingWorkspace",
        ] {
            XCTAssertFalse(script.contains(retired), "Retired web action or workspace remains: \(retired)")
        }
    }

    func testShellRetainsVideoCollectionLazyLoadChannel() throws {
        let appURL = try XCTUnwrap(VaultClassifierWebShell.bundledWebAssetURL(named: "app", extension: "js"))
        let script = try String(contentsOf: appURL, encoding: .utf8)
        XCTAssertTrue(script.contains("loadCreatorEntries"))
        XCTAssertTrue(script.contains("receiveCreatorEntries"))
        XCTAssertTrue(script.contains("classificationDataWorkspace"))
    }
}
