import Foundation
import XCTest
@testable import VaultClassifierCore

final class WorkspaceDeletionTests: XCTestCase {
    func testDeletingGroupDropsItsTreeAndReleasesPlatformsWithoutClearingSharedData() throws {
        var catalog = WorkspaceCatalog.starter()
        let sharedTree = catalog.trees[0]
        let tree = TagTreeAsset(id: "group-tree", name: "Group", nodes: [])
        let dataset = catalog.datasets[0]
        catalog.trees.append(tree)
        catalog.classifierTypes = [.init(id: "group", name: "Group", treeID: tree.id,
            treeRevision: tree.revision, datasetID: dataset.id, datasetRevision: dataset.revision,
            applicablePlatformIDs: ["youtube"])]
        catalog.datasets[0].collectedEntries = [entry("youtube"), entry("reddit")]

        XCTAssertTrue(catalog.removeClassifierType("group"))
        XCTAssertFalse(catalog.removeClassifierType("group"))
        XCTAssertTrue(catalog.classifierTypes.isEmpty)
        XCTAssertEqual(catalog.trees.map(\.id), [sharedTree.id])
        XCTAssertTrue(catalog.bindings.contains { $0.id == "youtube" })
        XCTAssertEqual(catalog.datasets[0].collectedEntries.count, 2)
        try catalog.validate()
        let reloaded = try JSONDecoder().decode(WorkspaceCatalog.self, from: JSONEncoder().encode(catalog))
        XCTAssertTrue(reloaded.classifierTypes.isEmpty)
        XCTAssertFalse(reloaded.trees.contains { $0.id == tree.id })
    }

    func testDeletingActiveGroupClearsItsBindingSelection() throws {
        var catalog = WorkspaceCatalog.starter()
        let tree = catalog.trees[0], dataset = catalog.datasets[0]
        catalog.classifierTypes = [.init(id: "group", name: "Group", treeID: tree.id,
            treeRevision: tree.revision, datasetID: dataset.id, datasetRevision: dataset.revision,
            applicablePlatformIDs: ["youtube"])]
        let index = try XCTUnwrap(catalog.bindings.firstIndex { $0.id == "youtube" })
        catalog.bindings[index].activeClassifierTypeID = "group"
        XCTAssertTrue(catalog.removeClassifierType("group"))
        XCTAssertNil(catalog.bindings[index].activeClassifierTypeID)
        XCTAssertTrue(catalog.trees.contains { $0.id == tree.id }, "binding still owns the shared tree")
        try catalog.validate()
    }

    func testClearingCollectedEntriesIsPermanentAndKeepsOtherPlatformsAndGroup() throws {
        var catalog = WorkspaceCatalog.starter()
        let tree = catalog.trees[0], dataset = catalog.datasets[0]
        catalog.classifierTypes = [.init(id: "group", name: "Group", treeID: tree.id,
            treeRevision: tree.revision, datasetID: dataset.id, datasetRevision: dataset.revision,
            applicablePlatformIDs: ["youtube"])]
        catalog.datasets[0].collectedEntries = [entry("youtube"), entry("reddit")]
        let bindings = catalog.bindings
        XCTAssertFalse(catalog.clearCollectedEntries("unknown"))
        XCTAssertEqual(catalog.datasets[0].collectedEntries.count, 2)
        XCTAssertTrue(catalog.clearCollectedEntries("youtube"))
        XCTAssertEqual(catalog.bindings, bindings)
        XCTAssertEqual(catalog.classifierTypes.map(\.id), ["group"])
        let reloaded = try JSONDecoder().decode(WorkspaceCatalog.self, from: JSONEncoder().encode(catalog))
        XCTAssertEqual(reloaded.datasets[0].collectedEntries.map(\.platformID), ["reddit"])
        try reloaded.validate()
    }

    func testRetiredTrashPayloadsAreIgnoredAndNeverWrittenBack() throws {
        for payload in [#"[{"id":"old","kind":"classifierType","name":"Deleted","deletedAtMilliseconds":1}]"#,
                        #"{"malformed":"retired data"}"#, "null"] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(WorkspaceCatalog.starter())) as? [String: Any])
            object["trash"] = try JSONSerialization.jsonObject(with: Data(payload.utf8), options: [.fragmentsAllowed])
            var catalog = try JSONDecoder().decode(WorkspaceCatalog.self, from: JSONSerialization.data(withJSONObject: object))
            catalog.trees.append(.init(id: "retired-tree", name: "Deleted group's tree", nodes: []))
            catalog.reconcileClassifierTypes()
            XCTAssertFalse(catalog.trees.contains { $0.id == "retired-tree" })
            XCTAssertTrue(catalog.classifierTypes.isEmpty)
            try catalog.validate()
            let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(catalog)) as? [String: Any])
            XCTAssertNil(encoded["trash"])
        }
    }

    private func entry(_ platform: String) -> CollectedPlatformEntry {
        .init(id: platform, platformID: platform, entryID: "entry", creatorID: "creator",
              creatorName: "Creator", entryType: "video", title: "Title")
    }
}
