import XCTest
@testable import VaultClassifierCore

final class CorrectionExampleSelectorTests: XCTestCase {
    private let tree = TagTreeAsset(id: "tree", name: "Topics", revision: 2, nodes: [
        .init(id: "games", name: "Games"),
        .init(id: "sports", name: "Sports"),
        .init(id: "retired", name: "Old tag", isRetired: true)
    ])
    private var group: ClassifierTypeAsset {
        .init(id: "group", name: "Videos", treeID: tree.id, treeRevision: tree.revision,
              datasetID: "dataset", datasetRevision: 1, applicablePlatformIDs: ["youtube"])
    }

    private func corrected(_ id: String, title: String, tags: [String],
                           typeID: String = "group", platform: String = "youtube",
                           revision: Int = 2, source: VideoClassificationSource = .humanCorrected,
                           creator: String = "creator") -> (CorrectionExample, VideoClassification) {
        let example = CorrectionExample(id: id, classifierTypeID: typeID,
            platformID: platform, entryID: id, creatorID: creator,
            title: title, correctTagIDs: tags, note: "Do not leak this note")
        let row = VideoClassification(classifierTypeID: typeID, platformID: platform,
            entryID: id, creatorID: creator, treeID: tree.id, treeRevision: revision,
            tags: tags.map { .init(tagID: $0, confidence: 5) },
            source: source, modelVersion: "human")
        return (example, row)
    }

    func testSelectsOnlyCurrentHumanCorrectionsFromTheSameGroupAndPlatform() {
        let fixtures = [
            corrected("relevant", title: "Minecraft base tutorial", tags: ["games"]),
            corrected("empty", title: "Minecraft reaction", tags: []),
            corrected("other-group", title: "Minecraft server", tags: ["games"], typeID: "other"),
            corrected("other-platform", title: "Minecraft update", tags: ["games"], platform: "reddit"),
            corrected("stale-tree", title: "Minecraft build", tags: ["games"], revision: 1),
            corrected("model-row", title: "Minecraft gameplay", tags: ["games"], source: .model),
            corrected("retired-tag", title: "Minecraft old", tags: ["retired"])
        ]
        var catalog = WorkspaceCatalog()
        catalog.correctionExamples = fixtures.map(\.0)
        catalog.videoClassifications = fixtures.map(\.1)
        let selector = CorrectionExampleSelector(catalog: catalog, classifierType: group, platformID: "youtube", tree: tree)
        let examples = selector.select(title: "Minecraft base guide", creatorID: "someone-else", excluding: "target")
        XCTAssertEqual(examples.map(\.title), ["Minecraft base tutorial", "Minecraft reaction"])
        XCTAssertEqual(examples.map(\.tagNames), [["Games"], []])
        XCTAssertEqual(selector.select(title: "Minecraft base guide", creatorID: "someone-else", excluding: "relevant").map(\.title),
                       ["Minecraft reaction"])
        XCTAssertTrue(selector.select(title: "Unrelated subject", creatorID: "someone-else", excluding: "target").isEmpty)
        XCTAssertTrue(selector.select(title: "Unrelated subject", creatorID: "creator", excluding: "target").isEmpty,
                      "a creator match alone does not make a correction relevant")
    }

    func testPromptTreatsCorrectionsAsDataAndKeepsNotesOut() {
        let fixtures = [corrected("one", title: "Minecraft base tutorial", tags: ["games"])]
        var catalog = WorkspaceCatalog()
        catalog.correctionExamples = fixtures.map(\.0)
        catalog.videoClassifications = fixtures.map(\.1)
        let selected = CorrectionExampleSelector(catalog: catalog, classifierType: group, platformID: "youtube", tree: tree)
            .select(title: "Minecraft guide", creatorID: "different", excluding: "target")
        let prompt = ClassificationPromptAssembler.dynamicSuffix(
            title: "Minecraft guide", summary: nil, text: nil,
            creatorPrior: [], creatorVideoCount: 0, correctionExamples: selected)
        XCTAssertTrue(prompt.contains("Past human corrections"))
        XCTAssertTrue(prompt.contains(#""tagNames":["Games"]"#))
        XCTAssertTrue(prompt.contains("Minecraft base tutorial"))
        XCTAssertFalse(prompt.contains("Do not leak this note"))
        XCTAssertTrue(prompt.contains("Title: Minecraft guide"))
    }
}
