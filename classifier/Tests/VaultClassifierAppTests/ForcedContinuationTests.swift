import XCTest
@testable import VaultClassifierLLM

/// LATENCY-REFINEMENT Phase 2: the decode never SAMPLES what the grammar forces.
/// These pin exactly which spans count as forced (fed in one step) and when the
/// reply is already complete (no round spent sampling end-of-text) — and, just as
/// important, that every real choice is left to the model.
final class ForcedContinuationTests: XCTestCase {
    private let allowed = ["Music", "Gaming", "Gaming News", "Clash Royale"]
    private func next(_ text: String, cap: Int = 1, decline: Bool = true) -> (forced: String, finished: Bool) {
        VaultLocalLLMEngine.forcedContinuation(after: text, allowedTagNames: allowed, allowDecline: decline, maximumTags: cap)
    }

    func testCompleteUnambiguousNameForcesTheConfidenceBoilerplate() {
        XCTAssertEqual(next("Music").forced, #"","confidence":"#)
        XCTAssertEqual(next("Clash Royale").forced, #"","confidence":"#)
        XCTAssertFalse(next("Music").finished)
    }

    func testPartialNamesAndAmbiguousPrefixesAreLeftToTheModel() {
        XCTAssertEqual(next("Mus").forced, "")                 // still choosing the name
        XCTAssertEqual(next("Clash").forced, "")
        XCTAssertEqual(next("Gaming").forced, "")              // could still become "Gaming News"
        XCTAssertEqual(next("Gaming News").forced, #"","confidence":"#)
    }

    func testPartiallyEmittedBoilerplateIsCompleted() {
        // The model resolved "Gaming" vs "Gaming News" itself by emitting `","`.
        XCTAssertEqual(next(#"Gaming",""#).forced, #"confidence":"#)
        XCTAssertEqual(next(#"Music","confidence"#).forced, #"":"#)
    }

    func testTheDigitIsAlwaysARealChoice() {
        let beforeDigit = next(#"Music","confidence":"#)
        XCTAssertEqual(beforeDigit.forced, "")
        XCTAssertFalse(beforeDigit.finished)
    }

    func testAtTheCapTheReplyIsFinishedRightAfterTheDigit() {
        XCTAssertTrue(next(#"Music","confidence":4"#, cap: 1).finished)
        // Below the cap the model still chooses "another tag" vs stop.
        let belowCap = next(#"Music","confidence":4"#, cap: 3)
        XCTAssertFalse(belowCap.finished)
        XCTAssertEqual(belowCap.forced, "")
        // Once it starts the separator, the rest of it is forced.
        XCTAssertEqual(next(#"Music","confidence":4}"#, cap: 3).forced, #",{"name":""#)
        // …and the second item finishes at cap 2.
        XCTAssertTrue(next(#"Music","confidence":4},{"name":"Gaming News","confidence":2"#, cap: 2).finished)
    }

    func testDeclineFinishesImmediatelyUnlessATagCouldStartWithIt() {
        XCTAssertTrue(next("none").finished)
        XCTAssertFalse(next("none", decline: false).finished)
        let shadowed = VaultLocalLLMEngine.forcedContinuation(
            after: "none", allowedTagNames: ["nonesuch", "Music"], allowDecline: true, maximumTags: 1)
        XCTAssertFalse(shadowed.finished)
    }

    func testQuotedTagNamesDisableForcing() {
        let result = VaultLocalLLMEngine.forcedContinuation(
            after: "Music", allowedTagNames: ["Music", #"Say "hi""#], allowDecline: true, maximumTags: 1)
        XCTAssertEqual(result.forced, "")
        XCTAssertFalse(result.finished)
    }
}
