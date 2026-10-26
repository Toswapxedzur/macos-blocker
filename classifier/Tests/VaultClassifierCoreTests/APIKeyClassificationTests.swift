import Foundation
import XCTest
@testable import VaultClassifierCore
@testable import VaultClassifierResearch
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class APIKeyClassificationTests: XCTestCase {
    private var item: LLMClassificationRequest { .init(staticPrefix: "Tags: Games, Mathematics. " + ClassificationReplyFormat.current.rule,
        dynamicSuffix: "Title: Games tutorial" + ClassificationReplyFormat.current.runway, allowedTagNames: ["Games", "Mathematics"], maximumTags: 3) }
    private let reply = #"{"items":[{"index":0,"tags":[{"name":"Games","confidence":5}]}]}"#
    private func response(_ type: APIKeyProviderType) throws -> Data {
        let object: [String: Any]
        if type == .gemini { object = ["candidates": [["finishReason": "STOP", "content": ["parts": [["text": reply]]]]]] }
        else { object = ["status": "completed", "output": [["type": "message", "content": [["type": "output_text", "text": reply]]]]] }
        return try JSONSerialization.data(withJSONObject: object)
    }
    func testThreeProvidersUseOfficialEndpointsHeadersAndStructuredBodies() async throws {
        for (type, host, model, header) in [(APIKeyProviderType.openAI,"api.openai.com","gpt-4.1-mini","Authorization"),(.gemini,"generativelanguage.googleapis.com","gemini-3-fixture","x-goog-api-key"),(.xAI,"api.x.ai","grok-fixture","Authorization")] {
            let profile = APIKeyProviderProfile(id: "fixture", type: type, credential: "fixture-key-not-real")
            let expected = try response(type)
            let http = URLSessionProviderHTTPClient { request in
                XCTAssertEqual(request.url?.host, host)
                XCTAssertEqual(request.value(forHTTPHeaderField: header), type == .gemini ? "fixture-key-not-real" : "Bearer fixture-key-not-real")
                XCTAssertFalse(request.url!.absoluteString.contains("fixture-key"))
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                XCTAssertNil(body["tools"], "search must remain explicitly disabled")
                XCTAssertFalse(String(decoding: request.httpBody!, as: UTF8.self).contains("fixture-key"))
                if type == .gemini { XCTAssertNotNil(body["generationConfig"]); XCTAssertNotNil(body["contents"]) }
                else { XCTAssertEqual(body["stream"] as? Bool, false); XCTAssertNotNil(body["text"]) }
                return (expected, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            let client = APIKeyClassificationClient(profiles: { _ in profile }, http: http)
            let group = ClassifierTypeAsset(name: "Fixture", treeID: "t", treeRevision: 1, datasetID: "d", datasetRevision: 1,
                classificationProvider: .apiKey, apiKey: .init(profileID: profile.id, model: model))
            let engine = try await client.resolveCloudEngine(for: group)
            let result = try await engine.classify(item)
            XCTAssertEqual(result.tags.map(\.name), ["Games"])
            let status = await client.status(); XCTAssertEqual(status.requestsToday, 1)
            await client.shutdown()
        }
    }
    func testFailureIsHeldUntilExplicitRetryAndDoesNotPersistCredentials() async throws {
        let profile = APIKeyProviderProfile(id: "fixture", type: .xAI, credential: "fixture-key-not-real")
        let http = URLSessionProviderHTTPClient { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!)
        }
        let client = APIKeyClassificationClient(profiles: { _ in profile }, http: http)
        let group = ClassifierTypeAsset(name: "Fixture", treeID: "t", treeRevision: 1, datasetID: "d", datasetRevision: 1,
            classificationProvider: .apiKey, apiKey: .init(profileID: profile.id, model: "fixture"))
        let engine = try await client.resolveCloudEngine(for: group)
        for _ in 0..<3 { do { _ = try await engine.classify(item); XCTFail("must fail") } catch {} }
        let held = await client.status(); XCTAssertEqual(held.requestsToday, 1)
        XCTAssertTrue(held.failedProfileIDs.contains(profile.id))
        await client.retryFailedRequests()
        do { _ = try await engine.classify(item); XCTFail("fixture is still unavailable") } catch {}
        let retried = await client.status(); XCTAssertEqual(retried.requestsToday, 2)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(group), as: UTF8.self).contains("fixture-key"))
        await client.shutdown()
    }
    func testSearchIsExplicitAndUnsupportedGeminiCombinationIsRefused() throws {
        for type in [APIKeyProviderType.openAI,.gemini,.xAI] {
            let profile = APIKeyProviderProfile(type: type)
            let request = try APIKeyClassificationEngine.prepare([item], configuration: .init(profileID: profile.id, model: "gemini-3-fixture", searchEnabled: true), profile: profile)
            let body = try JSONSerialization.jsonObject(with: request.body) as! [String: Any]
            XCTAssertNotNil(body["tools"])
        }
        XCTAssertThrowsError(try APIKeyClassificationEngine.prepare([item], configuration: .init(profileID: "p", model: "gemini-2.5-flash", searchEnabled: true), profile: .init(type: .gemini)))
    }
    func testProviderAndModelChangesInvalidateOnlyAutomaticCacheCurrency() throws {
        var group = ClassifierTypeAsset(name: "Fixture", treeID: "t", treeRevision: 1, datasetID: "d", datasetRevision: 1)
        let subscription = group.cloudModelVersion
        group.classificationProvider = .apiKey; group.apiKey = .init(profileID: "openai", model: "model-a")
        let api = group.cloudModelVersion; XCTAssertNotEqual(api, subscription)
        group.apiKey.model = "model-b"; XCTAssertNotEqual(api, group.cloudModelVersion)
        group.classificationProvider = .chatGPT; XCTAssertEqual(subscription, group.cloudModelVersion)
    }
}
