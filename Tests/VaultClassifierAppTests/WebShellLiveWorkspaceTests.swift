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

    func testShellContainsOnlyEffectivePerTypeLocalModelOverrides() throws {
        let appURL = try XCTUnwrap(VaultClassifierWebShell.bundledWebAssetURL(named: "app", extension: "js"))
        let script = try String(contentsOf: appURL, encoding: .utf8)
        XCTAssertTrue(script.contains("saveClassifierTypeLocalModel"))
        XCTAssertTrue(script.contains("toggleLocalModelAdvanced"))
        XCTAssertTrue(script.contains("classifier-local-model-form-"))
        let overrideStart = try XCTUnwrap(script.range(of: "const localModelOverrideBody"))
        let overrideEnd = try XCTUnwrap(script.range(of: "const localModelOverrideSection", range: overrideStart.upperBound..<script.endIndex))
        let overrideBody = String(script[overrideStart.lowerBound..<overrideEnd.lowerBound])
        XCTAssertTrue(overrideBody.contains("houseRules"))
        XCTAssertTrue(overrideBody.contains("allowDecline"))
        XCTAssertTrue(overrideBody.contains("confidenceBand"))
        XCTAssertFalse(overrideBody.contains("maximumTags"))
    }

    func testShellDisclosesOptInResearchDataFlow() throws {
        let appURL = try XCTUnwrap(VaultClassifierWebShell.bundledWebAssetURL(named: "app", extension: "js"))
        let stringsURL = try XCTUnwrap(VaultClassifierWebShell.bundledWebAssetURL(named: "strings", extension: "js"))
        let script = try String(contentsOf: appURL, encoding: .utf8)
        let strings = try String(contentsOf: stringsURL, encoding: .utf8)

        XCTAssertTrue(script.contains("saveResearchSettings"))
        XCTAssertTrue(script.contains("research.consent"))
        XCTAssertTrue(script.contains("supportsGenerateText"))
        XCTAssertTrue(strings.contains("Raw video titles, summaries, body text, and private creator IDs are never sent"))
        XCTAssertTrue(strings.contains("explicit local-model decline or a correction you submit"))
        XCTAssertFalse(strings.contains("Everything runs on this Mac; nothing leaves it"))
    }

    func testCollectionEntriesExposeCorrectionEditorWithoutANewHubOperation() throws {
        let appURL = try XCTUnwrap(VaultClassifierWebShell.bundledWebAssetURL(named: "app", extension: "js"))
        let script = try String(contentsOf: appURL, encoding: .utf8)
        XCTAssertTrue(script.contains("submitCorrection"))
        XCTAssertTrue(script.contains("correctTagIDs"))
        XCTAssertTrue(script.contains("correctionForms"))
        XCTAssertFalse(script.contains("correction-tags-updated"))
        XCTAssertFalse(script.contains("research-tags-updated"))
    }
}
