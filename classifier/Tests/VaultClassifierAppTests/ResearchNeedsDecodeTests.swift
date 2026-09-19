import XCTest
@testable import VaultClassifierCore
@testable import VaultClassifierLLM

/// Decode 2 (RESEARCH-REDESIGN §5, revised): the model extracts TERMS ONLY;
/// urgency is derived from Decode-1 confidences (`ResearchUrgency`). Structural
/// checks on the terms-only GBNF, the term parser, and the urgency derivation —
/// the full decode runs against a real model via the app's `needs` eval mode.
final class ResearchNeedsDecodeTests: XCTestCase {

    // MARK: - Grammar shape

    func testSingleTermGrammarHasNoTailChain() {
        let g = VaultLocalLLMEngine.researchNeedsGrammar(maximumTerms: 1)
        XCTAssertTrue(g.contains(#"root ::= "]}" | termobj "]}""#))
        XCTAssertFalse(g.contains("tail0"))
        XCTAssertTrue(g.contains("termobj ::="))
        XCTAssertTrue(g.contains("term ::= termchar+"))
        // No urgency/author/digit rules remain — terms only.
        XCTAssertFalse(g.contains("urgency"))
        XCTAssertFalse(g.contains("author"))
        XCTAssertFalse(g.contains("digit"))
    }

    func testMultiTermBuildsBoundedTailChain() {
        let g = VaultLocalLLMEngine.researchNeedsGrammar(maximumTerms: 3)
        XCTAssertTrue(g.contains(#"root ::= "]}" | termobj tail0 "]}""#))
        XCTAssertTrue(g.contains(#"tail0 ::= "" | "," termobj tail1"#))
        XCTAssertTrue(g.contains(#"tail1 ::= "" | "," termobj"#))
        XCTAssertFalse(g.contains("tail2"))          // chain terminates at bound 3
    }

    func testBoundClampedToAtLeastOne() {
        let g = VaultLocalLLMEngine.researchNeedsGrammar(maximumTerms: 0)
        XCTAssertTrue(g.contains(#"root ::= "]}" | termobj "]}""#))
        XCTAssertFalse(g.contains("tail0"))
    }

    // MARK: - Term parser

    func testParsesQuotedTerms() {
        // Exactly what the model emits AFTER the `{"needs":[` runway.
        let generated = #""HermitCraft","Mumbo Jumbo"]}"#
        XCTAssertEqual(VaultLocalLLMEngine.parseResearchTerms(generated), ["HermitCraft", "Mumbo Jumbo"])
    }

    func testParsesEmptyList() {
        XCTAssertEqual(VaultLocalLLMEngine.parseResearchTerms("]}"), [])
    }

    func testParsesSingleTermAndDeduplicates() {
        XCTAssertEqual(VaultLocalLLMEngine.parseResearchTerms(#""Ludwig","Ludwig"]}"#), ["Ludwig"])
    }

    func testStripsStrayEdgePunctuationButKeepsHandlesAndInnerPunctuation() {
        // Seen live: a bracketed CJK title yielded `:皇室戰爭`.
        XCTAssertEqual(VaultLocalLLMEngine.parseResearchTerms(#"":皇室戰爭","【HermitCraft】","@ludwig","Spider-Man: No Way Home","::"]}"#),
                       ["皇室戰爭", "HermitCraft", "@ludwig", "Spider-Man: No Way Home"])
    }

    // MARK: - Derived urgency (the reframe)

    func testUrgencyIsInverseOfMeanConfidence() {
        XCTAssertEqual(ResearchUrgency.fromTagConfidences([5]), 1)   // certain → not urgent
        XCTAssertEqual(ResearchUrgency.fromTagConfidences([1]), 5)   // guess → urgent
        XCTAssertEqual(ResearchUrgency.fromTagConfidences([3]), 3)
        XCTAssertEqual(ResearchUrgency.fromTagConfidences([5, 3]), 2) // mean 4 → 6-4=2
    }

    func testDeclineIsMaximallyUrgent() {
        XCTAssertEqual(ResearchUrgency.fromTagConfidences([]), 5)     // no tags = couldn't place it
    }

    func testResearchNeedClampsUrgency() {
        XCTAssertEqual(ResearchNeed(term: "x", urgency: 9).urgency, 5)
        XCTAssertEqual(ResearchNeed(term: "x", urgency: 0).urgency, 1)
    }
}
