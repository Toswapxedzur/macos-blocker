import Foundation
import XCTest
@testable import VaultClassifierCore
@testable import VaultClassifierResearch

private final class ScriptedGroundingHTTPClient: ProviderHTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [Data]
    private(set) var requests: [URLRequest] = []

    init(responses: [Data]) { self.responses = responses }

    func send(
        plan: ProviderRequestPlan,
        body: Data?,
        credential: ProviderCredentialRecord,
        timeout: TimeInterval
    ) async throws -> (data: Data, response: HTTPURLResponse) {
        try lock.withLock {
            var request = URLRequest(url: plan.url)
            request.httpMethod = plan.method
            request.httpBody = body
            requests.append(request)
            guard !responses.isEmpty else { throw ProviderTestProtocolError.invalidResponse }
            let data = responses.removeFirst()
            return (data, HTTPURLResponse(url: plan.url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    var capturedRequests: [URLRequest] { lock.withLock { requests } }
}

final class GroundedGenerationProtocolTests: XCTestCase {
    // MARK: - retired raw-search settings

    /// A state saved while raw search existed still decodes (the retired keys are
    /// ignored — research is provider-grounding only) and never re-encodes them.
    func testRetiredRawSearchKeysAreIgnoredAndNeverReencoded() throws {
        let legacy = Data(#"{"enabled":true,"requestsPerMinute":6,"searchMode":"rawSearchProvider","webSearchProviderProfileID":"serper-1","searchResultCount":3,"snippetContextChars":900}"#.utf8)
        let decoded = try JSONDecoder().decode(ResearchSettings.self, from: legacy)
        XCTAssertTrue(decoded.enabled)
        XCTAssertEqual(decoded.requestsPerMinute, 6)

        let reencoded = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)
        for retired in ["searchMode", "webSearchProviderProfileID", "searchResultCount", "snippetContextChars"] {
            XCTAssertFalse(reencoded.contains(retired))
        }
    }

    // MARK: - Capability gate

    func testSupportsProviderGroundingOnlyForNativeSearchProviders() {
        for type in [APIKeyProviderType.openAI, .gemini, .anthropic] {
            XCTAssertTrue(
                GroundedGenerationProtocol.supportsProviderGrounding(profile: .init(type: type)),
                "\(type) should support provider grounding"
            )
        }
        for type in [APIKeyProviderType.serper, .youSearch, .ollama, .deepSeek] {
            XCTAssertFalse(
                GroundedGenerationProtocol.supportsProviderGrounding(profile: .init(type: type)),
                "\(type) should not support provider grounding"
            )
        }
    }

    // MARK: - Request building injects the native-search tool per family

    func testGeminiGroundedRequestInjectsGoogleSearchToolAndOnlySubject() throws {
        let request = try GroundedGenerationProtocol.prepareGroundedGenerate(
            profile: .init(type: .gemini, credential: "key"),
            modelIdentifier: "gemini-2.0-flash",
            subject: "HermitCraft",
            maximumOutputTokens: 128
        )
        let body = String(decoding: try XCTUnwrap(request.body), as: UTF8.self)
        XCTAssertTrue(body.contains("google_search"))
        XCTAssertTrue(body.contains("HermitCraft"))
        XCTAssertFalse(body.contains("web_search"))
    }

    func testOpenAIGroundedRequestInjectsWebSearchTool() throws {
        let request = try GroundedGenerationProtocol.prepareGroundedGenerate(
            profile: .init(type: .openAI, credential: "key"),
            modelIdentifier: "gpt-4.1",
            subject: "HermitCraft",
            maximumOutputTokens: 128
        )
        let body = String(decoding: try XCTUnwrap(request.body), as: UTF8.self)
        XCTAssertTrue(body.contains("web_search"))
        XCTAssertTrue(body.contains("HermitCraft"))
    }

    func testAnthropicGroundedRequestInjectsWebSearchTool() throws {
        let request = try GroundedGenerationProtocol.prepareGroundedGenerate(
            profile: .init(type: .anthropic, credential: "key"),
            modelIdentifier: "claude-sonnet-4",
            subject: "HermitCraft",
            maximumOutputTokens: 128
        )
        let body = String(decoding: try XCTUnwrap(request.body), as: UTF8.self)
        XCTAssertTrue(body.contains("web_search_20250305"))
        XCTAssertTrue(body.contains("HermitCraft"))
    }

    func testGroundedPromptIsCreatorAwareForCreatorSubjects() throws {
        let creatorRequest = try GroundedGenerationProtocol.prepareGroundedGenerate(
            profile: .init(type: .gemini, credential: "key"),
            modelIdentifier: "gemini-2.0-flash",
            subject: "@hermitcraft",
            kind: .creator,
            maximumOutputTokens: 128
        )
        let creatorBody = String(decoding: try XCTUnwrap(creatorRequest.body), as: UTF8.self)
        XCTAssertTrue(creatorBody.contains("creator or channel"))
        XCTAssertTrue(creatorBody.contains("content they are known for"))
        XCTAssertTrue(creatorBody.contains("@hermitcraft"))

        let termRequest = try GroundedGenerationProtocol.prepareGroundedGenerate(
            profile: .init(type: .gemini, credential: "key"),
            modelIdentifier: "gemini-2.0-flash",
            subject: "HermitCraft",
            kind: .term,
            maximumOutputTokens: 128
        )
        let termBody = String(decoding: try XCTUnwrap(termRequest.body), as: UTF8.self)
        XCTAssertFalse(termBody.contains("creator or channel"))
        XCTAssertTrue(termBody.contains("what or who it is"))
    }

    func testUnsupportedProviderCannotBuildGroundedRequest() {
        XCTAssertThrowsError(try GroundedGenerationProtocol.prepareGroundedGenerate(
            profile: .init(type: .serper, credential: "key"),
            modelIdentifier: "model",
            subject: "Subject",
            maximumOutputTokens: 128
        ))
    }

    // MARK: - Response parsing (text + best-effort sources)

    func testParsesGeminiGroundedTextAndSourceURLs() throws {
        let data = Data(#"""
        {"candidates":[{"content":{"parts":[{"text":"HermitCraft is a collaborative Minecraft server."}]},"groundingMetadata":{"groundingChunks":[{"web":{"uri":"https://example.test/hc","title":"HC"}},{"web":{"uri":"https://example.test/hc2"}}]}}],"usageMetadata":{"promptTokenCount":10,"candidatesTokenCount":8}}
        """#.utf8)
        let parsed = try GroundedGenerationProtocol.parseGroundedGeneration(data, format: .geminiGenerateContent)
        XCTAssertTrue(parsed.text.contains("collaborative Minecraft server"))
        XCTAssertEqual(parsed.sourceURLs, ["https://example.test/hc", "https://example.test/hc2"])
    }

    func testSourceExtractionSkipsNonHTTPAndDeduplicates() throws {
        let data = Data(#"{"a":{"url":"https://example.test/x"},"b":[{"uri":"https://example.test/x"},{"uri":"ftp://example.test/y"}]}"#.utf8)
        let urls = GroundedGenerationProtocol.extractSourceURLs(data, format: .geminiGenerateContent)
        XCTAssertEqual(urls, ["https://example.test/x"])
    }

    // MARK: - Executor provider-grounding branch (single call, sources kept)

    func testExecutorProviderGroundingUsesSingleCallAndKeepsSources() async throws {
        let grounded = Data(#"""
        {"candidates":[{"content":{"parts":[{"text":"HermitCraft is a collaborative Minecraft survival series."}]},"groundingMetadata":{"groundingChunks":[{"web":{"uri":"https://example.test/hc"}}]}}],"usageMetadata":{"promptTokenCount":12,"candidatesTokenCount":9}}
        """#.utf8)
        let http = ScriptedGroundingHTTPClient(responses: [grounded])
        let configuration = GroundedResearchProviderConfiguration(
            llmProfile: .init(type: .gemini, credential: "llm-key"),
            llmCredential: .init(values: [.apiKey: "llm-key"]),
            llmModelIdentifier: "gemini-2.0-flash"
        )
        let subject = try XCTUnwrap(ResearchSubject(kind: .term, subject: "HermitCraft"))

        let result = try await GroundedResearchExecutor(http: http).research(subject, using: configuration)

        // Exactly one outbound request — no separate raw-search leg.
        XCTAssertEqual(http.capturedRequests.count, 1)
        XCTAssertEqual(result.knowledge.subject, "HermitCraft")
        XCTAssertTrue(result.knowledge.meaning.contains("collaborative Minecraft"))
        XCTAssertEqual(result.knowledge.contextTagHints, [])
        XCTAssertEqual(result.knowledge.sourceURLs, ["https://example.test/hc"])

        let outbound = String(decoding: try XCTUnwrap(http.capturedRequests.first?.httpBody), as: UTF8.self)
        XCTAssertTrue(outbound.contains("google_search"))
        XCTAssertTrue(outbound.contains("HermitCraft"))
    }

    func testExecutorGroundingRejectsNonGroundingProvider() async {
        let http = ScriptedGroundingHTTPClient(responses: [Data("{}".utf8)])
        let configuration = GroundedResearchProviderConfiguration(
            llmProfile: .init(type: .deepSeek, credential: "llm-key"),
            llmCredential: .init(values: [.apiKey: "llm-key"]),
            llmModelIdentifier: "model"
        )
        do {
            _ = try await GroundedResearchExecutor(http: http).research(
                try XCTUnwrap(ResearchSubject(kind: .term, subject: "Subject")),
                using: configuration
            )
            XCTFail("Expected grounding to reject a non-grounding provider")
        } catch {
            XCTAssertEqual(http.capturedRequests.count, 0)
        }
    }
}
