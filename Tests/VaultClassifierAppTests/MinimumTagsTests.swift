import XCTest
@testable import VaultClassifierCore
@testable import VaultClassifierLLM

/// minimumTags / expectedTags (owner request 2026-09-18): a min forces the model
/// to emit at least N best guesses instead of declining (recall over precision,
/// filtered at the policy floor); expected is a soft prompt target; max is the cap.
final class MinimumTagsTests: XCTestCase {

    // MARK: - Grammar (the hard bounds)

    func testMinZeroKeepsDeclineAndOneOptionalItem() throws {
        let g = try XCTUnwrap(VaultLocalLLMEngine.namesWithConfidenceGrammar(
            allowed: ["A", "B"], allowDecline: true, maximumTags: 1, minimumTags: 0))
        XCTAssertTrue(g.contains(#"root ::= "none" | obj"#))   // may decline
    }

    func testMinOneDropsDeclineAndForcesAnItem() throws {
        let g = try XCTUnwrap(VaultLocalLLMEngine.namesWithConfidenceGrammar(
            allowed: ["A", "B"], allowDecline: true, maximumTags: 1, minimumTags: 1))
        XCTAssertEqual(g.components(separatedBy: "\n").first, "root ::= obj")
        XCTAssertFalse(g.contains("none"), "min ≥ 1 must forbid declining")
    }

    func testMinTwoForcesTwoMandatoryItemsThenOptional() throws {
        // max 4, min 2 → obj + one mandatory `osep obj` + a 2-long optional chain.
        let g = try XCTUnwrap(VaultLocalLLMEngine.namesWithConfidenceGrammar(
            allowed: ["A", "B", "C", "D"], allowDecline: true, maximumTags: 4, minimumTags: 2))
        XCTAssertTrue(g.contains("root ::= obj osep obj tail0"))
        XCTAssertTrue(g.contains(#"tail0 ::= "" | osep obj tail1"#))
        XCTAssertTrue(g.contains(#"tail1 ::= "" | osep obj"#))
        XCTAssertFalse(g.contains("tail2"))
    }

    func testMinEqualsMaxIsAllMandatoryNoTail() throws {
        let g = try XCTUnwrap(VaultLocalLLMEngine.namesWithConfidenceGrammar(
            allowed: ["A", "B"], allowDecline: true, maximumTags: 3, minimumTags: 3))
        XCTAssertTrue(g.contains("root ::= obj osep obj osep obj"))
        XCTAssertFalse(g.contains("tail0"))
    }

    // MARK: - Prompt (the soft target)

    func testTagCountInstruction() {
        let f = ClassificationPromptAssembler.tagCountInstruction
        XCTAssertEqual(f(0, nil, 1), "Assign at most 1 tag.")
        XCTAssertEqual(f(0, nil, 3), "Assign at most 3 tags.")
        XCTAssertEqual(f(1, nil, 1), "Assign exactly 1 tag.")
        XCTAssertEqual(f(1, nil, 3), "Assign at least 1 and at most 3 tags.")
        XCTAssertEqual(f(1, 2, 3), "Assign at least 1 and at most 3 tags, aiming for about 2.")
        XCTAssertEqual(f(2, 3, 5), "Assign at least 2 and at most 5 tags, aiming for about 3.")
    }

    func testPromptDropsDeclineLineWhenMinPositive() {
        let taxonomy = ClassificationPromptAssembler.tagOptions(from: TagTreeAsset(id: "t", name: "T", nodes: [.init(id: "a", name: "A")]))
        let canDecline = ClassificationPromptAssembler.staticPrefix(taxonomy: taxonomy, houseRules: nil, maximumTags: 1, minimumTags: 0)
        XCTAssertTrue(canDecline.contains("Use none only"))
        let mustTag = ClassificationPromptAssembler.staticPrefix(taxonomy: taxonomy, houseRules: nil, maximumTags: 1, minimumTags: 1, expectedTags: 1)
        XCTAssertFalse(mustTag.contains("Use none"))
        XCTAssertTrue(mustTag.contains("never decline"))
    }

    // MARK: - Settings clamping

    func testSettingsClampMinExpectedIntoRange() {
        let s = LocalLLMSettings(maximumTags: 3, minimumTags: 9, expectedTags: 0)
        XCTAssertEqual(s.maximumTags, 3)
        XCTAssertEqual(s.minimumTags, 3)                 // clamped to max
        XCTAssertEqual(s.expectedTags, 3)                // clamped up to min (=3)
        let t = LocalLLMSettings(maximumTags: 5, minimumTags: 0, expectedTags: 9)
        XCTAssertEqual(t.expectedTags, 5)                // clamped down to max
        XCTAssertEqual(LocalLLMSettings().minimumTags, 0)          // default: may decline
        XCTAssertNil(LocalLLMSettings().expectedTags)
    }

    func testPerTypeBoundsInheritAndOverride() {
        let global = LocalLLMSettings(maximumTags: 4, minimumTags: 1, expectedTags: 2)
        let inherit = LocalModelOverrides().effectiveTagBounds(global: global)
        XCTAssertEqual(inherit.minimum, 1); XCTAssertEqual(inherit.expected, 2); XCTAssertEqual(inherit.maximum, 4)
        let override = LocalModelOverrides(maximumTags: 2, minimumTags: 0).effectiveTagBounds(global: global)
        XCTAssertEqual(override.minimum, 0); XCTAssertEqual(override.maximum, 2)
        XCTAssertEqual(override.expected, 2)             // inherited expected, clamped to the new max
    }
}
