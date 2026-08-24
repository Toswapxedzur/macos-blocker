import Foundation
import XCTest
@testable import VaultClassifierCore

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
    // MARK: - searchMode persistence

    func testSearchModeRoundTripsAndDefaultsToRawWhenAbsent() throws {
        var settings = ResearchSettings()
        XCTAssertEqual(settings.searchMode, .rawSearchProvider)
        settings.searchMode = .providerGrounding

        let encoded = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(ResearchSettings.self, from: encoded)
        XCTAssertEqual(decoded.searchMode, .providerGrounding)

        // Back-compat: a stored payload predating searchMode decodes to the default.
        let legacy = Data(#"{"enabled":true,"requestsPerMinute":6}"#.utf8)
        let legacyDecoded = try JSONDecoder().decode(ResearchSettings.self, from: legacy)
        XCTAssertEqual(legacyDecoded.searchMode, .rawSearchProvider)
        XCTAssertTrue(legacyDecoded.enabled)
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
            searchMode: .providerGrounding,
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
            searchMode: .providerGrounding,
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
