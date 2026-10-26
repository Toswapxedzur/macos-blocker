import Foundation
import XCTest
@testable import VaultClassifierCore
@testable import VaultClassifierResearch

final class ReasoningSearchTests: XCTestCase {
    private var item: LLMClassificationRequest { .init(staticPrefix: "Tags: Games. " + ClassificationReplyFormat.current.rule, dynamicSuffix: "Games tutorial", allowedTagNames: ["Games"], maximumTags: 3) }
    func testProviderReasoningChoicesReachTheCorrectWireField() throws {
        for (provider, model) in [(APIKeyProviderType.openAI,"gpt-6.1-sol"),(.gemini,"gemini-3.1-flash-lite"),(.xAI,"grok-4.7")] {
            let profile = APIKeyProviderProfile(id: "p", type: provider)
            for effort in [ClassificationReasoningEffort.providerDefault,.low,.medium,.high] {
                let request = try APIKeyClassificationEngine.prepare([item], configuration: .init(profileID: "p", model: model, reasoningEffort: effort), profile: profile)
                let body = try JSONSerialization.jsonObject(with: request.body) as! [String: Any]
                XCTAssertNotNil(body["tools"])
                if provider == .gemini {
                    let generation = body["generationConfig"] as! [String: Any]
                    XCTAssertEqual((generation["thinkingConfig"] as? [String: String])?["thinkingLevel"], effort == .providerDefault ? nil : effort.rawValue)
                    XCTAssertNil(body["reasoning"])
                } else { XCTAssertEqual((body["reasoning"] as? [String: String])?["effort"], effort == .providerDefault ? nil : effort.rawValue) }
            }
        }
    }
    func testGeminiLargeBatchSchemaDoesNotExpandArrayBounds() throws {
        let requests = Array(repeating: item, count: 16)
        let request = try APIKeyClassificationEngine.prepare(requests, configuration: .init(profileID: "p", model: "gemini-3.1-flash-lite"), profile: .init(id: "p", type: .gemini))
        let text = String(decoding: request.body, as: UTF8.self)
        XCTAssertFalse(text.contains("maxItems")); XCTAssertFalse(text.contains("minItems"))
        // Looser provider grammar must never make the application accept a short batch.
        XCTAssertThrowsError(try ChatGPTClassificationEngine.parse(#"{"items":[{"index":0,"tags":[{"name":"Games","confidence":5}]}]}"#, requests: requests))
    }
    func testUnsupportedEffortAndSearchCombinationsFailBeforeDispatch() throws {
        XCTAssertThrowsError(try ClassificationModelPolicy.validate(provider: .openAI, model: "gpt-4.1-mini", effort: .high))
        XCTAssertThrowsError(try ClassificationModelPolicy.validate(provider: .gemini, model: "gemini-3-pro-preview", effort: .medium))
        XCTAssertThrowsError(try ClassificationModelPolicy.validate(provider: .gemini, model: "gemini-2.5-flash", effort: .providerDefault))
        XCTAssertFalse(ClassificationModelPolicy.searchCompatible(provider: .gemini, model: "gemini-3-pro-image"))
        XCTAssertEqual(ClassificationModelPolicy.efforts(provider: .xAI, model: "grok-4.20-multi-agent"), [.providerDefault])
    }
    func testOldSearchOffSettingsBecomeAlwaysSearchWithoutRestoringTheSwitch() throws {
        let api = try JSONDecoder().decode(APIKeyClassificationSettings.self, from: Data(#"{"profileID":"p","model":"gemini-3.1-flash-lite","searchEnabled":false}"#.utf8))
        let subscription = try JSONDecoder().decode(ChatGPTClassificationSettings.self, from: Data(#"{"accountID":"a","model":"gpt-6.1-sol","searchEnabled":false}"#.utf8))
        XCTAssertEqual(api.reasoningEffort, .providerDefault); XCTAssertEqual(subscription.reasoningEffort, .low)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(api), as: UTF8.self).contains("searchEnabled"))
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(subscription), as: UTF8.self).contains("searchEnabled"))
    }
    func testReasoningChangesAutomaticCacheCurrencyForEachConnection() {
        var type = ClassifierTypeAsset(name: "Fixture", treeID: "t", treeRevision: 1, datasetID: "d", datasetRevision: 1)
        let subscription = type.cloudModelVersion; type.chatGPT.reasoningEffort = .high
        XCTAssertNotEqual(type.cloudModelVersion, subscription)
        type.classificationProvider = .apiKey; type.apiKey = .init(profileID: "p", model: "gemini-3.1-flash-lite")
        let api = type.cloudModelVersion; type.apiKey.reasoningEffort = .low
        XCTAssertNotEqual(type.cloudModelVersion, api)
    }
}
