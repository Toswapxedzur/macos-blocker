import XCTest
@testable import VaultClassifierCore

/// Shared cloud tagging controls and bounded state decoding.
final class TaggingSettingsTests: XCTestCase {
    func testOptionalTagBoundsFollowEachDialDefaultIndependently() throws {
        for dial in StrictnessDial.allCases {
            let defaults = TaggingSettings(strictness: dial)
            XCTAssertEqual(defaults.tagBounds, dial.tagBounds)
            let maximumOnly = TaggingSettings(strictness: dial, maximumTagsOverride: 2)
            XCTAssertEqual(maximumOnly.minimumTags, dial.minimumTags)
            XCTAssertEqual(maximumOnly.maximumTags, 2)
            let minimumOnly = TaggingSettings(strictness: dial, minimumTagsOverride: 0)
            XCTAssertEqual(minimumOnly.minimumTags, 0)
            XCTAssertEqual(minimumOnly.maximumTags, dial.maximumTags)
        }
        let custom = TaggingSettings(strictness: .strict, minimumTagsOverride: 2, maximumTagsOverride: 2)
        XCTAssertEqual(custom.tagBounds, TagBounds(minimum: 2, maximum: 2))
        XCTAssertEqual(custom.extraTagMinimumOdds, StrictnessDial.strict.extraTagMinimumOdds)
        XCTAssertEqual(try JSONDecoder().decode(TaggingSettings.self, from: JSONEncoder().encode(custom)), custom)
        let blank = try JSONDecoder().decode(TaggingSettings.self, from: Data(#"{"strictness":5,"minimumTagsOverride":null,"maximumTagsOverride":null}"#.utf8))
        XCTAssertEqual(blank.tagBounds, StrictnessDial.broadest.tagBounds)
        for json in [#"{"strictness":3,"minimumTagsOverride":-1,"maximumTagsOverride":0}"#,
                     #"{"strictness":3,"minimumTagsOverride":3,"maximumTagsOverride":1}"#,
                     #"{"strictness":3,"minimumTagsOverride":"bad","maximumTagsOverride":99}"#] {
            let guarded = try JSONDecoder().decode(TaggingSettings.self, from: Data(json.utf8))
            XCTAssertEqual(guarded.tagBounds, StrictnessDial.balanced.tagBounds)
        }
    }
    // MARK: - Dials

    func testStrictnessPositionsMapToTagBoundsAndSureness() {
        XCTAssertEqual(StrictnessDial.default, .balanced)
        XCTAssertEqual(StrictnessDial.allCases.map(\.rawValue), [1, 2, 3, 4, 5])
        XCTAssertEqual(StrictnessDial.allCases.map(\.maximumTags), [1, 3, 3, 3, 3])
        XCTAssertEqual(StrictnessDial.allCases.map(\.minimumTags), [0, 0, 0, 0, 1])
        XCTAssertEqual(StrictnessDial.allCases.map(\.extraTagMinimumOdds), [0.90, 0.97, 0.90, 0.85, 0.85])
        XCTAssertEqual(StrictnessDial.broadest.tagBounds, TagBounds(minimum: 1, maximum: 3))
        XCTAssertNil(StrictnessDial.resolve(0)); XCTAssertNil(StrictnessDial.resolve(6)); XCTAssertNil(StrictnessDial.resolve(nil))
    }


    func testNearestPositionsForPreDialValues() {
        XCTAssertNil(StrictnessDial.nearest(maximumTags: nil, minimumTags: nil, extraTagMinimumOdds: nil))
        XCTAssertEqual(StrictnessDial.nearest(maximumTags: 1, minimumTags: 0, extraTagMinimumOdds: 0.9), .strictest)
        XCTAssertEqual(StrictnessDial.nearest(maximumTags: 3, minimumTags: 1, extraTagMinimumOdds: 0.85), .broadest)
        XCTAssertEqual(StrictnessDial.nearest(maximumTags: 3, minimumTags: 0, extraTagMinimumOdds: 0.97), .strict)
        XCTAssertEqual(StrictnessDial.nearest(maximumTags: 3, minimumTags: 0, extraTagMinimumOdds: 0.90), .balanced)
        XCTAssertEqual(StrictnessDial.nearest(maximumTags: 5, minimumTags: nil, extraTagMinimumOdds: 0.80), .broad)
        XCTAssertEqual(StrictnessDial.nearest(maximumTags: 3, minimumTags: nil, extraTagMinimumOdds: nil), .balanced)

    }

    // MARK: - TaggingSettings



    // MARK: - ResearchSettings


    /// Budgets, cooldown, the creator trigger and the knowledge limits are constants
    /// now; every key they once had decodes silently and never re-encodes.


}
