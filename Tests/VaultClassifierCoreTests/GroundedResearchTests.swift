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

    // Research is provider-grounding only (RESEARCH-REDESIGN Cut A): one call to a
    // grounding-capable provider that searches natively. No raw-search leg exists.

    func testExecutorSendsOnlySanitizedSubjectAndReturnsKnowledgeWithoutTags() async throws {
        let grounded = Data(#"""
        {"candidates":[{"content":{"parts":[{"text":"HermitCraft is a collaborative Minecraft survival multiplayer series."}]},"groundingMetadata":{"groundingChunks":[{"web":{"uri":"https://example.test/hermitcraft"}}]}}],"usageMetadata":{"promptTokenCount":21,"candidatesTokenCount":9}}
        """#.utf8)
        let http = ScriptedResearchHTTPClient(responses: [grounded])
        let configuration = GroundedResearchProviderConfiguration(
            llmProfile: .init(type: .gemini, credential: "llm-key"),
            llmCredential: .init(values: [.apiKey: "llm-key"]),
            llmModelIdentifier: "model"
        )
        let subject = try XCTUnwrap(ResearchSubject(kind: .term, subject: "HermitCraft"))

        let result = try await GroundedResearchExecutor(http: http).research(subject, using: configuration)

        XCTAssertEqual(result.knowledge.kind, .term)
        XCTAssertEqual(result.knowledge.subject, "HermitCraft")
        XCTAssertEqual(result.knowledge.contextTagHints, [])
        XCTAssertEqual(result.knowledge.sourceURLs, ["https://example.test/hermitcraft"])
        XCTAssertEqual(result.chargedTokenCount, 30)
        XCTAssertLessThanOrEqual(result.knowledge.meaning.count, KnowledgeEntry.maximumMeaningLength)

        XCTAssertEqual(http.capturedRequests.count, 1, "a single grounded call — no separate search provider")
        let outbound = http.capturedRequests.compactMap(\.httpBody).map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n")
        XCTAssertTrue(outbound.contains("HermitCraft"))
        XCTAssertFalse(outbound.contains("RAW PRIVATE VIDEO TITLE"))
    }

    func testMissingUsageChargesRequestedOutputCap() async throws {
        let grounded = Data(#"{"candidates":[{"content":{"parts":[{"text":"A public game show."}]}}]}"#.utf8)
        let http = ScriptedResearchHTTPClient(responses: [grounded])
        let configuration = GroundedResearchProviderConfiguration(
            llmProfile: .init(type: .gemini, credential: "llm-key"),
            llmCredential: .init(values: [.apiKey: "llm-key"]),
            llmModelIdentifier: "model",
            maximumOutputTokens: 77
        )
        let result = try await GroundedResearchExecutor(http: http).research(
            XCTUnwrap(ResearchSubject(kind: .term, subject: "The Show")),
            using: configuration
        )
        XCTAssertEqual(result.chargedTokenCount, 77)
    }
}
