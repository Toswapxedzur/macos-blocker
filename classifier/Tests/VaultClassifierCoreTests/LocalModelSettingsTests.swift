import XCTest
@testable import VaultClassifierCore

/// The two dials (2026-09-23) and what old state decodes to.
final class LocalModelSettingsTests: XCTestCase {
    func testOptionalTagBoundsFollowEachDialDefaultIndependently() throws {
        for dial in StrictnessDial.allCases {
            let defaults = LocalLLMSettings(strictness: dial)
            XCTAssertEqual(defaults.tagBounds, dial.tagBounds)
            let maximumOnly = LocalLLMSettings(strictness: dial, maximumTagsOverride: 2)
            XCTAssertEqual(maximumOnly.minimumTags, dial.minimumTags)
            XCTAssertEqual(maximumOnly.maximumTags, 2)
            let minimumOnly = LocalLLMSettings(strictness: dial, minimumTagsOverride: 0)
            XCTAssertEqual(minimumOnly.minimumTags, 0)
            XCTAssertEqual(minimumOnly.maximumTags, dial.maximumTags)
        }
        let custom = LocalLLMSettings(strictness: .strict, minimumTagsOverride: 2, maximumTagsOverride: 2)
        XCTAssertEqual(custom.tagBounds, TagBounds(minimum: 2, maximum: 2))
        XCTAssertEqual(custom.extraTagMinimumOdds, StrictnessDial.strict.extraTagMinimumOdds)
        XCTAssertEqual(try JSONDecoder().decode(LocalLLMSettings.self, from: JSONEncoder().encode(custom)), custom)
        let blank = try JSONDecoder().decode(LocalLLMSettings.self, from: Data(#"{"strictness":5,"minimumTagsOverride":null,"maximumTagsOverride":null}"#.utf8))
        XCTAssertEqual(blank.tagBounds, StrictnessDial.broadest.tagBounds)
        for json in [#"{"strictness":3,"minimumTagsOverride":-1,"maximumTagsOverride":0}"#,
                     #"{"strictness":3,"minimumTagsOverride":3,"maximumTagsOverride":1}"#,
                     #"{"strictness":3,"minimumTagsOverride":"bad","maximumTagsOverride":99}"#] {
            let guarded = try JSONDecoder().decode(LocalLLMSettings.self, from: Data(json.utf8))
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

    func testSpeedQualityTiersNameOneCatalogModelEach() {
        XCTAssertEqual(SpeedQualityDial.default, .balanced)
        XCTAssertEqual(SpeedQualityDial.fast.ggufFileName, "Qwen2.5-3B-Instruct-Q4_K_M.gguf")
        XCTAssertEqual(SpeedQualityDial.balanced.ggufFileName, "Qwen2.5-7B-Instruct-Q4_K_M.gguf")
        XCTAssertEqual(SpeedQualityDial.best.ggufFileName, "Qwen2.5-14B-Instruct-Q4_K_M.gguf")
        XCTAssertNil(SpeedQualityDial.resolve("turbo")); XCTAssertNil(SpeedQualityDial.resolve(" "))
    }

    func testNearestPositionsForPreDialValues() {
        XCTAssertNil(StrictnessDial.nearest(maximumTags: nil, minimumTags: nil, extraTagMinimumOdds: nil))
        XCTAssertEqual(StrictnessDial.nearest(maximumTags: 1, minimumTags: 0, extraTagMinimumOdds: 0.9), .strictest)
        XCTAssertEqual(StrictnessDial.nearest(maximumTags: 3, minimumTags: 1, extraTagMinimumOdds: 0.85), .broadest)
        XCTAssertEqual(StrictnessDial.nearest(maximumTags: 3, minimumTags: 0, extraTagMinimumOdds: 0.97), .strict)
        XCTAssertEqual(StrictnessDial.nearest(maximumTags: 3, minimumTags: 0, extraTagMinimumOdds: 0.90), .balanced)
        XCTAssertEqual(StrictnessDial.nearest(maximumTags: 5, minimumTags: nil, extraTagMinimumOdds: 0.80), .broad)
        XCTAssertEqual(StrictnessDial.nearest(maximumTags: 3, minimumTags: nil, extraTagMinimumOdds: nil), .balanced)

        XCTAssertNil(SpeedQualityDial.nearest(modelFileName: nil)); XCTAssertNil(SpeedQualityDial.nearest(modelFileName: ""))
        XCTAssertEqual(SpeedQualityDial.nearest(modelFileName: "Qwen2.5-7B-Instruct-Q4_K_M.gguf"), .balanced)
        XCTAssertEqual(SpeedQualityDial.nearest(modelFileName: "Llama-3.2-3B-Instruct-Q4_K_M.gguf"), .fast)
        XCTAssertEqual(SpeedQualityDial.nearest(modelFileName: "Qwen2.5-14B-Instruct-Q4_K_M.gguf"), .best)
        XCTAssertEqual(SpeedQualityDial.nearest(modelFileName: "Mistral-7B-Instruct-v0.3-Q4_K_M.gguf"), .balanced)
        XCTAssertNil(SpeedQualityDial.nearest(modelFileName: "mystery.gguf"))
    }

    // MARK: - LocalLLMSettings

    func testSettingsDeriveEverythingFromTheDials() {
        let settings = LocalLLMSettings(speedQuality: .best, strictness: .strict, houseRules: String(repeating: "x", count: 4_100))
        XCTAssertEqual(settings.modelFileName, "Qwen2.5-14B-Instruct-Q4_K_M.gguf")
        XCTAssertEqual(settings.maximumTags, 3); XCTAssertEqual(settings.minimumTags, 0)
        XCTAssertEqual(settings.extraTagMinimumOdds, 0.97)
        XCTAssertEqual(settings.houseRules.count, 4_000)
        // Runtime constants.
        XCTAssertEqual(settings.contextTokens, 4_096); XCTAssertEqual(settings.batchTokens, 512)
        XCTAssertTrue(settings.gpuOffload); XCTAssertEqual(settings.maximumOutputTokens, 16)
        XCTAssertEqual(settings.temperature, 0); XCTAssertTrue(settings.allowDecline)
        XCTAssertEqual(settings.confidenceThresholds, [0.20, 0.40, 0.60, 0.85])
        XCTAssertEqual(settings.maxResidentModels, 2)
        XCTAssertEqual(LocalLLMSettings(), LocalLLMSettings(speedQuality: .balanced, strictness: .balanced, houseRules: ""))
    }

    func testPreDialSettingsDecodeToTheNearestPositionsAndNeverReencodeOldKeys() throws {
        let legacy = Data(#"{"modelFileName":"Qwen2.5-7B-Instruct-Q4_K_M.gguf","engineEnabled":true,"contextTokens":4096,"maximumTags":3,"minimumTags":0,"extraTagMinimumOdds":0.97,"allowDecline":true,"confidenceThresholds":[0.2,0.4,0.6,0.85],"houseRules":"rule","maxResidentModels":2}"#.utf8)
        let decoded = try JSONDecoder().decode(LocalLLMSettings.self, from: legacy)
        XCTAssertEqual(decoded, LocalLLMSettings(speedQuality: .balanced, strictness: .strict, houseRules: "rule"))
        let reencoded = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)
        for retired in ["modelFileName", "engineEnabled", "contextTokens", "maximumTags", "minimumTags", "extraTagMinimumOdds", "allowDecline", "confidenceThresholds", "maxResidentModels"] {
            XCTAssertFalse(reencoded.contains(retired), "retired key written back: \(retired)")
        }
        XCTAssertEqual(try JSONDecoder().decode(LocalLLMSettings.self, from: Data(reencoded.utf8)), decoded)
        // An empty pre-dial state lands on the defaults.
        XCTAssertEqual(try JSONDecoder().decode(LocalLLMSettings.self, from: Data("{}".utf8)), LocalLLMSettings())
        // A stored dial wins over leftover pre-dial keys.
        let mixed = try JSONDecoder().decode(LocalLLMSettings.self, from: Data(#"{"strictness":4,"maximumTags":1}"#.utf8))
        XCTAssertEqual(mixed.strictness, .broad)
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
