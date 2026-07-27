import XCTest
@testable import VaultClassifierCore

final class TrashTests: XCTestCase {
    func testTrashAndRestoreClassifierTypeCarriesItsDecisions() {
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
            applicablePlatformID: "youtube"
        )]
        catalog.datasets[0].creatorClassifications = [CreatorClassificationRecord(
            classifierTypeID: "type",
            creatorID: "c",
            creatorName: "C",
            platformID: "youtube",
            treeID: tree.id,
            treeRevision: tree.revision,
            tagIDs: [],
            origin: .manual,
            review: .approved
        )]

        let entry = catalog.trashClassifierType("type")
        XCTAssertEqual(entry?.name, "My Type")
        XCTAssertEqual(entry?.kind, .classifierType)
        XCTAssertEqual(entry?.creatorClassifications.count, 1)
        XCTAssertTrue(catalog.classifierTypes.isEmpty)
        XCTAssertTrue(catalog.datasets[0].creatorClassifications.isEmpty)
        XCTAssertEqual(catalog.trash.count, 1)

        XCTAssertTrue(catalog.restoreTrashedEntry(entry!.id))
        XCTAssertEqual(catalog.classifierTypes.map(\.id), ["type"])
        XCTAssertEqual(catalog.datasets[0].creatorClassifications.count, 1)
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
        catalog.datasets[0].creatorClassifications = [CreatorClassificationRecord(
            classifierTypeID: "type",
            creatorID: "c",
            creatorName: "C",
            platformID: "youtube",
            treeID: catalog.trees[0].id,
            treeRevision: catalog.trees[0].revision,
            tagIDs: [],
            origin: .manual,
            review: .approved
        )]

        let entry = catalog.trashCollectionPlatform("youtube")
        XCTAssertEqual(entry?.kind, .collectionPlatform)
        XCTAssertEqual(entry?.collectedEntries.count, 1)
        XCTAssertEqual(entry?.creatorClassifications.count, 1)
        XCTAssertTrue(catalog.bindings.isEmpty)
        XCTAssertTrue(catalog.datasets[0].collectedEntries.isEmpty)
        XCTAssertTrue(catalog.datasets[0].creatorClassifications.isEmpty)

        XCTAssertTrue(catalog.restoreTrashedEntry(entry!.id))
        XCTAssertEqual(catalog.bindings.map(\.id), ["youtube"])
        XCTAssertEqual(catalog.datasets[0].collectedEntries.count, 1)
        XCTAssertEqual(catalog.datasets[0].creatorClassifications.count, 1)
        XCTAssertTrue(catalog.trash.isEmpty)
    }

    func testTrashTagTreeBlocksWhileReferencedAndAllowsUnreferenced() throws {
        var catalog = WorkspaceCatalog.starter()
        _ = try catalog.ensurePlatformBinding("youtube")
        let referencedTreeID = catalog.trees[0].id
        XCTAssertThrowsError(try catalog.trashTagTree(referencedTreeID)) { error in
            XCTAssertEqual(error as? WorkspaceCatalogError, .treeInUse(referencedTreeID))
        }
        XCTAssertTrue(catalog.trees.contains(where: { $0.id == referencedTreeID }))

        catalog.trees.append(TagTreeAsset(id: "extra", name: "Extra", nodes: []))
        let entry = try catalog.trashTagTree("extra")
        XCTAssertEqual(entry?.name, "Extra")
        XCTAssertFalse(catalog.trees.contains(where: { $0.id == "extra" }))
        XCTAssertTrue(catalog.restoreTrashedEntry(entry!.id))
        XCTAssertTrue(catalog.trees.contains(where: { $0.id == "extra" }))
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
