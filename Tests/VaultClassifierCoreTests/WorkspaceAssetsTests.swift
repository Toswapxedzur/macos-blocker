import XCTest
@testable import VaultClassifierCore

final class WorkspaceAssetsTests: XCTestCase {
    private func seed() throws -> VerifiedSeedPackage { try SeedPackageLoader.bundled() }

    func testCollectionRegistryLimitsTheClassifierToSixAutomatedAndThreeManualPlatforms() {
        XCTAssertEqual(Set(CollectionPlatformRegistry.definitions.map(\.id)), Set([
            "youtube", "tiktok", "facebook", "instagram", "twitter", "bilibili",
            "twitch", "reddit", "discord",
        ]))
        let available = Set(CollectionPlatformRegistry.definitions.lazy.filter(\.collectorAvailable).map(\.id))
        XCTAssertEqual(available, Set([
            "youtube", "tiktok", "facebook", "instagram", "twitch", "reddit", "twitter", "bilibili",
        ]))
        for platformID in ["twitch", "reddit", "discord"] {
            let platform = try! XCTUnwrap(CollectionPlatformRegistry.definition(for: platformID))
            XCTAssertFalse(platform.supportsLocalModel)
            XCTAssertFalse(platform.supportsLLMAssist)
        }
        for platformID in ["youtube", "tiktok", "facebook", "instagram", "twitter", "bilibili"] {
            let platform = try! XCTUnwrap(CollectionPlatformRegistry.definition(for: platformID))
            XCTAssertTrue(platform.supportsLocalModel)
            XCTAssertTrue(platform.supportsLLMAssist)
        }
        XCTAssertFalse(CollectionPlatformRegistry.definition(for: "pinterest") != nil)
    }

    func testManualOnlyPlatformRejectsModelAndLLMAssistButKeepsHumanClassification() throws {
        var catalog = WorkspaceCatalog.starter()
        let tree = try XCTUnwrap(catalog.trees.first)
        let dataset = try XCTUnwrap(catalog.datasets.first)
        catalog.bindings.append(.init(id: "twitch", name: "Twitch", treeID: tree.id, datasetID: dataset.id))

        let humanOnly = ClassifierTypeAsset(
            id: "twitch-manual",
            name: "Twitch manual",
            treeID: tree.id,
            treeRevision: tree.revision,
            datasetID: dataset.id,
            datasetRevision: dataset.revision,
            applicablePlatformID: "twitch"
        )
        catalog.classifierTypes = [humanOnly]
        XCTAssertNoThrow(try catalog.validate())

        catalog.models[0].trainingPlatformID = "twitch"
        catalog.models[0].trainingPlatformIDs = ["twitch"]
        XCTAssertThrowsError(try catalog.validate()) { error in
            XCTAssertEqual(error as? WorkspaceCatalogError, .invalidLocalModel(catalog.models[0].id))
        }

        catalog.models[0].trainingPlatformID = "youtube"
        catalog.models[0].trainingPlatformIDs = ["youtube"]
        let profile = APIKeyProviderProfile(id: "manual-only-profile", type: .gemini)
        catalog.providerProfiles = [profile]
        catalog.classifierTypes = [.init(
            id: "twitch-automated",
            name: "Twitch automated",
            treeID: tree.id,
            treeRevision: tree.revision,
            datasetID: dataset.id,
            datasetRevision: dataset.revision,
            applicablePlatformID: "twitch",
            llmAssistConfiguration: .init(providerProfileID: profile.id, modelIdentifier: "gemini-3.1-flash-lite")
        )]
        XCTAssertThrowsError(try catalog.validate()) { error in
            XCTAssertEqual(error as? WorkspaceCatalogError, .invalidClassifierType("twitch-automated"))
        }

        catalog.reconcileClassifierTypes()
        XCTAssertEqual(catalog.classifierTypes[0].applicablePlatformID, "twitch")
        XCTAssertNil(catalog.classifierTypes[0].llmAssistConfiguration)
        XCTAssertNoThrow(try catalog.validate())
    }

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

    func testEnsuringPlatformBindingAddsTheMissingPlatformToLocalClassificationData() throws {
        var catalog = WorkspaceCatalog.starter()
        let defaultBinding = try XCTUnwrap(catalog.bindings.first)

        let created = try catalog.ensurePlatformBinding("discord")
        let repeated = try catalog.ensurePlatformBinding("discord")

        XCTAssertEqual(created.id, "discord")
        XCTAssertEqual(created.name, "Discord")
        XCTAssertEqual(created.treeID, defaultBinding.treeID)
        XCTAssertEqual(created.datasetID, defaultBinding.datasetID)
        XCTAssertEqual(repeated, created)
        XCTAssertEqual(catalog.bindings.filter { $0.id == "discord" }.count, 1)
        XCTAssertNoThrow(try catalog.validate())
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

    func testRemovingCreatorClassificationTargetsOnlyThatCreatorAndType() {
        let retained = CreatorClassificationRecord(
            classifierTypeID: "other-type",
            creatorID: "youtube:channel:one",
            creatorName: "Creator one",
            platformID: "youtube",
            treeID: "tree",
            treeRevision: 1,
            tagIDs: ["games"],
            origin: .manual,
            review: .approved
        )
        let removed = CreatorClassificationRecord(
            classifierTypeID: "creator-type",
            creatorID: "youtube:channel:one",
            creatorName: "Creator one",
            platformID: "youtube",
            treeID: "tree",
            treeRevision: 1,
            tagIDs: ["games"],
            origin: .manual,
            review: .approved
        )
        var dataset = ClassificationDataset(name: "Labels", creatorClassifications: [retained, removed])

        XCTAssertTrue(dataset.removeCreatorClassification(
            classifierTypeID: "creator-type",
            platformID: "youtube",
            creatorID: "youtube:channel:one",
            origin: .manual
        ))
        XCTAssertEqual(dataset.creatorClassifications, [retained])
        XCTAssertFalse(dataset.removeCreatorClassification(
            classifierTypeID: "creator-type",
            platformID: "youtube",
            creatorID: "youtube:channel:one",
            origin: .manual
        ))
    }

    func testLegacyCreatorClassificationKeepsOtherTagsUndecided() throws {
        let legacy = Data(#"{"id":"creator","classifierTypeID":"type","creatorID":"channel","creatorName":"Creator","platformID":"youtube","treeID":"tree","treeRevision":1,"tagIDs":["games"],"origin":"manual","review":"approved","createdAtMilliseconds":1,"updatedAtMilliseconds":1}"#.utf8)
        let classification = try JSONDecoder().decode(CreatorClassificationRecord.self, from: legacy)

        XCTAssertEqual(classification.tagIDs, ["games"])
        XCTAssertTrue(classification.negativeTagIDs.isEmpty)
        XCTAssertEqual(try JSONDecoder().decode(CreatorClassificationRecord.self, from: JSONEncoder().encode(classification)), classification)
    }

    func testPriorityWeightsEveryAvailableCreatorDecision() throws {
        let tree = TagTreeAsset(id: "tree", name: "Topics", nodes: [.init(id: "games", name: "Games")])
        let human = CreatorClassificationRecord(
            classifierTypeID: "type",
            creatorID: "creator",
            creatorName: "Creator",
            platformID: "youtube",
            treeID: tree.id,
            treeRevision: tree.revision,
            tagIDs: ["games"],
            origin: .manual,
            review: .approved
        )
        let llm = CreatorClassificationRecord(
            classifierTypeID: "type",
            creatorID: "creator",
            creatorName: "Creator",
            platformID: "youtube",
            treeID: tree.id,
            treeRevision: tree.revision,
            tagIDs: [],
            negativeTagIDs: ["games"],
            origin: .llmAssist,
            review: .approved
        )
        var dataset = ClassificationDataset(name: "Labels")
        dataset.upsertCreatorClassification(human)
        dataset.upsertCreatorClassification(llm)
        XCTAssertEqual(dataset.creatorClassifications.count, 2)

        let entry = EntryEvidence(platform: "youtube", entryID: "entry", sourceID: "creator", surface: .feed, evidence: .init(title: "A game"))
        let humanFirst = ClassifierTypeAsset(
            id: "type", name: "Human first", treeID: tree.id, treeRevision: tree.revision,
            datasetID: "dataset", datasetRevision: 1, applicablePlatformID: "youtube",
            decisionPriority: [.human, .llmAssist, .localModel]
        )
        let humanFirstResult = try WorkspaceNeuralClassifier(
            classifierType: humanFirst,
            model: nil,
            taxonomy: try tree.inferenceTaxonomy(),
            policies: [],
            creatorClassifications: dataset.creatorClassifications
        ).classify(entry)
        XCTAssertEqual(try XCTUnwrap(humanFirstResult.scores.first).finalScore, 0.6, accuracy: 0.0001)
        XCTAssertEqual(humanFirstResult.selectedLeafTagIDs, ["games"])

        let llmFirst = ClassifierTypeAsset(
            id: "type", name: "LLM first", treeID: tree.id, treeRevision: tree.revision,
            datasetID: "dataset", datasetRevision: 1, applicablePlatformID: "youtube",
            decisionPriority: [.llmAssist, .human, .localModel]
        )
        let llmFirstResult = try WorkspaceNeuralClassifier(
            classifierType: llmFirst,
            model: nil,
            taxonomy: try tree.inferenceTaxonomy(),
            policies: [],
            creatorClassifications: dataset.creatorClassifications
        ).classify(entry)
        XCTAssertEqual(try XCTUnwrap(llmFirstResult.scores.first).finalScore, 0.4, accuracy: 0.0001)
        XCTAssertTrue(llmFirstResult.selectedLeafTagIDs.isEmpty)
    }

    func testCreatorClassificationsAreTheOnlyActiveTrainingLabels() throws {
        let tree = TagTreeAsset(
            id: "interests",
            name: "Interests",
            nodes: [
                .init(id: "games", name: "Games"),
                .init(id: "technology", name: "Technology"),
            ]
        )
        let manual = CreatorClassificationRecord(
            id: "creator-decision",
            classifierTypeID: "creator-focus",
            creatorID: "youtube:channel:games",
            creatorName: "Game creator",
            platformID: "youtube",
            treeID: tree.id,
            treeRevision: tree.revision,
            tagIDs: ["games"],
            negativeTagIDs: ["technology"],
            origin: .manual,
            review: .approved,
            createdAtMilliseconds: 100,
            updatedAtMilliseconds: 100
        )
        let llm = CreatorClassificationRecord(
            classifierTypeID: "creator-focus",
            creatorID: "youtube:channel:technology",
            creatorName: "Tech creator",
            platformID: "youtube",
            treeID: tree.id,
            treeRevision: tree.revision,
            tagIDs: ["technology"],
            origin: .llmAssist,
            review: .approved
        )
        let pending = CreatorClassificationRecord(
            classifierTypeID: "creator-focus",
            creatorID: "youtube:channel:pending",
            creatorName: "Pending creator",
            platformID: "youtube",
            treeID: tree.id,
            treeRevision: tree.revision,
            tagIDs: ["games"],
            origin: .llmAssist,
            review: .pending
        )
        var dataset = ClassificationDataset(
            id: "personal-labels",
            name: "Personal labels",
            records: [
                .init(title: "Legacy entry label", tagIDs: ["games"], origin: .manual, review: .approved, platformID: "youtube", treeRevision: tree.revision),
            ],
            creatorClassifications: [manual, llm, pending],
            collectedEntries: [
                .init(id: "game-video-one", platformID: "youtube", entryID: "game-video-one", creatorID: manual.creatorID, creatorName: manual.creatorName, entryType: "video", title: "Ranked deck guide"),
                .init(id: "game-video-two", platformID: "youtube", entryID: "game-video-two", creatorID: manual.creatorID, creatorName: manual.creatorName, entryType: "video", title: "Arena gameplay"),
                .init(id: "tech-video", platformID: "youtube", entryID: "tech-video", creatorID: llm.creatorID, creatorName: llm.creatorName, entryType: "video", title: "Build a local neural model"),
                .init(id: "pending-video", platformID: "youtube", entryID: "pending-video", creatorID: pending.creatorID, creatorName: pending.creatorName, entryType: "video", title: "Do not train this"),
            ]
        )

        let examples = LocalModelTrainer.approvedExamples(for: tree, dataset: dataset, platformID: "youtube")
        XCTAssertEqual(examples.count, 3)
        XCTAssertEqual(Set(examples.flatMap(\.positiveLabelIDs)), ["games", "technology"])
        XCTAssertEqual(Set(examples.flatMap(\.negativeLabelIDs)), ["technology"])
        XCTAssertFalse(examples.contains(where: { $0.text == "Do not train this" }))
        XCTAssertFalse(examples.contains(where: { $0.text == "Legacy entry label" }))

        var updated = manual
        updated.tagIDs = ["technology"]
        updated.negativeTagIDs = ["games"]
        updated.updatedAtMilliseconds = 200
        let retained = dataset.upsertCreatorClassification(updated)
        XCTAssertEqual(dataset.creatorClassifications.count, 3)
        XCTAssertEqual(retained.id, manual.id)
        XCTAssertEqual(retained.createdAtMilliseconds, 100)
        XCTAssertEqual(retained.tagIDs, ["technology"])
        XCTAssertEqual(retained.negativeTagIDs, ["games"])
        XCTAssertEqual(try JSONDecoder().decode(ClassificationDataset.self, from: JSONEncoder().encode(dataset)), dataset)
    }

    func testLocalModelTrainingCombinesEachSelectedPlatformSource() throws {
        let tree = TagTreeAsset(
            id: "interests",
            name: "Interests",
            nodes: [
                .init(id: "games", name: "Games"),
                .init(id: "technology", name: "Technology"),
            ]
        )
        let youtubeCreator = CreatorClassificationRecord(
            classifierTypeID: "creator-focus",
            creatorID: "youtube:channel:games",
            creatorName: "Games creator",
            platformID: "youtube",
            treeID: tree.id,
            treeRevision: tree.revision,
            tagIDs: ["games"],
            origin: .manual,
            review: .approved
        )
        let instagramCreator = CreatorClassificationRecord(
            classifierTypeID: "creator-focus",
            creatorID: "instagram:creator:technology",
            creatorName: "Technology creator",
            platformID: "instagram",
            treeID: tree.id,
            treeRevision: tree.revision,
            tagIDs: ["technology"],
            origin: .llmAssist,
            review: .approved
        )
        let dataset = ClassificationDataset(
            id: "personal-labels",
            name: "Personal labels",
            creatorClassifications: [youtubeCreator, instagramCreator],
            collectedEntries: [
                .init(id: "youtube-video", platformID: "youtube", entryID: "youtube-video", creatorID: youtubeCreator.creatorID, creatorName: youtubeCreator.creatorName, entryType: "video", title: "YouTube deck guide"),
                .init(id: "instagram-video", platformID: "instagram", entryID: "instagram-video", creatorID: instagramCreator.creatorID, creatorName: instagramCreator.creatorName, entryType: "reel", title: "Instagram neural model guide"),
            ]
        )
        let model = LocalModelAsset(
            name: "Cross-platform model",
            treeID: tree.id,
            treeRevision: tree.revision,
            datasetID: dataset.id,
            datasetRevision: dataset.revision,
            trainingPlatformID: "youtube",
            trainingPlatformIDs: ["youtube", "instagram", "youtube"]
        )

        XCTAssertEqual(model.effectiveTrainingPlatformIDs, ["instagram", "youtube"])
        let examples = LocalModelTrainer.approvedExamples(
            for: tree,
            dataset: dataset,
            platformIDs: model.effectiveTrainingPlatformIDs
        )
        XCTAssertEqual(Set(examples.map(\.text)), ["YouTube deck guide", "Instagram neural model guide"])
        XCTAssertEqual(Set(examples.flatMap(\.positiveLabelIDs)), ["games", "technology"])
    }

    func testRetiredDecisionScopeSettingsAreIgnoredUntilOneApplicablePlatformIsChosen() throws {
        let legacy = Data(#"{"id":"legacy-type","name":"Legacy type","treeID":"vault-starter","treeRevision":1,"datasetID":"local-dataset","datasetRevision":1,"localModelID":null,"llmProfileIDs":[],"decisionPriority":["human","llmAssist","localModel"],"creatorDecisionSources":["human"],"entryDecisionSources":[],"updatedAtMilliseconds":0}"#.utf8)
        let type = try JSONDecoder().decode(ClassifierTypeAsset.self, from: legacy)
        XCTAssertNil(type.applicablePlatformID)

        var catalog = WorkspaceCatalog.starter()
        catalog.bindings.append(.init(id: "instagram", treeID: "vault-starter", datasetID: "local-dataset"))
        catalog.classifierTypes = [type]
        catalog.reconcileClassifierTypes()

        XCTAssertNil(catalog.classifierTypes[0].applicablePlatformID)
        XCTAssertNoThrow(try catalog.validate())
    }

    func testLegacySingleSourceTypeKeepsItsOneApplicablePlatform() throws {
        let legacy = Data(#"{"id":"legacy-type","name":"Legacy type","treeID":"vault-starter","treeRevision":1,"datasetID":"local-dataset","datasetRevision":1,"dataSourcePlatformIDs":["youtube"],"localModelID":null,"llmProfileIDs":[],"decisionPriority":["human","llmAssist","localModel"],"creatorDecisionSources":["human"],"entryDecisionSources":[],"updatedAtMilliseconds":0}"#.utf8)
        let type = try JSONDecoder().decode(ClassifierTypeAsset.self, from: legacy)
        XCTAssertEqual(type.applicablePlatformID, "youtube")

        let encoded = String(decoding: try JSONEncoder().encode(type), as: UTF8.self)
        XCTAssertFalse(encoded.contains("dataSourcePlatformIDs"))
        XCTAssertFalse(encoded.contains("creatorDecisionSources"))
        XCTAssertFalse(encoded.contains("entryDecisionSources"))
    }

    func testLegacyLLMSettingsDecodeToSafeCurrentDefaults() throws {
        let legacy = Data(#"{"id":"legacy-type","name":"Legacy type","treeID":"vault-starter","treeRevision":1,"datasetID":"local-dataset","datasetRevision":1,"applicablePlatformID":"youtube","llmAssistConfiguration":{"providerProfileID":"gemini","modelIdentifier":"gemini-3.1-flash-lite","maximumTokens":512,"inputCostUSDPerMillion":0.2,"outputCostUSDPerMillion":0.8},"decisionPriority":["human","llmAssist","localModel"],"updatedAtMilliseconds":0}"#.utf8)

        let decoded = try JSONDecoder().decode(ClassifierTypeAsset.self, from: legacy)
        XCTAssertEqual(decoded.llmAssistConfiguration?.providerProfileID, "gemini")
        XCTAssertEqual(decoded.llmAssistConfiguration?.modelIdentifier, "gemini-3.1-flash-lite")
        XCTAssertEqual(decoded.llmAssistConfiguration?.dailyOutputTokenLimit, LLMAssistConfiguration.defaultDailyOutputTokenLimit)
        XCTAssertEqual(decoded.llmAssistConfiguration?.batchSize, LLMAssistConfiguration.defaultBatchSize)

        let reencoded = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)
        XCTAssertFalse(reencoded.contains("inputCostUSDPerMillion"))
        XCTAssertFalse(reencoded.contains("outputCostUSDPerMillion"))
        XCTAssertFalse(reencoded.contains("maximumTokens"))
    }

    func testRemovingPlatformBindingPurgesItsDataAndReconcilesDependents() throws {
        var catalog = WorkspaceCatalog.starter()
        let tree = try XCTUnwrap(catalog.trees.first)
        let dataset = try XCTUnwrap(catalog.datasets.first)
        catalog.bindings.append(.init(id: "instagram", name: "Instagram", treeID: tree.id, datasetID: dataset.id))
        catalog.datasets[0].collectedEntries = [
            .init(id: "youtube-entry", platformID: "youtube", entryID: "youtube-entry", creatorID: "youtube:creator", creatorName: "YouTube creator", entryType: "video", title: "YouTube guide"),
            .init(id: "instagram-entry", platformID: "instagram", entryID: "instagram-entry", creatorID: "instagram:creator", creatorName: "Instagram creator", entryType: "reel", title: "Instagram guide"),
        ]
        catalog.datasets[0].creatorClassifications = [
            .init(classifierTypeID: "creator-type", creatorID: "youtube:creator", creatorName: "YouTube creator", platformID: "youtube", treeID: tree.id, treeRevision: tree.revision, tagIDs: ["games"], origin: .manual, review: .approved),
            .init(classifierTypeID: "creator-type", creatorID: "instagram:creator", creatorName: "Instagram creator", platformID: "instagram", treeID: tree.id, treeRevision: tree.revision, tagIDs: ["games"], origin: .manual, review: .approved),
        ]
        catalog.models.append(.init(
            id: "combined-model",
            name: "Combined model",
            treeID: tree.id,
            treeRevision: tree.revision,
            datasetID: dataset.id,
            datasetRevision: dataset.revision,
            isReady: true,
            trainingPlatformID: "youtube",
            trainingPlatformIDs: ["youtube", "instagram"]
        ))
        catalog.models.append(.init(
            id: "instagram-only-model",
            name: "Instagram-only model",
            treeID: tree.id,
            treeRevision: tree.revision,
            datasetID: dataset.id,
            datasetRevision: dataset.revision,
            isReady: true,
            trainingPlatformID: "instagram",
            trainingPlatformIDs: ["instagram"]
        ))
        catalog.classifierTypes = [.init(
            id: "creator-type",
            name: "Creator type",
            treeID: tree.id,
            treeRevision: tree.revision,
            datasetID: dataset.id,
            datasetRevision: dataset.revision,
            applicablePlatformID: "youtube"
        )]

        XCTAssertTrue(catalog.removePlatformBinding("instagram"))
        XCTAssertEqual(catalog.bindings.map(\.id), ["youtube"])
        XCTAssertEqual(catalog.datasets[0].collectedEntries.map(\.platformID), ["youtube"])
        XCTAssertEqual(catalog.datasets[0].creatorClassifications.map(\.platformID), ["youtube"])
        XCTAssertEqual(catalog.datasets[0].revision, dataset.revision + 1)
        XCTAssertEqual(catalog.classifierTypes[0].applicablePlatformID, "youtube")
        XCTAssertFalse(catalog.models.contains(where: { $0.id == "instagram-only-model" }))
        let combined = try XCTUnwrap(catalog.models.first(where: { $0.id == "combined-model" }))
        XCTAssertEqual(combined.effectiveTrainingPlatformIDs, ["youtube"])
        XCTAssertEqual(combined.datasetRevision, catalog.datasets[0].revision)
        XCTAssertFalse(combined.isReady)
        XCTAssertFalse(catalog.models[0].isReady)
        XCTAssertNoThrow(try catalog.validate())
        XCTAssertFalse(catalog.removePlatformBinding("instagram"))
    }

    func testLegacyClassificationDatasetDecodesWithoutCreatorClassifications() throws {
        let legacy = Data(#"{"id":"legacy","name":"Legacy","records":[],"collectedEntries":[],"revision":1}"#.utf8)
        XCTAssertTrue(try JSONDecoder().decode(ClassificationDataset.self, from: legacy).creatorClassifications.isEmpty)
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

    func testClassifierTypeRequiresMatchingAssetsAndReconcilesStaleDependencies() throws {
        var catalog = WorkspaceCatalog.starter()
        catalog.trees[0].nodes = [.init(id: "games", name: "Games")]
        catalog.datasets[0].creatorClassifications = [
            .init(
                classifierTypeID: "games-neural",
                creatorID: "youtube:channel:games",
                creatorName: "Games creator",
                platformID: "youtube",
                treeID: catalog.trees[0].id,
                treeRevision: catalog.trees[0].revision,
                tagIDs: ["games"],
                origin: .manual,
                review: .approved
            ),
        ]
        catalog.datasets[0].collectedEntries = [
            .init(id: "game-entry", platformID: "youtube", entryID: "game-entry", creatorID: "youtube:channel:games", creatorName: "Games creator", entryType: "video", title: "Deck game guide"),
        ]
        catalog.models[0] = try LocalModelTrainer.train(
            catalog.models[0],
            tree: catalog.trees[0],
            dataset: catalog.datasets[0],
            epochs: 1,
            configuration: .init(vocabularyLimit: 16, embeddingDimension: 4, hiddenDimension: 4, initializationSeed: 3)
        )
        let profile = APIKeyProviderProfile(id: "gemini-profile", type: .gemini)
        catalog.providerProfiles = [profile]
        let tree = try XCTUnwrap(catalog.trees.first)
        let dataset = try XCTUnwrap(catalog.datasets.first)
        let classifierType = ClassifierTypeAsset(
            id: "creator-brain",
            name: "Creator brain",
            treeID: tree.id,
            treeRevision: tree.revision,
            datasetID: dataset.id,
            datasetRevision: dataset.revision,
            applicablePlatformID: "youtube",
            localModelID: catalog.models[0].id,
            llmAssistConfiguration: .init(providerProfileID: profile.id, modelIdentifier: "gemini-3.1-flash-lite")
        )
        catalog.classifierTypes = [classifierType]
        XCTAssertNoThrow(try catalog.validate())

        catalog.datasets[0].revision += 1
        XCTAssertThrowsError(try catalog.validate()) { error in
            XCTAssertEqual(error as? WorkspaceCatalogError, .invalidClassifierType(classifierType.id))
        }
        catalog.reconcileClassifierTypes()
        XCTAssertNoThrow(try catalog.validate())
        XCTAssertEqual(catalog.classifierTypes[0].datasetRevision, catalog.datasets[0].revision)
        XCTAssertNil(catalog.classifierTypes[0].localModelID)

        catalog.providerProfiles = []
        catalog.reconcileClassifierTypes()
        XCTAssertNil(catalog.classifierTypes[0].llmAssistConfiguration)
    }

    func testCoordinatorDispatchesAnActiveClassifierTypeToThePersistedNeuralModel() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = try LocalClassifierCoordinator(
            verifiedPackage: seed(),
            stateFile: .init(url: root.appendingPathComponent("state.json"))
        )
        var catalog = coordinator.snapshot().workspaceCatalog
        catalog.trees[0].nodes = [.init(id: "games", name: "Games")]
        let example = EmbeddedNeuralTrainingExample(text: "ranked deck game", positiveLabelIDs: ["games"])
        var neural = try EmbeddedNeuralTextClassifier(
            configuration: .init(vocabularyLimit: 16, embeddingDimension: 4, hiddenDimension: 4, initializationSeed: 9),
            labelIDs: ["games"],
            trainingExamples: [example]
        )
        _ = try neural.train([example], epochs: 2)
        catalog.models[0].isReady = true
        catalog.models[0].version = 7
        catalog.models[0].embeddedNeuralModel = neural
        catalog.models[0].embeddedTrainingReport = .init(epochs: 2, exampleCount: 1, labelUpdateCount: 2, meanBinaryCrossEntropy: 0)
        let tree = try XCTUnwrap(catalog.trees.first)
        let dataset = try XCTUnwrap(catalog.datasets.first)
        let classifierType = ClassifierTypeAsset(
            id: "games-neural",
            name: "Games neural",
            treeID: tree.id,
            treeRevision: tree.revision,
            datasetID: dataset.id,
            datasetRevision: dataset.revision,
            applicablePlatformID: "youtube",
            localModelID: catalog.models[0].id
        )
        catalog.classifierTypes = [classifierType]
        catalog.bindings[0].activeClassifierTypeID = classifierType.id
        catalog.bindings[0].activeModelID = catalog.models[0].id
        try coordinator.updateWorkspaceCatalog(catalog)

        let result = try coordinator.classifyWithLedger(.init(
            platform: "youtube",
            entryID: "browser-entry",
            sourceID: "creator",
            surface: .feed,
            evidence: .init(title: "ranked deck game")
        )).result

        XCTAssertEqual(result.packageID, "workspace-classifier-type-games-neural")
        XCTAssertEqual(result.modelVersion, "local-neural-local-neural-model-v7")
        XCTAssertEqual(result.scores.map(\.tagID), ["games"])
    }

    func testModelTrainingUsesOnlyApprovedCreatorClassificationsForItsTreeAndPlatform() throws {
        let tree = TagTreeAsset(
            id: "interests",
            name: "Interests",
            nodes: [
                .init(id: "games", name: "Games"),
                .init(id: "technology", name: "Technology"),
                .init(id: "cooking", name: "Cooking"),
            ]
        )
        let gamesCreator = CreatorClassificationRecord(
            classifierTypeID: "creator-focus",
            creatorID: "youtube:channel:games",
            creatorName: "Games creator",
            platformID: "youtube",
            treeID: tree.id,
            treeRevision: tree.revision,
            tagIDs: ["games"],
            origin: .manual,
            review: .approved
        )
        let technologyCreator = CreatorClassificationRecord(
            classifierTypeID: "creator-focus",
            creatorID: "youtube:channel:technology",
            creatorName: "Technology creator",
            platformID: "youtube",
            treeID: tree.id,
            treeRevision: tree.revision,
            tagIDs: ["technology"],
            origin: .llmAssist,
            review: .approved
        )
        let cookingCreator = CreatorClassificationRecord(
            classifierTypeID: "creator-focus",
            creatorID: "youtube:channel:cooking",
            creatorName: "Cooking creator",
            platformID: "youtube",
            treeID: tree.id,
            treeRevision: tree.revision,
            tagIDs: ["cooking"],
            origin: .manual,
            review: .approved
        )
        let pendingCreator = CreatorClassificationRecord(
            classifierTypeID: "creator-focus",
            creatorID: "youtube:channel:pending",
            creatorName: "Pending creator",
            platformID: "youtube",
            treeID: tree.id,
            treeRevision: tree.revision,
            tagIDs: ["games"],
            origin: .llmAssist,
            review: .pending
        )
        let otherPlatformCreator = CreatorClassificationRecord(
            classifierTypeID: "creator-focus",
            creatorID: "twitch:channel:games",
            creatorName: "Twitch games creator",
            platformID: "twitch",
            treeID: tree.id,
            treeRevision: tree.revision,
            tagIDs: ["games"],
            origin: .manual,
            review: .approved
        )
        let outdatedTreeCreator = CreatorClassificationRecord(
            classifierTypeID: "creator-focus",
            creatorID: "youtube:channel:old-tree",
            creatorName: "Old tree creator",
            platformID: "youtube",
            treeID: tree.id,
            treeRevision: tree.revision + 1,
            tagIDs: ["games"],
            origin: .manual,
            review: .approved
        )
        let dataset = ClassificationDataset(
            id: "personal-labels",
            name: "Personal labels",
            records: [
                .init(title: "Legacy entry label", tagIDs: ["games"], origin: .manual, review: .approved, platformID: "youtube", treeRevision: tree.revision),
            ],
            creatorClassifications: [gamesCreator, technologyCreator, cookingCreator, pendingCreator, otherPlatformCreator, outdatedTreeCreator],
            collectedEntries: [
                .init(id: "games-guide", platformID: "youtube", entryID: "games-guide", creatorID: gamesCreator.creatorID, creatorName: gamesCreator.creatorName, entryType: "video", title: "Fast deck guide for the arena"),
                .init(id: "games-patch", platformID: "youtube", entryID: "games-patch", creatorID: gamesCreator.creatorID, creatorName: gamesCreator.creatorName, entryType: "video", title: "Patch notes and ranked gameplay"),
                .init(id: "technology-network", platformID: "youtube", entryID: "technology-network", creatorID: technologyCreator.creatorID, creatorName: technologyCreator.creatorName, entryType: "video", title: "Build a compact neural network"),
                .init(id: "technology-embedding", platformID: "youtube", entryID: "technology-embedding", creatorID: technologyCreator.creatorID, creatorName: technologyCreator.creatorName, entryType: "video", title: "Review a local embedding model"),
                .init(id: "cooking-pasta", platformID: "youtube", entryID: "cooking-pasta", creatorID: cookingCreator.creatorID, creatorName: cookingCreator.creatorName, entryType: "video", title: "Quick pasta recipe"),
                .init(id: "cooking-bread", platformID: "youtube", entryID: "cooking-bread", creatorID: cookingCreator.creatorID, creatorName: cookingCreator.creatorName, entryType: "video", title: "Bake sourdough bread"),
                .init(id: "pending", platformID: "youtube", entryID: "pending", creatorID: pendingCreator.creatorID, creatorName: pendingCreator.creatorName, entryType: "video", title: "Unreviewed suggestion"),
                .init(id: "twitch", platformID: "twitch", entryID: "twitch", creatorID: otherPlatformCreator.creatorID, creatorName: otherPlatformCreator.creatorName, entryType: "stream", title: "Another platform"),
                .init(id: "old-tree", platformID: "youtube", entryID: "old-tree", creatorID: outdatedTreeCreator.creatorID, creatorName: outdatedTreeCreator.creatorName, entryType: "video", title: "Old tree"),
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

    func testProviderProfilesKeepSelectedLanguageAndPlatformTransports() throws {
        let profiles: [APIKeyProviderProfile] = [
            .init(id: "deepseek-key", type: .deepSeek),
            .init(id: "youtube-key", type: .youtubeData),
            .init(id: "custom-key", type: .custom, customEndpoint: "https://api.example.com/v1"),
        ]
        var catalog = WorkspaceCatalog.starter()
        catalog.providerProfiles = profiles

        XCTAssertNoThrow(try catalog.validate())
        XCTAssertEqual(
            Set(APIKeyProviderType.allCases),
            [
                .openAI, .openAICompatible, .deepSeek, .gemini, .anthropic,
                .mistral, .cohere, .groq, .openRouter, .ollama,
                .youtubeData, .twitch, .reddit, .xPlatform, .tikTok,
                .instagramGraph, .facebookGraph, .custom,
            ]
        )
        let encoded = try JSONEncoder().encode(catalog)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("apiKey"))
        XCTAssertEqual(try JSONDecoder().decode(WorkspaceCatalog.self, from: encoded).providerProfiles, profiles)
    }

    func testRemovedPlatformProfileIsResetAndDroppedDuringReconciliation() throws {
        let direct = Data(#"{"id":"direct","name":"Direct","type":"deepSeek","modelIdentifier":"deepseek-chat","batchSize":1,"maximumTokens":10,"updatedAtMilliseconds":1}"#.utf8)
        let decoded = try JSONDecoder().decode(APIKeyProviderProfile.self, from: direct)
        XCTAssertEqual(decoded.type, .deepSeek)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self).contains("modelIdentifier"))

        let retired = Data(#"{"id":"retired","name":"Retired","type":"spotify","modelIdentifier":"grok","batchSize":1,"maximumTokens":10,"updatedAtMilliseconds":1}"#.utf8)
        let reset = try JSONDecoder().decode(APIKeyProviderProfile.self, from: retired)
        XCTAssertEqual(reset.type, .openAICompatible)
        XCTAssertEqual(reset.name, "")
        XCTAssertThrowsError(try reset.validate())

        var catalog = WorkspaceCatalog.starter()
        catalog.providerProfiles = [reset]
        catalog.reconcileClassifierTypes()
        XCTAssertTrue(catalog.providerProfiles.isEmpty)
        XCTAssertNoThrow(try catalog.validate())
    }

    func testProviderProtocolsExposeWorkingRequestPlansForEverySupportedType() throws {
        for type in APIKeyProviderType.allCases {
            let descriptor = ProviderProtocolRegistry.descriptor(for: type)
            XCTAssertEqual(descriptor.identifier, type.rawValue)
            XCTAssertEqual(descriptor.revision, ProviderProtocolDescriptor.currentRevision)
            XCTAssertFalse(descriptor.requestFormats.isEmpty)
            XCTAssertEqual(type.supportsLLMConfiguration, descriptor.supportsLLMConfiguration)
        }

        let gemini = APIKeyProviderProfile(type: .gemini)
        let geminiPlan = try DescriptorBackedProviderProtocol(descriptor: .init(
            identifier: "gemini",
            family: .geminiGenerateContentV1Beta,
            defaultBaseURL: "https://generativelanguage.googleapis.com/v1beta",
            authentication: .apiKeyHeader,
            authenticationHeader: "x-goog-api-key",
            credentialFields: [.apiKey],
            requestFormats: [.init(operation: .generateText, method: "POST", pathTemplate: "/models/{model}:generateContent", bodyFormat: .geminiGenerateContent)]
        )).requestPlan(for: gemini, operation: .generateText)
        XCTAssertEqual(geminiPlan.method, "POST")
        XCTAssertEqual(geminiPlan.bodyFormat, .geminiGenerateContent)
        XCTAssertEqual(geminiPlan.authenticationHeader, "x-goog-api-key")
        XCTAssertEqual(geminiPlan.url.absoluteString, "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-lite:generateContent")

        let compatible = APIKeyProviderProfile(type: .openAICompatible, customEndpoint: "https://api.deepseek.com/v1")
        let compatiblePlan = try DescriptorBackedProviderProtocol(descriptor: ProviderProtocolRegistry.descriptor(for: .openAICompatible))
            .requestPlan(for: compatible, operation: .generateText, modelIdentifier: "deepseek-chat")
        XCTAssertEqual(compatiblePlan.url.absoluteString, "https://api.deepseek.com/v1/chat/completions")
        XCTAssertEqual(compatiblePlan.bodyFormat, .openAIChatCompletions)

        let deepSeek = APIKeyProviderProfile(type: .deepSeek)
        let deepSeekPlan = try DescriptorBackedProviderProtocol(descriptor: ProviderProtocolRegistry.descriptor(for: .deepSeek))
            .requestPlan(for: deepSeek, operation: .generateText)
        XCTAssertEqual(deepSeekPlan.url.absoluteString, "https://api.deepseek.com/v1/chat/completions")

        let custom = APIKeyProviderProfile(type: .custom, customEndpoint: "https://api.example.com/v1")
        let customPlan = try DescriptorBackedProviderProtocol(descriptor: ProviderProtocolRegistry.descriptor(for: .custom))
            .requestPlan(for: custom, operation: .generateText)
        XCTAssertEqual(customPlan.url.absoluteString, "https://api.example.com/v1/chat/completions")
        XCTAssertEqual(customPlan.bodyFormat, .openAIChatCompletions)
    }

    func testProviderProtocolsRejectUnsafeOrIncompleteDispatchSettings() throws {
        let unsafeEndpoint = APIKeyProviderProfile(type: .openAICompatible, customEndpoint: "http://remote.example")
        XCTAssertThrowsError(try unsafeEndpoint.validate())

        let missingEndpoint = APIKeyProviderProfile(type: .openAICompatible)
        XCTAssertNoThrow(try missingEndpoint.validate())
        XCTAssertThrowsError(try missingEndpoint.validateForDispatch())
    }

    func testProtocolCredentialRecordsRequireTheDeclaredFieldSet() throws {
        let descriptor = ProviderProtocolRegistry.descriptor(for: .openAI)
        XCTAssertNoThrow(try ProviderCredentialRecord(values: [.apiKey: "token-value"]).validate(for: descriptor))
        XCTAssertNoThrow(try ProviderCredentialRecord(values: [.apiKey: " token-value\n"]).validate(for: descriptor))
        XCTAssertThrowsError(try ProviderCredentialRecord(values: [.bearerToken: "token-value"]).validate(for: descriptor))
    }

    func testLegacyCatalogDecodesWithoutProviderProfiles() throws {
        let encoded = try JSONEncoder().encode(WorkspaceCatalog.starter())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "providerProfiles")
        let legacy = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])

        XCTAssertTrue(try JSONDecoder().decode(WorkspaceCatalog.self, from: legacy).providerProfiles.isEmpty)
    }
}
