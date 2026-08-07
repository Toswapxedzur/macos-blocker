import XCTest
@testable import VaultClassifierCore

final class VideoClassificationCoordinatorTests: XCTestCase {

    private func temporaryStateFile() -> (root: URL, file: LocalStateFile) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        return (root, LocalStateFile(url: root.appendingPathComponent("state.json")))
    }

    private func makeCoordinatorWithYouTubeType() throws -> (LocalClassifierCoordinator, URL) {
        let fixture = temporaryStateFile()
        let coordinator = try LocalClassifierCoordinator(verifiedPackage: SeedPackageLoader.bundled(), stateFile: fixture.file)

        var catalog = WorkspaceCatalog.starter()
        let tree = TagTreeAsset(id: "t", name: "Topics", nodes: [
            .init(id: "g", name: "Games"),
            .init(id: "p", name: "Politics"),
        ])
        catalog.trees.append(tree)
        let dataset = catalog.datasets[0]
        catalog.classifierTypes.append(ClassifierTypeAsset(
            id: "type", name: "YT", treeID: tree.id, treeRevision: tree.revision,
            datasetID: dataset.id, datasetRevision: dataset.revision, applicablePlatformID: "youtube"
        ))
        try coordinator.updateWorkspaceCatalog(catalog)
        // Sanity: the type survived reconciliation and targets youtube.
        let live = coordinator.snapshot().workspaceCatalog
        XCTAssertEqual(live.classifierTypes.first?.applicablePlatformID, "youtube")
        return (coordinator, fixture.root)
    }

    func testClassifyVideoProducesPerVideoTagsAndCaches() async throws {
        let (coordinator, root) = try makeCoordinatorWithYouTubeType()
        defer { try? FileManager.default.removeItem(at: root) }

        // No classification yet -> decision cache is empty.
        XCTAssertNil(coordinator.cachedVideoTags(platformID: "youtube", entryID: "youtube:video:v1"))

        // The stub LLM selects allowed tag names present in the prompt; the title
        // contains "Games" so we expect the Games tag.
        let projection = try await coordinator.classifyVideo(
            platformID: "youtube", entryID: "youtube:video:v1", creatorID: "c1",
            title: "A great Games montage"
        )
        XCTAssertEqual(projection.tags.map(\.id), ["g"])

        // Now the decision cache returns it without re-classifying.
        let cached = coordinator.cachedVideoTags(platformID: "youtube", entryID: "youtube:video:v1")
        XCTAssertEqual(cached?.tags.map(\.id), ["g"])
    }

    func testClassifyVideoUpdatesDerivedCreatorHistogram() async throws {
        let (coordinator, root) = try makeCoordinatorWithYouTubeType()
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try await coordinator.classifyVideo(
            platformID: "youtube", entryID: "youtube:video:v1", creatorID: "c1",
            title: "Games highlights"
        )
        let histogram = coordinator.snapshot().workspaceCatalog
            .creatorHistogram(classifierTypeID: "type", platformID: "youtube", creatorID: "c1")
        XCTAssertEqual(histogram?.videoCount, 1)
        XCTAssertNotNil(histogram?.stats["g"])
    }

    func testClassifyVideoOnCollectionDisabledPlatformThrows() async throws {
        let fixture = temporaryStateFile()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = try LocalClassifierCoordinator(verifiedPackage: SeedPackageLoader.bundled(), stateFile: fixture.file)

        var catalog = WorkspaceCatalog.starter()
        if let index = catalog.bindings.firstIndex(where: { $0.id == "youtube" }) {
            catalog.bindings[index].collectionEnabled = false
        }
        try coordinator.updateWorkspaceCatalog(catalog)

        do {
            _ = try await coordinator.classifyVideo(
                platformID: "youtube", entryID: "v1", creatorID: "c1", title: "x")
            XCTFail("expected disabled-collection error")
        } catch {
            // expected
        }
    }
}
