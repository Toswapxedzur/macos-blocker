import Foundation
import XCTest
@testable import VaultClassifierCore

final class ProviderGenerationProtocolTests: XCTestCase {
    func testArbitrarySearchRequestIsBoundedAndProviderSpecific() throws {
        let serper = APIKeyProviderProfile(type: .serper, credential: "key")
        let prepared = try RawWebSearchProtocol.prepareSearch(
            profile: serper,
            query: "  Example   Show  ",
            resultCount: 3
        )
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: prepared.body) as? [String: Any])
        XCTAssertEqual(body["q"] as? String, "Example Show")
        XCTAssertEqual(body["num"] as? Int, 3)
        XCTAssertEqual(prepared.operation, .searchWeb)

        XCTAssertThrowsError(try RawWebSearchProtocol.prepareSearch(
            profile: serper,
            query: String(repeating: "x", count: RawWebSearchProtocol.maximumQueryCharacters + 1)
        ))
    }

    func testSearchParsersBoundAndSanitizePublicURLs() throws {
        let data = Data(#"{"organic":[{"title":"One","link":"https://user:pass@example.test/a#private","snippet":"Result"},{"title":"Bad","link":"file:///tmp/private","snippet":"drop"}]}"#.utf8)
        let results = try RawWebSearchProtocol.parseResults(data, format: .serperSearch)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].url, "https://example.test/a")
    }

    func testGenerationBodiesCoverEverySupportedFormat() throws {
        let cases: [(APIKeyProviderType, ProviderRequestBodyFormat)] = [
            (.openAI, .openAIResponses),
            (.deepSeek, .openAIChatCompletions),
            (.anthropic, .anthropicMessages),
            (.gemini, .geminiGenerateContent),
            (.cohere, .cohereChat),
            (.ollama, .ollamaChat),
        ]
        for (type, expectedFormat) in cases {
            let profile = APIKeyProviderProfile(type: type, credential: type == .ollama ? nil : "key")
            let prepared = try ProviderGenerationProtocol.prepareGenerateText(
                profile: profile,
                modelIdentifier: "model",
                systemPrompt: "Facts only.",
                userPrompt: "Explain the subject.",
                maximumOutputTokens: 64
            )
            XCTAssertEqual(prepared.plan.bodyFormat, expectedFormat)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: prepared.body) as? [String: Any])
            XCTAssertEqual(json["model"] as? String, expectedFormat == .geminiGenerateContent ? nil : "model")
            XCTAssertFalse(prepared.body.isEmpty)
        }
    }

    func testGenerationParserReusesProviderTestResponseContract() throws {
        let response = Data(#"{"choices":[{"message":{"content":"Grounded meaning"}}],"usage":{"prompt_tokens":8,"completion_tokens":3}}"#.utf8)
        let parsed = try ProviderGenerationProtocol.parseGeneratedText(
            response,
            format: .openAIChatCompletions
        )
        XCTAssertEqual(parsed.content, "Grounded meaning")
        XCTAssertEqual(parsed.usage.tokenCount, 11)
    }

    func testSearchOnlyAndEmbeddingFormatsCannotGenerate() throws {
        XCTAssertThrowsError(try ProviderGenerationProtocol.prepareGenerateText(
            profile: .init(type: .serper, credential: "key"),
            modelIdentifier: "model",
            userPrompt: "prompt",
            maximumOutputTokens: 32
        )) { error in
            XCTAssertEqual(error as? ProviderTestProtocolError, .unsupportedProvider)
        }
    }
}
