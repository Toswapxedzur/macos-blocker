import XCTest
@testable import VaultClassifierLLM

/// LATENCY-REFINEMENT Phase 2: the decode never SAMPLES what the grammar forces.
/// These pin exactly which spans count as forced (fed in one step) and when the
/// reply is already complete (no round spent sampling end-of-text) — and, just as
/// important, that every real choice is left to the model.
final class ForcedContinuationTests: XCTestCase {
    private let allowed = ["Music", "Gaming", "Gaming News", "Clash Royale"]
    private func next(_ text: String, cap: Int = 1, decline: Bool = true) -> (forced: String, finished: Bool) {
        VaultLocalLLMEngine.forcedContinuation(after: text, allowedTagNames: allowed, allowDecline: decline, maximumTags: cap, format: .json)
    }

    func testCompleteUnambiguousNameForcesTheConfidenceBoilerplate() {
        XCTAssertEqual(next("Music").forced, #"","confidence":"#)
        XCTAssertEqual(next("Clash Royale").forced, #"","confidence":"#)
        XCTAssertFalse(next("Music").finished)
    }

    func testAmbiguousPrefixesAreLeftToTheModel() {
        XCTAssertEqual(next("").forced, "")                    // the name decision itself is always sampled
        XCTAssertEqual(next("G").forced, "")                   // "Gaming" or "Gaming News"
        XCTAssertEqual(next("Gaming").forced, "")              // could still become "Gaming News"
        XCTAssertEqual(next("Gaming News").forced, #"","confidence":"#)
    }

    /// Once a partial name can only become ONE allowed name, the grammar leaves no
    /// choice about the rest: it is fed with its boilerplate in the same step
    /// instead of costing a generation round per remaining name token.
    func testAPartialNameWithOneCompletionIsCompleted() {
        XCTAssertEqual(next("Mus").forced, #"ic","confidence":"#)
        XCTAssertEqual(next("Clash").forced, #" Royale","confidence":"#)
        XCTAssertEqual(next("Gaming N").forced, #"ews","confidence":"#)
        // Second tag of a reply: only the current chunk decides.
        XCTAssertEqual(next(#"Music","confidence":4},{"name":"Cl"#, cap: 3).forced, #"ash Royale","confidence":"#)
    }

    func testAPrefixSharedWithTheDeclineLiteralIsNotCompleted() {
        let decline = VaultLocalLLMEngine.declineLiteral
        let sharing = [decline + "sense"]                      // a tag name that starts like the decline literal
        let first = String(decline.prefix(1))
        let open = VaultLocalLLMEngine.forcedContinuation(after: first, allowedTagNames: sharing, allowDecline: true, maximumTags: 1, format: .json)
        XCTAssertEqual(open.forced, "", "could still be the decline literal")
        let closed = VaultLocalLLMEngine.forcedContinuation(after: first, allowedTagNames: sharing, allowDecline: false, maximumTags: 1, format: .json)
        XCTAssertEqual(closed.forced, String(sharing[0].dropFirst()) + #"","confidence":"#)
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
            after: "none", allowedTagNames: ["nonesuch", "Music"], allowDecline: true, maximumTags: 1, format: .json)
        XCTAssertFalse(shadowed.finished)
    }

    func testQuotedTagNamesDisableForcing() {
        let result = VaultLocalLLMEngine.forcedContinuation(
            after: "Music", allowedTagNames: ["Music", #"Say "hi""#], allowDecline: true, maximumTags: 1, format: .json)
        XCTAssertEqual(result.forced, "")
        XCTAssertFalse(result.finished)
    }
}
