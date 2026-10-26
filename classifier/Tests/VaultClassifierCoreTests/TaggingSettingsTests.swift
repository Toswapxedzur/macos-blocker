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


    func testRetiredPackageUpdatePolicyIsIgnoredWithoutLosingActiveSettings() throws {
        let old = Data(#"{"packageUpdateMode":{"invalid":true},"classificationEnabled":false,"research":{"enabled":true},"dictionaries":{"creatorMode":"full","creatorCacheSize":27}}"#.utf8)
        let settings = try JSONDecoder().decode(ClassifierSettings.self, from: old)
        XCTAssertFalse(settings.classificationEnabled)
        XCTAssertTrue(settings.research.enabled)
        XCTAssertEqual(settings.dictionaries.creatorMode, .full)
        XCTAssertEqual(settings.dictionaries.creatorCacheSize, 27)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(settings), as: UTF8.self).contains("packageUpdateMode"))
    }

    // MARK: - ResearchSettings

    func testClassifierSettingsResearchDefaultsOffAndPersists() throws {
        let legacy = Data(#"{"packageUpdateMode":"automatic"}"#.utf8)
        let legacySettings = try JSONDecoder().decode(ClassifierSettings.self, from: legacy)
        XCTAssertFalse(legacySettings.research.enabled)

        let value = ClassifierSettings(research: .init(enabled: true, llmProviderProfileID: "llm", llmModelIdentifier: "model"))
        let data = try JSONEncoder().encode(value)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"research\""))
        XCTAssertEqual(try JSONDecoder().decode(ClassifierSettings.self, from: data), value)
    }

    /// Budgets, cooldown, the creator trigger and the knowledge limits are constants
    /// now; every key they once had decodes silently and never re-encodes.
    func testResearchConstantsAndRetiredKeys() throws {
        let old = #"{"enabled":true,"llmProviderProfileID":"llm","llmModelIdentifier":"m","requestsPerMinute":99,"dailyTokenLimit":5,"cooldownHours":1,"authorThreshold":{"score":9,"halfLifeDays":1},"knowledgeTTLDays":7,"maxKnowledgePerVideo":1,"trigger":"all","urgencyFloor":4}"#
        let decoded = try JSONDecoder().decode(ResearchSettings.self, from: Data(old.utf8))
        XCTAssertEqual(decoded, ResearchSettings(enabled: true, llmProviderProfileID: "llm", llmModelIdentifier: "m"))
        XCTAssertEqual(decoded.requestsPerMinute, 6); XCTAssertEqual(decoded.dailyTokenLimit, 10_000)
        XCTAssertEqual(decoded.cooldownHours, 24)
        XCTAssertEqual(decoded.authorThreshold, AuthorResearchThreshold(score: 3, halfLifeDays: 14))
        XCTAssertEqual(decoded.knowledgeTTLDays, 0); XCTAssertEqual(decoded.maxKnowledgePerVideo, 8)
        let reencoded = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)
        for retired in ["requestsPerMinute", "dailyTokenLimit", "cooldownHours", "authorThreshold", "knowledgeTTLDays", "maxKnowledgePerVideo", "\"trigger\"", "urgencyFloor"] {
            XCTAssertFalse(reencoded.contains(retired), "retired key written back: \(retired)")
        }
    }

    func testCreatorRuleClamps() {
        XCTAssertEqual(AuthorResearchThreshold().score, 3)
        XCTAssertEqual(AuthorResearchThreshold().halfLifeDays, 14)
        XCTAssertEqual(AuthorResearchThreshold(score: 0, halfLifeDays: 0), AuthorResearchThreshold(score: 0.5, halfLifeDays: 1))
        XCTAssertEqual(AuthorResearchThreshold(score: 999, halfLifeDays: 9_999), AuthorResearchThreshold(score: 50, halfLifeDays: 365))
    }
}
