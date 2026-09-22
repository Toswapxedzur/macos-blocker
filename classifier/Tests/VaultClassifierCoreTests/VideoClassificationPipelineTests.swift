import XCTest
@testable import VaultClassifierCore

// Captures the request the pipeline sent, and returns a scripted result.
private final class RequestRecorder: @unchecked Sendable {
    var last: LLMClassificationRequest?
}

private struct ScriptedOnDeviceLLM: OnDeviceLLM {
    let modelVersion: String
    let result: LLMClassificationResult
    let recorder: RequestRecorder
    func classify(_ request: LLMClassificationRequest) async throws -> LLMClassificationResult {
        recorder.last = request
        return result
    }
}

final class VideoClassificationPipelineTests: XCTestCase {

    private func makeTree() -> TagTreeAsset {
        TagTreeAsset(id: "tree", name: "Topics", nodes: [
            .init(id: "g", name: "Games"),
            .init(id: "m", name: "Minecraft", parentID: "g"),
            .init(id: "p", name: "Politics"),
            .init(id: "o", name: "Old", isRetired: true),
        ])
    }

    private func makeType() -> ClassifierTypeAsset {
        ClassifierTypeAsset(
            id: "type", name: "YT", treeID: "tree", treeRevision: 1,
            datasetID: "ds", datasetRevision: 1, applicablePlatformID: "youtube"
        )
    }

    // MARK: - Assembler

    func testTagOptionsSkipRetiredAndResolveParentName() {
        let options = ClassificationPromptAssembler.tagOptions(from: makeTree())
        XCTAssertEqual(options.map(\.name), ["Games", "Minecraft", "Politics"]) // "Old" retired, excluded
        XCTAssertEqual(options.first { $0.name == "Minecraft" }?.parentName, "Games")
        XCTAssertNil(options.first { $0.name == "Politics" }?.parentName)
    }

    func testStaticPrefixIsDeterministicAndIncludesHouseRules() {
        let taxonomy = ClassificationPromptAssembler.tagOptions(from: makeTree())
        let a = ClassificationPromptAssembler.staticPrefix(taxonomy: taxonomy, houseRules: "Tag gaming-news as Politics.", maximumTags: 5)
        let b = ClassificationPromptAssembler.staticPrefix(taxonomy: taxonomy, houseRules: "Tag gaming-news as Politics.", maximumTags: 5)
        XCTAssertEqual(a, b, "same input must produce a byte-identical prefix for KV caching")
        XCTAssertTrue(a.contains("House rules"))
        XCTAssertTrue(a.contains("Tag gaming-news as Politics."))
        XCTAssertTrue(a.contains("- Minecraft (under Games)"))
    }

    func testDynamicSuffixFeedsCreatorStatsAsDataWithoutFraming() {
        let knowledge = [KnowledgeEntry(kind: .term, subject: "HermitCraft", meaning: "A Minecraft SMP.")]
        let suffix = ClassificationPromptAssembler.dynamicSuffix(
            title: "HermitCraft finale", summary: nil, text: nil,
            creatorPrior: [CreatorPriorTag(tagName: "Games", count: 17, share: 17.0 / 20.0, averageConfidence: 4.2, confidenceStdev: 0.6)],
            creatorVideoCount: 20,
            knowledge: knowledge
        )
        XCTAssertTrue(suffix.contains("HermitCraft: A Minecraft SMP."))
        // Owner spec: total classified videos + a frequency per tag — nothing else
        // (no percentages, no confidence statistics), on one compact line; no framing.
        XCTAssertTrue(suffix.contains("Creator (20 videos): Games 17"))
        XCTAssertFalse(suffix.contains("%"))
        XCTAssertFalse(suffix.contains("±"))
        XCTAssertTrue(suffix.contains("Title: HermitCraft finale"))
        XCTAssertFalse(suffix.contains("weight it lightly"))
        XCTAssertFalse(suffix.contains("STRONG default"))
    }

    // MARK: - Pipeline

    func testPipelineWithStubProducesTagFromTitle() async throws {
        let pipeline = VideoClassificationPipeline(llm: StubOnDeviceLLM())
        let catalog = WorkspaceCatalog()
        let result = try await pipeline.classify(
            title: "A great Games montage", entryID: "v1", creatorID: "c1", platformID: "youtube",
            classifierType: makeType(), tree: makeTree(), catalog: catalog
        )
        XCTAssertEqual(result.tags.map(\.tagID), ["g"])   // "Games" matched -> id g
        XCTAssertEqual(result.source, .model)
        XCTAssertEqual(result.creatorID, "c1")
    }

    func testPipelineMapsNamesToIDsAndDropsUnknownNames() async throws {
        let recorder = RequestRecorder()
        let llm = ScriptedOnDeviceLLM(
            modelVersion: "scripted/v9",
            result: LLMClassificationResult(
                tags: [LLMTagScore(name: "Games", confidence: 5), LLMTagScore(name: "NotATag", confidence: 3)]
            ),
            recorder: recorder
        )
        let pipeline = VideoClassificationPipeline(llm: llm, promptVersion: "pX")
        let result = try await pipeline.classify(
            title: "Some vague title", entryID: "v1", creatorID: "c1", platformID: "youtube",
            classifierType: makeType(), tree: makeTree(), catalog: WorkspaceCatalog()
        )
        XCTAssertEqual(result.tags, [ScoredTag(tagID: "g", confidence: 5)]) // NotATag dropped
        XCTAssertEqual(result.modelVersion, "scripted/v9+pX")
    }

    func testPipelineInjectsKnowledgeAndMarksSource() async throws {
        let recorder = RequestRecorder()
        let llm = ScriptedOnDeviceLLM(
            modelVersion: "s/1",
            result: LLMClassificationResult(tags: [LLMTagScore(name: "Games", confidence: 4)]),
            recorder: recorder
        )
        var catalog = WorkspaceCatalog()
        catalog.upsertKnowledgeEntry(KnowledgeEntry(kind: .term, subject: "HermitCraft", meaning: "A Minecraft SMP."))
        let pipeline = VideoClassificationPipeline(llm: llm)
        let result = try await pipeline.classify(
            title: "HermitCraft season 9", entryID: "v1", creatorID: "c1", platformID: "youtube",
            classifierType: makeType(), tree: makeTree(), catalog: catalog
        )
        XCTAssertEqual(result.source, .modelKnowledge)
        XCTAssertEqual(result.knowledgeRefs, ["term:hermitcraft"])
        XCTAssertTrue(recorder.last?.dynamicSuffix.contains("A Minecraft SMP.") ?? false)
    }

    func testPipelineFeedsDerivedCreatorPriorIntoPrompt() async throws {
        let recorder = RequestRecorder()
        let llm = ScriptedOnDeviceLLM(
            modelVersion: "s/1",
            result: LLMClassificationResult(tags: []),
            recorder: recorder
        )
        // Seed a prior: creator c1 already has a video tagged Games(5).
        var catalog = WorkspaceCatalog()
        catalog.upsertVideoClassification(VideoClassification(
            classifierTypeID: "type", platformID: "youtube", entryID: "seed", creatorID: "c1",
            treeID: "tree", treeRevision: 1, tags: [ScoredTag(tagID: "g", confidence: 5)],
            source: .model, modelVersion: "s/1"))

        let pipeline = VideoClassificationPipeline(llm: llm)
        _ = try await pipeline.classify(
            title: "vague", entryID: "v2", creatorID: "c1", platformID: "youtube",
            classifierType: makeType(), tree: makeTree(), catalog: catalog
        )
        let suffix = try XCTUnwrap(recorder.last?.dynamicSuffix)
        XCTAssertTrue(suffix.contains("Creator (1 videos): Games 1"))
    }

    func testPipelineCarriesPerTypeRequestOverrides() async throws {
        let recorder = RequestRecorder()
        let llm = ScriptedOnDeviceLLM(
            modelVersion: "s/1",
            result: .init(tags: []),
            recorder: recorder
        )
        let pipeline = VideoClassificationPipeline(llm: llm)
        _ = try await pipeline.classify(
            title: "Unclear title", entryID: "v1", creatorID: "c1", platformID: "youtube",
            classifierType: makeType(), tree: makeTree(), catalog: WorkspaceCatalog(),
            houseRules: "Prefer Politics.", allowDecline: false,
            confidenceThresholds: [0.1, 0.3, 0.6, 0.9]
        )
        XCTAssertEqual(recorder.last?.allowDecline, false)
        XCTAssertEqual(recorder.last?.confidenceThresholds, [0.1, 0.3, 0.6, 0.9])
        XCTAssertTrue(recorder.last?.staticPrefix.contains("Prefer Politics.") == true)
    }

    func testLowConfidenceCreatorGroundingInfersTagFromCreatorDescription() async throws {
        var catalog = WorkspaceCatalog()
        // Creator keyed with a description that names an allowed tag.
        catalog.upsertKnowledgeEntry(KnowledgeEntry(kind: .creator, subject: "c1", meaning: "A Politics news channel."))
        let pipeline = VideoClassificationPipeline(llm: StubOnDeviceLLM())

        // Title carries no allowed tag name -> the content-only primary decode
        // declines. Because the creator is keyed, the pipeline runs a second
        // decode grounded on the creator description and infers "Politics".
        let result = try await pipeline.classify(
            title: "weekly roundup", entryID: "v1", creatorID: "c1", platformID: "youtube",
            classifierType: makeType(), tree: makeTree(), catalog: catalog
        )
        XCTAssertEqual(result.tags.map(\.tagID), ["p"])
        XCTAssertEqual(result.source, .modelKnowledge)
        XCTAssertEqual(result.knowledgeRefs, ["creator:c1"])
    }

    func testConfidentPrimaryDoesNotUseCreatorGrounding() async throws {
        var catalog = WorkspaceCatalog()
        catalog.upsertKnowledgeEntry(KnowledgeEntry(kind: .creator, subject: "c1", meaning: "A Politics channel."))
        let pipeline = VideoClassificationPipeline(llm: StubOnDeviceLLM())

        // Title names "Games" -> the primary decode tags it confidently, so the
        // creator description is never consulted.
        let result = try await pipeline.classify(
            title: "Games highlights", entryID: "v1", creatorID: "c1", platformID: "youtube",
            classifierType: makeType(), tree: makeTree(), catalog: catalog
        )
        XCTAssertEqual(result.tags.map(\.tagID), ["g"])
        XCTAssertEqual(result.source, .model)
        XCTAssertTrue(result.knowledgeRefs.isEmpty)
    }

    func testCreatorGroundingSkippedWhenCreatorNotKeyed() async throws {
        let catalog = WorkspaceCatalog()   // no creator description
        let pipeline = VideoClassificationPipeline(llm: StubOnDeviceLLM())
        let result = try await pipeline.classify(
            title: "weekly roundup", entryID: "v1", creatorID: "c1", platformID: "youtube",
            classifierType: makeType(), tree: makeTree(), catalog: catalog
        )
        XCTAssertTrue(result.tags.isEmpty)       // declines, no fallback available
        XCTAssertEqual(result.source, .model)
    }

    func testGranularResearchDefaultsLeaveClassificationRequestByteIdentical() async throws {
        let recorder = RequestRecorder()
        let pipeline = VideoClassificationPipeline(llm: ScriptedOnDeviceLLM(
            modelVersion: "s/1",
            result: .init(tags: []),
            recorder: recorder
        ))
        var catalog = WorkspaceCatalog()
        catalog.upsertKnowledgeEntry(.init(
            kind: .term,
            subject: "HermitCraft",
            meaning: "A Minecraft SMP."
        ))

        let inherited = try await pipeline.classify(
            title: "HermitCraft finale", entryID: "v", creatorID: "c", platformID: "youtube",
            classifierType: makeType(), tree: makeTree(), catalog: catalog
        )
        let inheritedRequest = try XCTUnwrap(recorder.last)
        let defaults = ResearchSettings()
        let explicit = try await pipeline.classify(
            title: "HermitCraft finale", entryID: "v", creatorID: "c", platformID: "youtube",
            classifierType: makeType(), tree: makeTree(), catalog: catalog,
            knowledgeTTLDays: defaults.knowledgeTTLDays,
            maxKnowledgePerVideo: defaults.maxKnowledgePerVideo
        )

        XCTAssertEqual(recorder.last, inheritedRequest)
        XCTAssertEqual(explicit.knowledgeRefs, inherited.knowledgeRefs)
        XCTAssertEqual(explicit.source, inherited.source)
    }
}
