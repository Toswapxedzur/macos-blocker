import XCTest
@testable import VaultClassifierCore

final class WorkspaceAssetsTests: XCTestCase {
    private func seed() throws -> VerifiedSeedPackage { try SeedPackageLoader.bundled() }

    func testCollectionRegistryMarksOnlyInstalledPublicContentCollectorsAvailable() {
        let available = Set(CollectionPlatformRegistry.definitions.lazy.filter(\.collectorAvailable).map(\.id))
        XCTAssertEqual(available, Set([
            "youtube", "tiktok", "facebook", "instagram", "twitch", "reddit",
            "twitter", "bluesky", "threads", "substack", "bilibili", "rumble",
            "pinterest", "tumblr", "peertube", "pixelfed",
        ]))
        XCTAssertFalse(CollectionPlatformRegistry.definition(for: "discord")?.collectorAvailable ?? true)
        XCTAssertFalse(CollectionPlatformRegistry.definition(for: "kick")?.collectorAvailable ?? true)
        XCTAssertFalse(CollectionPlatformRegistry.definition(for: "kuaishou")?.collectorAvailable ?? true)
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

    func testCreatorClassificationsAreDurableSourceOfTruthAndApprovedLLMLabelsTrain() throws {
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
        XCTAssertFalse(examples.contains(where: { $0.text == "Do not train this" }))

        var updated = manual
        updated.tagIDs = ["technology"]
        updated.updatedAtMilliseconds = 200
        let retained = dataset.upsertCreatorClassification(updated)
        XCTAssertEqual(dataset.creatorClassifications.count, 3)
        XCTAssertEqual(retained.id, manual.id)
        XCTAssertEqual(retained.createdAtMilliseconds, 100)
        XCTAssertEqual(retained.tagIDs, ["technology"])
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
            records: [
                .init(title: "YouTube deck guide", tagIDs: ["games"], origin: .manual, review: .approved, platformID: "youtube", treeRevision: tree.revision),
                .init(title: "Twitch stream", tagIDs: ["games"], origin: .manual, review: .approved, platformID: "twitch", treeRevision: tree.revision),
            ],
            creatorClassifications: [instagramCreator],
            collectedEntries: [
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

    func testLegacyClassifierTypeMigratesToAllCompatiblePlatformSources() throws {
        let legacy = Data(#"{"id":"legacy-type","name":"Legacy type","treeID":"vault-starter","treeRevision":1,"datasetID":"local-dataset","datasetRevision":1,"localModelID":null,"llmProfileIDs":[],"decisionPriority":["human","llmAssist","localModel"],"creatorDecisionSources":["human"],"entryDecisionSources":[],"updatedAtMilliseconds":0}"#.utf8)
        let type = try JSONDecoder().decode(ClassifierTypeAsset.self, from: legacy)
        XCTAssertTrue(type.dataSourcePlatformIDs.isEmpty)

        var catalog = WorkspaceCatalog.starter()
        catalog.bindings.append(.init(id: "instagram", treeID: "vault-starter", datasetID: "local-dataset"))
        catalog.classifierTypes = [type]
        catalog.reconcileClassifierTypes()

        XCTAssertEqual(catalog.classifierTypes[0].dataSourcePlatformIDs, ["instagram", "youtube"])
        XCTAssertNoThrow(try catalog.validate())
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
        catalog.datasets[0].records = [
            .init(title: "Deck game guide", tagIDs: ["games"], origin: .manual, review: .approved, platformID: "youtube", treeRevision: catalog.trees[0].revision),
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
            localModelID: catalog.models[0].id,
            llmProfileIDs: [profile.id],
            creatorDecisionSources: [.human, .llmAssist, .localModel],
            entryDecisionSources: [.localModel]
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
        XCTAssertFalse(catalog.classifierTypes[0].creatorDecisionSources.contains(.localModel))
        XCTAssertFalse(catalog.classifierTypes[0].entryDecisionSources.contains(.localModel))

        catalog.providerProfiles = []
        catalog.reconcileClassifierTypes()
        XCTAssertTrue(catalog.classifierTypes[0].llmProfileIDs.isEmpty)
        XCTAssertFalse(catalog.classifierTypes[0].creatorDecisionSources.contains(.llmAssist))
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
            localModelID: catalog.models[0].id,
            entryDecisionSources: [.localModel]
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
                .instagramGraph, .facebookGraph, .linkedIn, .pinterest,
                .bluesky, .mastodon, .vimeo, .dailyMotion, .spotify, .custom,
            ]
        )
        let encoded = try JSONEncoder().encode(catalog)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("apiKey"))
        XCTAssertEqual(try JSONDecoder().decode(WorkspaceCatalog.self, from: encoded).providerProfiles, profiles)
    }

    func testDirectPresetsRemainReadableAndRetiredNamesMigrateToCompatibleTransport() throws {
        let direct = Data(#"{"id":"direct","name":"Direct","type":"deepSeek","modelIdentifier":"deepseek-chat","batchSize":1,"maximumTokens":10,"updatedAtMilliseconds":1}"#.utf8)
        let decoded = try JSONDecoder().decode(APIKeyProviderProfile.self, from: direct)
        XCTAssertEqual(decoded.type, .deepSeek)
        XCTAssertEqual(decoded.modelIdentifier, "deepseek-chat")

        let retired = Data(#"{"id":"retired","name":"Retired","type":"xAI","modelIdentifier":"grok","batchSize":1,"maximumTokens":10,"updatedAtMilliseconds":1}"#.utf8)
        let migrated = try JSONDecoder().decode(APIKeyProviderProfile.self, from: retired)
        XCTAssertEqual(migrated.type, .openAICompatible)
        XCTAssertEqual(migrated.modelIdentifier, "grok")
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

        let compatible = APIKeyProviderProfile(type: .openAICompatible, modelIdentifier: "deepseek-chat", customEndpoint: "https://api.deepseek.com/v1")
        let compatiblePlan = try DescriptorBackedProviderProtocol(descriptor: ProviderProtocolRegistry.descriptor(for: .openAICompatible))
            .requestPlan(for: compatible, operation: .generateText)
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
        let unsafeEndpoint = APIKeyProviderProfile(type: .openAICompatible, modelIdentifier: "model", customEndpoint: "http://remote.example")
        XCTAssertThrowsError(try unsafeEndpoint.validate())

        let missingEndpoint = APIKeyProviderProfile(type: .openAICompatible, modelIdentifier: "model")
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
