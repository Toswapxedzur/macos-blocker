import Foundation
import XCTest
@testable import VaultClassifierApp

@MainActor
final class DormantKnowledgeSurfaceTests: XCTestCase {
    func testRetiredKnowledgeCannotBeReachedThroughSnapshotOrActions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try VaultClassifierViewModel(headlessVaultDirectory: directory)
        let snapshot = model.webSnapshot()
        let settings = try XCTUnwrap(snapshot["settings"] as? [String: Any]), assets = try XCTUnwrap(snapshot["assets"] as? [String: Any])
        XCTAssertNil(settings["dictionaries"]); XCTAssertNil(settings["research"]); XCTAssertNil(assets["knowledge"])
        let names = Set(ClassifierWebActionCatalog.actions.map(\.name))
        for retired in ["knowledgePage", "importPersonalDictionary", "exportPersonalDictionary", "addKnowledgeTerm", "addKnowledgeCreator", "editKnowledgeEntry", "deleteKnowledgeEntry", "saveDictionarySettings", "completeDictionaryOnboarding", "checkDictionaryUpdates", "downloadDictionary", "saveResearchSettings", "saveClassifierTypeResearch", "retryFailedResearch"] {
            XCTAssertFalse(names.contains(retired), retired)
            XCTAssertTrue(model.performWebAction(retired, data: [:]))
            XCTAssertNotNil(model.issue, retired)
        }
        XCTAssertTrue(model.performWebAction("workspace", data: ["workspace": "knowledge"]))
        XCTAssertEqual(model.workspace.rawValue, "browserBridge")
        XCTAssertNotNil(model.issue)
    }
}
