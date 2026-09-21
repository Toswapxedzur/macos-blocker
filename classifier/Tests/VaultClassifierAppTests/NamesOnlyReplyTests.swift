import XCTest
@testable import VaultClassifierCore
@testable import VaultClassifierLLM

/// The PRODUCTION reply (2026-09-21): bare tag names — `Tags:` then ` Music, Sports`
/// and a newline — with no scaffold and no confidence digit. These pin what the
/// grammar allows, what is fed without sampling, and how confidence is derived.
final class NamesOnlyReplyTests: XCTestCase {
    private let allowed = ["Music", "Gaming", "Gaming News", "Clash Royale"]
    private func next(_ text: String, cap: Int = 3, decline: Bool = true) -> (forced: String, finished: Bool) {
        VaultLocalLLMEngine.forcedContinuation(
            after: text, allowedTagNames: allowed, allowDecline: decline, maximumTags: cap, format: .names)
    }

    func testProductionFormatIsBareNames() {
        XCTAssertEqual(ClassificationReplyFormat.names.runway, "Tags:")
        XCTAssertFalse(ClassificationReplyFormat.names.runway.hasSuffix(" "),
                       "a runway ending in a space forces unnatural tokens — the name carries the space")
        XCTAssertEqual(ClassificationReplyFormat.names.nameLead, " ")
        XCTAssertFalse(ClassificationReplyFormat.names.emitsConfidence)
    }

    /// The model's natural "done" on a bare line is a NEWLINE. Without it in the
    /// grammar its stop is rejected and the separator is the only legal move, so it
    /// is forced to keep adding tags (measured: continue odds 1.000 on 782 of 782).
    func testGrammarLetsTheReplyEndWithANewline() throws {
        let g = try XCTUnwrap(VaultLocalLLMEngine.namesWithConfidenceGrammar(
            allowed: ["Gaming", "Music"], allowDecline: true, maximumTags: 3, format: .names))
        XCTAssertTrue(g.contains("root ::= core lineend"))
        XCTAssertTrue(g.contains(#"lineend ::= "" | "\n""#))
        XCTAssertTrue(g.contains(#"core ::= " none" | obj tail0"#))
        XCTAssertTrue(g.contains(#"obj ::= " " name"#))
        XCTAssertTrue(g.contains(#"osep ::= ",""#))
        XCTAssertFalse(g.contains("conf"), "no confidence digit is ever generated")
    }

    func testOnlyRealChoicesAreSampled() {
        XCTAssertEqual(next("").forced, "")                          // the first name is the decision
        XCTAssertEqual(next(" Mus").forced, "ic")                    // one completion left → fed
        XCTAssertEqual(next(" Gaming").forced, "")                   // could still become "Gaming News"
        XCTAssertEqual(next(" Music").forced, "")                    // stop or add another: the model's call
        XCTAssertFalse(next(" Music").finished)
        XCTAssertTrue(next(" Music", cap: 1).finished)               // at the cap nothing can follow
        XCTAssertEqual(next(" Music, Cl").forced, "ash Royale")
        XCTAssertTrue(next(" Music, Gaming News, Clash Royale").finished)
        XCTAssertTrue(next(" none").finished)
    }

    /// Confidence is read from the odds the engine recorded at each name start (for
    /// an extra tag: the odds of continuing × the odds of that name).
    func testConfidenceComesFromTheRecordedOdds() {
        let parsed = VaultLocalLLMEngine.parseStructuredOutput(
            " Music, Gaming News", nameStartProbabilities: [0.97, 0.91],
            allowedTagNames: allowed, thresholds: [0.20, 0.40, 0.60, 0.85], format: .names)
        XCTAssertEqual(parsed.tags.map(\.name), ["Music", "Gaming News"])
        XCTAssertEqual(parsed.tags.map(\.modelConfidence), [5, 5])
        XCTAssertFalse(parsed.declined)
        let weak = VaultLocalLLMEngine.parseStructuredOutput(
            " Music", nameStartProbabilities: [0.45], allowedTagNames: allowed,
            thresholds: [0.20, 0.40, 0.60, 0.85], format: .names)
        XCTAssertEqual(weak.tags.map(\.modelConfidence), [3])
        XCTAssertTrue(VaultLocalLLMEngine.parseStructuredOutput(
            " none", nameStartProbabilities: [0.8], allowedTagNames: allowed,
            thresholds: [0.20, 0.40, 0.60, 0.85], format: .names).declined)
    }

    /// The precision knob: default 0.90, clamped, and old states decode to the default.
    func testExtraTagSurenessSetting() throws {
        XCTAssertEqual(LocalLLMSettings().extraTagMinimumOdds, 0.90)
        XCTAssertEqual(LocalLLMSettings(extraTagMinimumOdds: 7).extraTagMinimumOdds, 0.999)
        XCTAssertEqual(LocalLLMSettings(extraTagMinimumOdds: -1).extraTagMinimumOdds, 0)
        let old = try JSONDecoder().decode(LocalLLMSettings.self, from: Data(#"{"maximumTags":3}"#.utf8))
        XCTAssertEqual(old.extraTagMinimumOdds, 0.90)
        XCTAssertEqual(try JSONDecoder().decode(LocalLLMSettings.self, from: JSONEncoder().encode(LocalLLMSettings(extraTagMinimumOdds: 0.8))).extraTagMinimumOdds, 0.8)
    }

    /// No digit is asked for, so the prompt must not describe one.
    func testPromptDoesNotAskForAConfidence() {
        let prefix = ClassificationPromptAssembler.staticPrefix(
            taxonomy: [LLMTagOption(id: "m", name: "Music")], houseRules: nil, maximumTags: 3)
        XCTAssertEqual(ClassificationReplyFormat.current.id, "names")
        XCTAssertFalse(prefix.lowercased().contains("confidence"))
        XCTAssertTrue(prefix.contains("tag names only"))
        // Free (cached prefix) and measured to lower needless declines.
        XCTAssertTrue(prefix.contains("Most videos need only one tag"))
    }
}
