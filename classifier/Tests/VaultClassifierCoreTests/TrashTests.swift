import XCTest
@testable import VaultClassifierCore

final class TrashTests: XCTestCase {
    func testTrashAndRestoreClassifierType() {
        var catalog = WorkspaceCatalog.starter()
        let tree = catalog.trees[0]
        let dataset = catalog.datasets[0]
        catalog.classifierTypes = [ClassifierTypeAsset(
            id: "type",
            name: "My Type",
            treeID: tree.id,
            treeRevision: tree.revision,
            datasetID: dataset.id,
            datasetRevision: dataset.revision,
            applicablePlatformIDs: ["youtube"]
        )]
        let entry = catalog.trashClassifierType("type")
        XCTAssertEqual(entry?.name, "My Type")
        XCTAssertEqual(entry?.kind, .classifierType)
        XCTAssertTrue(catalog.classifierTypes.isEmpty)
        XCTAssertEqual(catalog.trash.count, 1)

        XCTAssertTrue(catalog.restoreTrashedEntry(entry!.id))
        XCTAssertEqual(catalog.classifierTypes.map(\.id), ["type"])
        XCTAssertTrue(catalog.trash.isEmpty)
    }

    func testTrashAndRestoreCollectionPlatformCarriesItsData() throws {
        var catalog = WorkspaceCatalog.starter()
        _ = try catalog.ensurePlatformBinding("youtube")
        XCTAssertTrue(catalog.datasets[0].upsertCollectedEntry(CollectedPlatformEntry(
            id: "e1",
            platformID: "youtube",
            entryID: "youtube:video:1",
            creatorID: "c",
            creatorName: "C",
            entryType: "video",
            title: "T"
        )))
        let entry = catalog.trashCollectionPlatform("youtube")
        XCTAssertEqual(entry?.kind, .collectionPlatform)
        XCTAssertEqual(entry?.collectedEntries.count, 1)
        // Other default platforms remain; only YouTube's binding is removed.
        XCTAssertFalse(catalog.bindings.contains(where: { $0.id == "youtube" }))
        XCTAssertTrue(catalog.datasets[0].collectedEntries.isEmpty)

        XCTAssertTrue(catalog.restoreTrashedEntry(entry!.id))
        XCTAssertTrue(catalog.bindings.contains(where: { $0.id == "youtube" }))
        XCTAssertEqual(catalog.datasets[0].collectedEntries.count, 1)
        XCTAssertTrue(catalog.trash.isEmpty)
    }

    func testTreesNothingRefersToAreDroppedOnReconcile() throws {
        var catalog = WorkspaceCatalog.starter()
        _ = try catalog.ensurePlatformBinding("youtube")
        let kept = Set(catalog.trees.map(\.id))
        catalog.trees.append(TagTreeAsset(id: "orphan", name: "Orphan", nodes: []))
        catalog.reconcileClassifierTypes()
        XCTAssertEqual(Set(catalog.trees.map(\.id)), kept)
    }

    func testTrashCollectedEntriesKeepsThePlatformAndRestores() throws {
        var catalog = WorkspaceCatalog.starter()
        let binding = try catalog.ensurePlatformBinding("youtube")
        let datasetIndex = try XCTUnwrap(catalog.datasets.firstIndex(where: { $0.id == binding.datasetID }))
        catalog.datasets[datasetIndex].collectedEntries = [
            CollectedPlatformEntry(id: "e1", platformID: "youtube", entryID: "youtube:video:a", creatorID: "youtube:channel:c", creatorName: "C", entryType: "video", title: "A")
        ]
        let entry = try XCTUnwrap(catalog.trashCollectedEntries("youtube"))
        XCTAssertTrue(catalog.datasets[datasetIndex].collectedEntries.isEmpty)
        XCTAssertTrue(catalog.bindings.contains(where: { $0.id == "youtube" }))
        XCTAssertTrue(catalog.restoreTrashedEntry(entry.id))
        XCTAssertEqual(catalog.datasets[datasetIndex].collectedEntries.map(\.entryID), ["youtube:video:a"])
    }

        func testPurgeExpiredTrashRemovesOnlyEntriesPastTTL() {
        var catalog = WorkspaceCatalog.starter()
        let now = WorkspaceCatalog.now()
        catalog.trash = [
            TrashedEntry(id: "old", kind: .tagTree, name: "Old", deletedAtMilliseconds: now - TrashedEntry.defaultTTLMilliseconds - 1_000),
            TrashedEntry(id: "recent", kind: .tagTree, name: "Recent", deletedAtMilliseconds: now - 1_000),
        ]
        XCTAssertEqual(catalog.purgeExpiredTrash(nowMilliseconds: now), 1)
        XCTAssertEqual(catalog.trash.map(\.id), ["recent"])
    }

    func testPermanentlyDeleteRemovesEntry() {
        var catalog = WorkspaceCatalog.starter()
        catalog.trash = [TrashedEntry(id: "z", kind: .tagTree, name: "Z")]
        XCTAssertTrue(catalog.permanentlyDeleteTrashedEntry("z"))
        XCTAssertTrue(catalog.trash.isEmpty)
        XCTAssertFalse(catalog.permanentlyDeleteTrashedEntry("z"))
    }

    func testTrashSurvivesCodableRoundTripAndMigratesFromAbsentKey() throws {
        var catalog = WorkspaceCatalog.starter()
        catalog.trash = [TrashedEntry(id: "t", kind: .tagTree, name: "T", tree: TagTreeAsset(id: "x", name: "X", nodes: []))]
        let data = try JSONEncoder().encode(catalog)
        let decoded = try JSONDecoder().decode(WorkspaceCatalog.self, from: data)
        XCTAssertEqual(decoded.trash.map(\.id), ["t"])

        let legacy = Data(#"{"trees":[],"datasets":[]}"#.utf8)
        let migrated = try JSONDecoder().decode(WorkspaceCatalog.self, from: legacy)
        XCTAssertTrue(migrated.trash.isEmpty)
    }
}
