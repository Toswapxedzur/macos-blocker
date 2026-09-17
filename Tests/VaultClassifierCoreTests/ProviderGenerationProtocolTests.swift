import Foundation
import XCTest
@testable import VaultClassifierCore

final class ProviderGenerationProtocolTests: XCTestCase {
    /// Serper / You.com fed the removed raw-search mode. Their types stay decodable
    /// (a saved profile is never silently dropped) but they are retired: flagged,
    /// untestable, and unusable for research.
    func testSearchOnlyProvidersAreRetiredButStillDecodable() throws {
        for type in [APIKeyProviderType.serper, .youSearch] {
            XCTAssertTrue(type.isRetiredSearchProvider)
            let profile = APIKeyProviderProfile(type: type, credential: "key")
            let decoded = try JSONDecoder().decode(APIKeyProviderProfile.self, from: JSONEncoder().encode(profile))
            XCTAssertEqual(decoded.type, type)
            XCTAssertThrowsError(try ProviderTestProtocol.prepare(profile: profile))
            XCTAssertFalse(GroundedGenerationProtocol.supportsProviderGrounding(profile: profile))
        }
        XCTAssertFalse(APIKeyProviderType.gemini.isRetiredSearchProvider)
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
