import XCTest
@testable import VaultClassifierLLM

/// Structural checks for the PRODUCTION Decode-1 grammar
/// (`namesWithConfidenceGrammar`, RESEARCH-REDESIGN Phase 2), which lets the
/// model emit its own `,"confidence":N` per tag. The digit/boilerplate literals
/// and the inter-object separator must match exactly what `structuredDecode`
/// splits on, or model confidence is silently lost.
final class NamesWithConfidenceGrammarTests: XCTestCase {
    private let confRule = #"conf ::= "\",\"confidence\":" digit"#
    private let digitRule = #"digit ::= "1" | "2" | "3" | "4" | "5""#
    private let osepRule = #"osep ::= "},{\"name\":\"""#

    func testSingleTagObjectShape() throws {
        let g = try XCTUnwrap(VaultLocalLLMEngine.namesWithConfidenceGrammar(allowed: ["Gaming", "Music"], allowDecline: true, maximumTags: 1, format: .json))
        XCTAssertTrue(g.contains(#"root ::= "none" | obj"#))
        XCTAssertFalse(g.contains("tail0"))          // no chain for a single tag
        XCTAssertTrue(g.contains("obj ::= name conf"))
        XCTAssertTrue(g.contains(confRule))
        XCTAssertTrue(g.contains(digitRule))
        XCTAssertTrue(g.contains(#"name ::= "Gaming" | "Music""#))
    }

    func testMultiTagBuildsBoundedObjectChain() throws {
        let g = try XCTUnwrap(VaultLocalLLMEngine.namesWithConfidenceGrammar(allowed: ["A", "B", "C"], allowDecline: true, maximumTags: 3, format: .json))
        XCTAssertTrue(g.contains(#"root ::= "none" | obj tail0"#))
        XCTAssertTrue(g.contains(#"tail0 ::= "" | osep obj tail1"#))
        XCTAssertTrue(g.contains(#"tail1 ::= "" | osep obj"#))
        XCTAssertFalse(g.contains("tail2"))          // chain terminates at bound 3
        XCTAssertTrue(g.contains(osepRule))
    }

    func testSeparatorMatchesTheParserSplit() throws {
        // osep must decode to `},{"name":"` — the exact string structuredDecode
        // splits object continuations on. Divergence merges tags into one.
        let g = try XCTUnwrap(VaultLocalLLMEngine.namesWithConfidenceGrammar(allowed: ["A"], maximumTags: 2, format: .json))
        XCTAssertTrue(g.contains(osepRule))
    }

    func testDeclineDisabledOmitsNoneAlternative() throws {
        let g = try XCTUnwrap(VaultLocalLLMEngine.namesWithConfidenceGrammar(allowed: ["Gaming"], allowDecline: false, maximumTags: 1, format: .json))
        XCTAssertTrue(g.contains("root ::= obj"))
        XCTAssertFalse(g.contains(#""none""#))
    }

    func testUnusableNamesAreSkippedAndEmptyReturnsNil() {
        let mixed = VaultLocalLLMEngine.namesWithConfidenceGrammar(allowed: ["Good", "Bad\nName"], allowDecline: false, maximumTags: 2, format: .json)
        XCTAssertEqual(mixed?.contains(#""Good""#), true)
        XCTAssertEqual(mixed?.contains("Bad"), false)
        XCTAssertNil(VaultLocalLLMEngine.namesWithConfidenceGrammar(allowed: ["\n", ""], maximumTags: 2, format: .json))
        XCTAssertNil(VaultLocalLLMEngine.namesWithConfidenceGrammar(allowed: [], maximumTags: 2, format: .json))
    }
}
