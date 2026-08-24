import Foundation
import XCTest
@testable import VaultClassifierCore

private final class ScriptedResearchHTTPClient: ProviderHTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [Data]
    private(set) var requests: [URLRequest] = []

    init(responses: [Data]) {
        self.responses = responses
    }

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

final class GroundedResearchTests: XCTestCase {
    func testSubjectSanitizerAllowsOnlyShortEntitiesAndPublicHandles() throws {
        XCTAssertEqual(ResearchSubject(kind: .term, subject: "  “HermitCraft”  ")?.subject, "HermitCraft")
        XCTAssertEqual(ResearchSubject(kind: .creator, subject: "youtube:handle:@creator")?.subject, "@creator")
        XCTAssertNil(ResearchSubject(kind: .creator, subject: "youtube:channel:UC123"))
        XCTAssertNil(ResearchSubject(kind: .term, subject: "https://example.test/private"))
        XCTAssertNil(ResearchSubject(kind: .term, subject: "Who is this person?"))
        XCTAssertNil(ResearchSubject(kind: .term, subject: String(repeating: "long ", count: 20)))
    }

    func testExecutorSendsOnlySanitizedSubjectAndReturnsKnowledgeWithoutTags() async throws {
        let search = Data(#"{"organic":[{"title":"HermitCraft","link":"https://example.test/hermitcraft","snippet":"A collaborative Minecraft survival server."}]}"#.utf8)
        let completion = Data(#"{"choices":[{"message":{"content":"HermitCraft is a collaborative Minecraft survival multiplayer series."}}],"usage":{"prompt_tokens":21,"completion_tokens":9}}"#.utf8)
        let http = ScriptedResearchHTTPClient(responses: [search, completion])
        let executor = GroundedResearchExecutor(http: http)
        let configuration = GroundedResearchProviderConfiguration(
            llmProfile: .init(type: .deepSeek, credential: "llm-key"),
            llmCredential: .init(values: [.apiKey: "llm-key"]),
            llmModelIdentifier: "model",
            webSearchProfile: .init(type: .serper, credential: "search-key"),
            webSearchCredential: .init(values: [.apiKey: "search-key"])
        )
        let subject = try XCTUnwrap(ResearchSubject(kind: .term, subject: "HermitCraft"))

        let result = try await executor.research(subject, using: configuration)

        XCTAssertEqual(result.knowledge.kind, .term)
        XCTAssertEqual(result.knowledge.subject, "HermitCraft")
        XCTAssertEqual(result.knowledge.contextTagHints, [])
        XCTAssertEqual(result.knowledge.sourceURLs, ["https://example.test/hermitcraft"])
        XCTAssertEqual(result.chargedTokenCount, 30)
        XCTAssertLessThanOrEqual(result.knowledge.meaning.count, KnowledgeEntry.maximumMeaningLength)

        let outbound = http.capturedRequests.compactMap(\.httpBody).map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n")
        XCTAssertTrue(outbound.contains("HermitCraft"))
        XCTAssertFalse(outbound.contains("RAW PRIVATE VIDEO TITLE"))
    }

    func testMissingUsageChargesRequestedOutputCap() async throws {
        let search = Data(#"{"results":{"web":[{"title":"Show","url":"https://example.test/show","snippets":["A game show."]}]}}"#.utf8)
        let completion = Data(#"{"message":{"content":"A public game show."}}"#.utf8)
        let http = ScriptedResearchHTTPClient(responses: [search, completion])
        let configuration = GroundedResearchProviderConfiguration(
            llmProfile: .init(type: .ollama),
            llmCredential: .init(values: [:]),
            llmModelIdentifier: "model",
            webSearchProfile: .init(type: .youSearch, credential: "key"),
            webSearchCredential: .init(values: [.apiKey: "key"]),
            maximumOutputTokens: 77
        )
        let result = try await GroundedResearchExecutor(http: http).research(
            XCTUnwrap(ResearchSubject(kind: .term, subject: "The Show")),
            using: configuration
        )
        XCTAssertEqual(result.chargedTokenCount, 77)
    }

    func testExecutorHonorsSearchCountAndSnippetContextBudget() async throws {
        let longSnippet = String(repeating: "x", count: 700) + "OUTSIDE-CONTEXT"
        let searchObject: [String: Any] = ["organic": [
            ["title": "First", "link": "https://example.test/first", "snippet": longSnippet],
            ["title": "SECOND-RESULT", "link": "https://example.test/second", "snippet": "unused"],
        ]]
        let search = try JSONSerialization.data(withJSONObject: searchObject)
        let completion = Data(#"{"choices":[{"message":{"content":"Grounded."}}]}"#.utf8)
        let http = ScriptedResearchHTTPClient(responses: [search, completion])
        let configuration = GroundedResearchProviderConfiguration(
            llmProfile: .init(type: .deepSeek, credential: "llm-key"),
            llmCredential: .init(values: [.apiKey: "llm-key"]),
            llmModelIdentifier: "model",
            webSearchProfile: .init(type: .serper, credential: "search-key"),
            webSearchCredential: .init(values: [.apiKey: "search-key"]),
            searchResultCount: 1,
            snippetContextChars: 512
        )

        _ = try await GroundedResearchExecutor(http: http).research(
            XCTUnwrap(ResearchSubject(kind: .term, subject: "Subject")),
            using: configuration
        )

        let requests = http.capturedRequests
        XCTAssertTrue(String(decoding: try XCTUnwrap(requests.first?.httpBody), as: UTF8.self).contains(#""num":1"#))
        let generationBody = String(decoding: try XCTUnwrap(requests.last?.httpBody), as: UTF8.self)
        XCTAssertFalse(generationBody.contains("SECOND-RESULT"))
        XCTAssertFalse(generationBody.contains("OUTSIDE-CONTEXT"))
    }
}
