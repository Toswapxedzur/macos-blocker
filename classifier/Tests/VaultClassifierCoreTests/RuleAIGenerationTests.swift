import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import VaultClassifierCore
@testable import VaultClassifierResearch

final class RuleAIGenerationTests: XCTestCase {
    func testRealAPIClientUsesSavedCredentialsAndReturnsGenericResultsForThreeProviders() async throws {
        let input=try RuleAIInput(payload:#"{"prompt":"Summarize","input":{"text":"fixture"}}"#)
        for (provider,model,host,header) in [(APIKeyProviderType.openAI,"gpt-5","api.openai.com","Authorization"),(.gemini,"gemini-3-flash-preview","generativelanguage.googleapis.com","x-goog-api-key"),(.xAI,"grok-4.6-fixture","api.x.ai","Authorization")] {
            let profile=APIKeyProviderProfile(id:"fixture",type:provider,credential:"fixture-only-key")
            let response: [String:Any] = provider == .gemini ? ["candidates":[["finishReason":"STOP","content":["parts":[["text":"A summary"]]]]]] : ["status":"completed","output":[["type":"message","content":[["type":"output_text","text":"A summary"]]]]]
            let bytes=try JSONSerialization.data(withJSONObject:response)
            let http=URLSessionProviderHTTPClient { request in
                XCTAssertTrue(request.timeoutInterval.isInfinite)
                XCTAssertEqual(request.url?.host,host)
                XCTAssertEqual(request.value(forHTTPHeaderField:header),provider == .gemini ? "fixture-only-key" : "Bearer fixture-only-key")
                let body=try XCTUnwrap(JSONSerialization.jsonObject(with:XCTUnwrap(request.httpBody)) as? [String:Any])
                XCTAssertNotNil(body["tools"]);XCTAssertFalse(String(decoding:request.httpBody!,as:UTF8.self).contains("fixture-only-key"))
                XCTAssertNil(body["text"],"arbitrary rule calls must not inherit the tagging schema")
                return (bytes,HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!)
            }
            let client=APIKeyClassificationClient(profiles:{_ in profile},http:http)
            let result=try await client.generateForRule(profileID:profile.id,model:model,effort:.low,input:input)
            XCTAssertEqual(result.text,"A summary")
            let status=await client.status();XCTAssertEqual(status.requestsToday,1)
            await client.shutdown()
        }
    }
    func testPromptIsGenericAndAllConnectionsEnableSearchAndEffort() throws {
        let input = try RuleAIInput(payload: #"{"prompt":"Summarize input","input":{"text":"example"}}"#)
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
        XCTAssertNil(root["max_output_tokens"]); XCTAssertNotNil(root["tools"])
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
