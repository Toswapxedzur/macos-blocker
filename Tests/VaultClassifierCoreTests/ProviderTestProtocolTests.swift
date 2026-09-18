import Foundation
import XCTest
@testable import VaultClassifierCore
@testable import VaultClassifierResearch

final class ProviderTestProtocolTests: XCTestCase {
    func testGeminiConnectionTestUsesFixedPromptAndParsesUsage() throws {
        let prepared = try ProviderTestProtocol.prepare(profile: .init(type: .gemini))
        XCTAssertEqual(prepared.operation, .generateText)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: prepared.body) as? [String: Any])
        XCTAssertEqual(
            (((body["contents"] as? [[String: Any]])?.first?["parts"] as? [[String: Any]])?.first?["text"] as? String),
            ProviderTestProtocol.prompt
        )
        let response = Data(#"{"usageMetadata":{"promptTokenCount":7,"candidatesTokenCount":2},"candidates":[{"content":{"parts":[{"text":"OK"}]}}]}"#.utf8)
        let parsed = try ProviderTestProtocol.parseResponse(response, format: .geminiGenerateContent, operation: .generateText)
        XCTAssertEqual(parsed.content, "OK")
        XCTAssertEqual(parsed.usage, .init(tokenCount: 9))
    }

    func testCompatibleConnectionUsesExplicitTestModel() throws {
        let profile = APIKeyProviderProfile(
            type: .openAICompatible,
            customEndpoint: "https://api.example.test/v1",
            testModelIdentifier: "test-model"
        )
        let prepared = try ProviderTestProtocol.prepare(profile: profile)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: prepared.body) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "test-model")
    }

    func testCustomConnectionWithoutModelIsRejected() {
        let profile = APIKeyProviderProfile(type: .custom, customEndpoint: "https://api.example.test/v1")
        XCTAssertThrowsError(try ProviderTestProtocol.prepare(profile: profile)) { error in
            XCTAssertEqual(error as? ProviderTestProtocolError, .modelRequired)
        }
    }

    func testOfficialPlatformConnectionTestContainsNoCollectedEvidence() throws {
        let profile = APIKeyProviderProfile(type: .youtubeData, credential: "test-key")
        let prepared = try ProviderTestProtocol.prepare(profile: profile)
        XCTAssertEqual(prepared.operation, .readPublicContent)
        XCTAssertEqual(prepared.plan.method, "GET")
        XCTAssertTrue(prepared.body.isEmpty)
        XCTAssertTrue(prepared.plan.url.absoluteString.contains("videos"))
        XCTAssertFalse(prepared.plan.url.absoluteString.contains("creator"))
    }

    func testResponseShapeDoesNotRetainProviderValues() {
        let shape = ProviderTestProtocol.responseShape(for: Data(#"{"choices":[{"message":{"content":"secret output"}}]}"#.utf8))
        XCTAssertTrue(shape.contains("content: non-empty string"))
        XCTAssertFalse(shape.contains("secret output"))
    }
}
