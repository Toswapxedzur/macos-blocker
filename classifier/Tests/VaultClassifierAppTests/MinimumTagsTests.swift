import XCTest
@testable import VaultClassifierCore
@testable import VaultClassifierLLM

/// minimumTags (owner request 2026-09-18; the sibling `expectedTags` soft target was
/// measured to do nothing — exact match 40/42/40% — and removed): a min forces the model
/// to emit at least N best guesses instead of declining (recall over precision,
/// filtered at the policy floor); expected is a soft prompt target; max is the cap.
final class MinimumTagsTests: XCTestCase {

    // MARK: - Grammar (the hard bounds)

    func testMinZeroKeepsDeclineAndOneOptionalItem() throws {
        let g = try XCTUnwrap(VaultLocalLLMEngine.namesWithConfidenceGrammar(
            allowed: ["A", "B"], allowDecline: true, maximumTags: 1, minimumTags: 0, format: .json))
        XCTAssertTrue(g.contains(#"root ::= "none" | obj"#))   // may decline
    }

    func testMinOneDropsDeclineAndForcesAnItem() throws {
        let g = try XCTUnwrap(VaultLocalLLMEngine.namesWithConfidenceGrammar(
            allowed: ["A", "B"], allowDecline: true, maximumTags: 1, minimumTags: 1, format: .json))
        XCTAssertEqual(g.components(separatedBy: "\n").first, "root ::= obj")
        XCTAssertFalse(g.contains("none"), "min ≥ 1 must forbid declining")
    }

    func testMinTwoForcesTwoMandatoryItemsThenOptional() throws {
        // max 4, min 2 → obj + one mandatory `osep obj` + a 2-long optional chain.
        let g = try XCTUnwrap(VaultLocalLLMEngine.namesWithConfidenceGrammar(
            allowed: ["A", "B", "C", "D"], allowDecline: true, maximumTags: 4, minimumTags: 2, format: .json))
        XCTAssertTrue(g.contains("root ::= obj osep obj tail0"))
        XCTAssertTrue(g.contains(#"tail0 ::= "" | osep obj tail1"#))
        XCTAssertTrue(g.contains(#"tail1 ::= "" | osep obj"#))
        XCTAssertFalse(g.contains("tail2"))
    }

    func testMinEqualsMaxIsAllMandatoryNoTail() throws {
        let g = try XCTUnwrap(VaultLocalLLMEngine.namesWithConfidenceGrammar(
            allowed: ["A", "B"], allowDecline: true, maximumTags: 3, minimumTags: 3, format: .json))
        XCTAssertTrue(g.contains("root ::= obj osep obj osep obj"))
        XCTAssertFalse(g.contains("tail0"))
    }

    // MARK: - Prompt

    func testTagCountInstruction() {
        let f = ClassificationPromptAssembler.tagCountInstruction
        XCTAssertEqual(f(0, 1), "Assign at most 1 tag.")
        // Bare-name replies ask for extra tags sparingly (unless two or more are required).
        let sparing = " Most videos need only one tag; add another only when the video is clearly also about that topic."
        XCTAssertEqual(f(0, 3), "Assign at most 3 tags." + sparing)
        XCTAssertEqual(f(1, 1), "Assign exactly 1 tag.")
        XCTAssertEqual(f(1, 3), "Assign at least 1 and at most 3 tags." + sparing)
        XCTAssertEqual(f(2, 5), "Assign at least 2 and at most 5 tags.")
    }

    func testPromptDropsDeclineLineWhenMinPositive() {
        let taxonomy = ClassificationPromptAssembler.tagOptions(from: TagTreeAsset(id: "t", name: "T", nodes: [.init(id: "a", name: "A")]))
        let canDecline = ClassificationPromptAssembler.staticPrefix(taxonomy: taxonomy, houseRules: nil, maximumTags: 1, minimumTags: 0)
        XCTAssertTrue(canDecline.contains("Use none only"))
        let mustTag = ClassificationPromptAssembler.staticPrefix(taxonomy: taxonomy, houseRules: nil, maximumTags: 1, minimumTags: 1)
        XCTAssertFalse(mustTag.contains("Use none"))
        XCTAssertTrue(mustTag.contains("never decline"))
    }

    // MARK: - Settings clamping

    func testBroadestPositionForbidsDeclining() {
        XCTAssertEqual(LocalLLMSettings(strictness: .broadest).minimumTags, 1)
        XCTAssertEqual(LocalLLMSettings(strictness: .broadest).maximumTags, 3)
        XCTAssertEqual(LocalLLMSettings().minimumTags, 0)          // default: may decline
    }

    func testPreDialMinimumTagsStateDecodesToTheBroadestPosition() throws {
        // State written while min/max/expected tags were settings must still load.
        let stored = #"{"maximumTags":3,"minimumTags":1,"expectedTags":2}"#
        let decoded = try JSONDecoder().decode(LocalLLMSettings.self, from: Data(stored.utf8))
        XCTAssertEqual(decoded.strictness, .broadest)
        XCTAssertEqual(decoded.maximumTags, 3); XCTAssertEqual(decoded.minimumTags, 1)
        let overrides = try JSONDecoder().decode(LocalModelOverrides.self, from: Data(#"{"minimumTags":1,"expectedTags":2}"#.utf8))
        XCTAssertEqual(overrides.strictness, .broadest)
    }

    func testPerTypeBoundsInheritAndOverride() {
        let global = LocalLLMSettings(strictness: .broadest)
        let inherit = LocalModelOverrides().effectiveTagBounds(global: global)
        XCTAssertEqual(inherit.minimum, 1); XCTAssertEqual(inherit.maximum, 3)
        let override = LocalModelOverrides(strictness: .strictest).effectiveTagBounds(global: global)
        XCTAssertEqual(override.minimum, 0); XCTAssertEqual(override.maximum, 1)
    }
}
