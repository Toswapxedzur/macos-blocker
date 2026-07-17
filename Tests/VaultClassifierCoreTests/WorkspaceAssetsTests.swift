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

    func testModelTrainingUsesOnlyApprovedRecordsForItsTreeAndPlatform() throws {
        let tree = TagTreeAsset(
            id: "interests",
            name: "Interests",
            nodes: [
                .init(id: "games", name: "Games"),
                .init(id: "technology", name: "Technology"),
                .init(id: "cooking", name: "Cooking"),
            ]
        )
        let dataset = ClassificationDataset(
            id: "personal-labels",
            name: "Personal labels",
            records: [
                .init(title: "Fast deck guide for the arena", tagIDs: ["games"], origin: .manual, review: .approved, platformID: "youtube", treeRevision: tree.revision),
                .init(title: "Patch notes and ranked gameplay", tagIDs: ["games"], origin: .manual, review: .approved, platformID: "youtube", treeRevision: tree.revision),
                .init(title: "Build a compact neural network", tagIDs: ["technology"], origin: .manual, review: .approved, platformID: "youtube", treeRevision: tree.revision),
                .init(title: "Review a local embedding model", tagIDs: ["technology"], origin: .llmAssist, review: .approved, platformID: "youtube", treeRevision: tree.revision),
                .init(title: "Quick pasta recipe", tagIDs: ["cooking"], origin: .manual, review: .approved, platformID: "youtube", treeRevision: tree.revision),
                .init(title: "Bake sourdough bread", tagIDs: ["cooking"], origin: .manual, review: .approved, platformID: "youtube", treeRevision: tree.revision),
                .init(title: "Unreviewed suggestion", tagIDs: ["games"], origin: .llmAssist, review: .pending, platformID: "youtube", treeRevision: tree.revision),
                .init(title: "Another platform", tagIDs: ["games"], origin: .manual, review: .approved, platformID: "twitch", treeRevision: tree.revision),
                .init(title: "Old tree", tagIDs: ["games"], origin: .manual, review: .approved, platformID: "youtube", treeRevision: tree.revision + 1),
            ]
        )
        let model = LocalModelAsset(
            id: "interests-model",
            name: "Interests model",
            treeID: tree.id,
            treeRevision: tree.revision,
            datasetID: dataset.id,
            datasetRevision: dataset.revision,
            trainingPlatformID: "youtube",
            baseEmbeddingID: .multilingualE5Small
        )
        let configuration = EmbeddedNeuralModelConfiguration(
            vocabularyLimit: 128,
            embeddingDimension: 12,
            hiddenDimension: 10,
            learningRate: 0.16,
            l2Penalty: 0.0001,
            initializationSeed: 11
        )

        let trained = try LocalModelTrainer.train(model, tree: tree, dataset: dataset, epochs: 450, configuration: configuration)

        XCTAssertTrue(trained.isReady)
        XCTAssertEqual(trained.version, 2)
        XCTAssertEqual(trained.baseEmbeddingID, .multilingualE5Small)
        XCTAssertEqual(trained.embeddedTrainingReport?.exampleCount, 6)
        XCTAssertEqual(Set(trained.embeddedNeuralModel?.labelIDs ?? []), ["games", "technology", "cooking"])
        let predictions = Dictionary(
            uniqueKeysWithValues: trained.embeddedNeuralModel?.predictions(for: "pasta bread recipe").map { ($0.labelID, $0.probability) } ?? []
        )
        XCTAssertGreaterThan(predictions["cooking"] ?? 0, 0.65)
    }

    func testLegacyModelAssetDecodesWithoutANeuralArtifact() throws {
        let legacy = Data(#"{"id":"legacy","name":"Legacy","treeID":"tree","treeRevision":1,"datasetID":"data","datasetRevision":1,"version":1,"isReady":false}"#.utf8)
        let decoded = try JSONDecoder().decode(LocalModelAsset.self, from: legacy)

        XCTAssertNil(decoded.trainingPlatformID)
        XCTAssertNil(decoded.baseEmbeddingID)
        XCTAssertNil(decoded.embeddedNeuralModel)
        XCTAssertNil(decoded.embeddedTrainingReport)
    }
}
