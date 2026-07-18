import XCTest
@testable import VaultClassifierApp

final class WorkspaceNavigationTests: XCTestCase {
    func testWorkspaceIdentifiersIncludeEachRenderedLocalTool() {
        let identifiers = Set(VaultClassifierViewModel.Workspace.allCases.map(\.rawValue))

        XCTAssertTrue([
            "tagTree", "localModel", "llmAssist", "browserBridge", "classificationData",
            "inspect", "policies", "activity", "training", "backup", "audit",
        ].allSatisfy(identifiers.contains))
    }
}
