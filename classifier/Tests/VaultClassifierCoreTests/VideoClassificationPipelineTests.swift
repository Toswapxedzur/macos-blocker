import XCTest
@testable import VaultClassifierCore

// Captures the request the pipeline sent, and returns a scripted result.
private final class RequestRecorder: @unchecked Sendable {
    var last: LLMClassificationRequest?
    var count = 0
}

private struct ScriptedClassificationEngine: ClassificationEngine {
    let modelVersion: String
    let result: LLMClassificationResult
    let recorder: RequestRecorder
    func classify(_ request: LLMClassificationRequest) async throws -> LLMClassificationResult {
        recorder.count += 1; recorder.last = request
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
            datasetID: "ds", datasetRevision: 1, applicablePlatformIDs: ["youtube"]
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
        let suffix = ClassificationPromptAssembler.dynamicSuffix(
            title: "HermitCraft finale", summary: nil, text: nil,
            creatorPrior: [CreatorPriorTag(tagName: "Games", count: 17, share: 17.0 / 20.0, averageConfidence: 4.2, confidenceStdev: 0.6)],
            creatorVideoCount: 20
        )
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
        let pipeline = VideoClassificationPipeline(llm: StubClassificationEngine())
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
        let llm = ScriptedClassificationEngine(
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


    func testConfidenceCutoffAppliesToFirstAndEveryAdditionalTag() async throws {
        let recorder = RequestRecorder()
        let llm = ScriptedClassificationEngine(
            modelVersion: "scripted/v10",
            result: .init(tags: [
                .init(name: "Games", confidence: 3),
                .init(name: "Minecraft", confidence: 4),
                .init(name: "Politics", confidence: 5)
            ]),
            recorder: recorder
        )
        let pipeline = VideoClassificationPipeline(llm: llm, maximumTags: 32, minimumConfidence: 4, promptVersion: "p6")
        let result = try await pipeline.classify(
            title: "Mixed title", entryID: "v1", creatorID: "c1", platformID: "youtube",
            classifierType: makeType(), tree: makeTree(), catalog: WorkspaceCatalog()
        )
        XCTAssertEqual(result.tags.map(\.tagID), ["p", "m"])
        XCTAssertEqual(recorder.last?.minimumConfidence, 4)
        XCTAssertEqual(recorder.last?.minimumTags, 0)
        XCTAssertTrue(recorder.last?.staticPrefix.contains("zero is valid") == true)

        let strict = VideoClassificationPipeline(llm: llm, maximumTags: 32, minimumConfidence: 5, promptVersion: "p6")
        let strictResult = try await strict.classify(
            title: "Mixed title", entryID: "v2", creatorID: "c1", platformID: "youtube",
            classifierType: makeType(), tree: makeTree(), catalog: WorkspaceCatalog()
        )
        XCTAssertEqual(strictResult.tags.map(\.tagID), ["p"])

        let below = ScriptedClassificationEngine(modelVersion: "scripted/v11",
            result: .init(tags: [.init(name: "Games", confidence: 3)]), recorder: recorder)
        let empty = try await VideoClassificationPipeline(llm: below, minimumConfidence: 4, promptVersion: "p6").classify(
            title: "Ambiguous title", entryID: "v3", creatorID: "c1", platformID: "youtube",
            classifierType: makeType(), tree: makeTree(), catalog: WorkspaceCatalog()
        )
        XCTAssertTrue(empty.tags.isEmpty, "even the first suggestion must clear the cutoff")
    }

    func testPipelineFeedsDerivedCreatorPriorIntoPrompt() async throws {
        let recorder = RequestRecorder()
        let llm = ScriptedClassificationEngine(
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
        let llm = ScriptedClassificationEngine(
            modelVersion: "s/1",
            result: .init(tags: []),
            recorder: recorder
        )
        let pipeline = VideoClassificationPipeline(llm: llm)
        _ = try await pipeline.classify(
            title: "Unclear title", entryID: "v1", creatorID: "c1", platformID: "youtube",
            classifierType: makeType(), tree: makeTree(), catalog: WorkspaceCatalog(),
            houseRules: "Prefer Politics.", extraTagMinimumOdds: 0.97
        )
        XCTAssertEqual(recorder.last?.extraTagMinimumOdds, 0.97)
        XCTAssertTrue(recorder.last?.staticPrefix.contains("Prefer Politics.") == true)
    }

    /// A researched creator's one sentence rides on the creator line of the ONE
    /// pass (there is no second decode any more), and the classification records
    /// that the description was used.


}

extension VideoClassificationPipelineTests {
}
