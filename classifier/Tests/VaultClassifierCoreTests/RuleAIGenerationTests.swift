import XCTest
@testable import VaultClassifierCore
@testable import VaultClassifierResearch

final class RuleAIGenerationTests: XCTestCase {
    func testPromptIsGenericAndAllConnectionsEnableSearchAndEffort() throws {
        let input = try RuleAIInput(payload: #"{"prompt":"Summarize input","input":{"text":"example"},"maxOutputTokens":512}"#)
        for (provider, model) in [(APIKeyProviderType.openAI,"gpt-5"),(.gemini,"gemini-3-flash-preview"),(.xAI,"grok-4.6-fixture")] {
            let profile = APIKeyProviderProfile(name: "Fixture", type: provider, credential: "fixture-only-key")
            let request = try RuleAIGeneration.apiKey(profile: profile, model: model, effort: .low, input: input)
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.body)) as? [String: Any])
            XCTAssertNotNil(root["tools"])
            let encoded = String(decoding: request.body, as: UTF8.self)
            XCTAssertTrue(encoded.contains("Summarize input")); XCTAssertFalse(encoded.contains("vault_classification"))
            XCTAssertTrue(encoded.contains("low")); XCTAssertFalse(encoded.contains("fixture-only-key"))
        }
        let subscription = try RuleAIGeneration.subscription(model: "gpt-5", effort: .low, input: input)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(subscription.body)) as? [String: Any])
        XCTAssertEqual(root["max_output_tokens"] as? Int, 512); XCTAssertNotNil(root["tools"])
    }
    func testInputBoundsRejectProviderOverridesAndNonIntegerTokens() throws {
        for payload in [#"{"prompt":"x","model":"override"}"#, #"{"prompt":"x","maxOutputTokens":true}"#, #"{"prompt":"x","maxOutputTokens":1.2}"#, #"{"prompt":"x","maxOutputTokens":4097}"#, #"{"prompt":""}"#] {
            XCTAssertThrowsError(try RuleAIInput(payload: payload))
        }
        let raw = try JSONSerialization.data(withJSONObject: ["prompt":String(repeating:"x",count:20001)])
        XCTAssertThrowsError(try RuleAIInput(payload:String(decoding:raw,as:UTF8.self)))
    }
    func testGenericResponseAndCitationParsingRejectsIncompleteResults() throws {
        let root: [String: Any] = ["status":"completed", "output":[["type":"message","role":"assistant","content":[["type":"output_text","text":"A useful summary", "annotations":[["type":"url_citation","url":"https://example.com/source","title":"Source"],["url":"javascript:alert(1)"]]]]]]]
        let reply = try RuleAIGeneration.parse(JSONSerialization.data(withJSONObject:root),format:.openAIResponses)
        XCTAssertEqual(reply.text,"A useful summary"); XCTAssertEqual(reply.citations.count,1)
        var incomplete=root;incomplete["status"]="incomplete"
        XCTAssertThrowsError(try RuleAIGeneration.parse(JSONSerialization.data(withJSONObject:incomplete),format:.openAIResponses))
    }
}
