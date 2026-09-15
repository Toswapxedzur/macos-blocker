import XCTest
@testable import VaultClassifierLLM

/// Structural checks for the multi-tag GBNF builder (`namesGrammar`). The full
/// decode is exercised against a real model by the eval harness; here we pin the
/// grammar shape that makes up-to-N tags (and backward-compatible single-tag)
/// decoding possible, deterministically and without a model.
final class NamesGrammarTests: XCTestCase {
    private let sepRule = #"sep ::= "\"},{\"name\":\"""#

    func testSingleTagBoundIsBackwardCompatible() throws {
        let g = try XCTUnwrap(VaultLocalLLMEngine.namesGrammar(allowed: ["Gaming", "Music"], allowDecline: true, maximumTags: 1))
        XCTAssertTrue(g.contains(#"root ::= "none" | name"#))
        // No repetition tails when only one tag is allowed.
        XCTAssertFalse(g.contains("tail0"))
        XCTAssertTrue(g.contains(sepRule))
        XCTAssertTrue(g.contains(#"name ::= "Gaming" | "Music""#))
    }

    func testDeclineDisabledOmitsNoneAlternative() throws {
        let g = try XCTUnwrap(VaultLocalLLMEngine.namesGrammar(allowed: ["Gaming"], allowDecline: false, maximumTags: 1))
        XCTAssertTrue(g.contains("root ::= name"))
        XCTAssertFalse(g.contains(#""none""#))
    }

    func testMultiTagBuildsBoundedOptionalChain() throws {
        let g = try XCTUnwrap(VaultLocalLLMEngine.namesGrammar(allowed: ["A", "B", "C"], allowDecline: true, maximumTags: 3))
        XCTAssertTrue(g.contains(#"root ::= "none" | name tail0"#))
        // Two optional "sep name" steps for a bound of 3 (1 mandatory + 2 extra).
        XCTAssertTrue(g.contains(#"tail0 ::= "" | sep name tail1"#))
        XCTAssertTrue(g.contains(#"tail1 ::= "" | sep name"#))
        // The chain terminates: no tail2 for a bound of 3.
        XCTAssertFalse(g.contains("tail2"))
        XCTAssertTrue(g.contains(sepRule))
    }

    func testSeparatorIsTheJSONObjectBoilerplate() throws {
        // The GBNF `sep` literal must decode to the exact string that the engine
        // splits the generated output on: `"},{"name":"`. If these ever diverge,
        // multi-tag parsing silently returns one merged (invalid) name.
        let g = try XCTUnwrap(VaultLocalLLMEngine.namesGrammar(allowed: ["A"], maximumTags: 2))
        XCTAssertTrue(g.contains(sepRule), "sep rule must be the {\"name\":\"} boilerplate")
    }

    func testBoundIsClampedToAtLeastOne() throws {
        let g = try XCTUnwrap(VaultLocalLLMEngine.namesGrammar(allowed: ["A"], allowDecline: false, maximumTags: 0))
        XCTAssertTrue(g.contains("root ::= name"))
        XCTAssertFalse(g.contains("tail0"))
    }

    func testUnusableNamesAreSkippedAndEmptyReturnsNil() {
        // A name with an embedded newline can't be a GBNF literal → skipped.
        let mixed = VaultLocalLLMEngine.namesGrammar(allowed: ["Good", "Bad\nName"], allowDecline: false, maximumTags: 2)
        XCTAssertEqual(mixed?.contains(#""Good""#), true)
        XCTAssertEqual(mixed?.contains("Bad"), false)
        // No usable names at all → nil.
        XCTAssertNil(VaultLocalLLMEngine.namesGrammar(allowed: ["\n", ""], maximumTags: 2))
        XCTAssertNil(VaultLocalLLMEngine.namesGrammar(allowed: [], maximumTags: 2))
    }

    func testDeclineLiteralAlreadyInTaxonomyIsNotDoubled() throws {
        let g = try XCTUnwrap(VaultLocalLLMEngine.namesGrammar(allowed: ["none", "Gaming"], allowDecline: true, maximumTags: 1))
        // "none" is a real tag here, so root must not prepend a second "none" |.
        XCTAssertFalse(g.contains(#"root ::= "none" |"#))
        XCTAssertTrue(g.contains(#"name ::= "none" | "Gaming""#))
    }
}
