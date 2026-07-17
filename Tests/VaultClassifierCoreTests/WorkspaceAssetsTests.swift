import XCTest
@testable import VaultClassifierCore

final class WorkspaceAssetsTests: XCTestCase {
    func testStarterCatalogBindsOneTreeAndDatasetToYouTube() {
        let catalog = WorkspaceCatalog.starter()
        let binding = try! XCTUnwrap(catalog.bindings.first)
        XCTAssertEqual(binding.id, "youtube")
        XCTAssertEqual(catalog.trees.filter { $0.id == binding.treeID }.count, 1)
        XCTAssertEqual(catalog.datasets.filter { $0.id == binding.datasetID }.count, 1)
        XCTAssertEqual(catalog.models.first?.treeRevision, catalog.trees.first?.revision)
        XCTAssertEqual(catalog.models.first?.datasetRevision, catalog.datasets.first?.revision)
        XCTAssertTrue(catalog.trees.first?.nodes.isEmpty == true)
    }

    func testTagNodeCanvasPositionRoundTripsAndLegacyNodeDefaultsToUnplaced() throws {
        let positioned = TagTreeNode(id: "topic", name: "Topic", positionX: 184, positionY: 96)
        let restored = try JSONDecoder().decode(TagTreeNode.self, from: JSONEncoder().encode(positioned))
        XCTAssertEqual(restored.positionX, 184)
        XCTAssertEqual(restored.positionY, 96)

        let legacy = try JSONDecoder().decode(TagTreeNode.self, from: Data(#"{"id":"legacy","name":"Legacy","parentID":null,"isRetired":false}"#.utf8))
        XCTAssertNil(legacy.positionX)
        XCTAssertNil(legacy.positionY)
        XCTAssertEqual(legacy.resolvedCanvasPosition(index: 1), .init(x: 178, y: 24))

        let origin = TagTreeNode(id: "origin", name: "Origin", positionX: 0, positionY: 0)
        XCTAssertEqual(origin.resolvedCanvasPosition(index: 8), .init(x: 0, y: 0))
    }

    func testTagTreeSubtreeIncludesOnlyTheSelectedBranch() {
        let tree = TagTreeAsset(
            id: "tree",
            name: "Tree",
            nodes: [
                .init(id: "root", name: "Root"),
                .init(id: "child", name: "Child", parentID: "root"),
                .init(id: "grandchild", name: "Grandchild", parentID: "child"),
                .init(id: "sibling", name: "Sibling", parentID: "root"),
                .init(id: "other", name: "Other")
            ]
        )

        XCTAssertEqual(tree.subtreeNodeIDs(rootID: "child"), ["child", "grandchild"])
        XCTAssertEqual(tree.subtreeNodeIDs(rootID: "missing"), [])
    }

    func testClassificationRecordRetainsOriginAndReviewSeparately() {
        let record = ClassificationRecord(
            title: "Example entry",
            tagIDs: ["content.topics.technology"],
            origin: .llmAssist,
            review: .pending,
            platformID: "youtube",
            treeRevision: 2
        )
        XCTAssertEqual(record.origin, .llmAssist)
        XCTAssertEqual(record.review, .pending)
        XCTAssertEqual(record.platformID, "youtube")
    }

    func testPlatformRejectsAnIncompatibleActiveModel() {
        var catalog = WorkspaceCatalog.starter()
        catalog.models[0].isReady = true
        catalog.models[0].datasetRevision = 99
        catalog.bindings[0].activeModelID = catalog.models[0].id
        XCTAssertThrowsError(try catalog.validate()) { error in
            XCTAssertEqual(error as? WorkspaceCatalogError, .incompatibleActiveModel(catalog.models[0].id))
        }
    }
}
