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

private actor APIBatchTransport: ProviderHTTPClient {
    var active = 0
    var peak = 0
    var calls = 0
    let suspend: Bool
    init(suspend: Bool = false) { self.suspend = suspend }
    func send(plan: ProviderRequestPlan, body: Data?, credential: ProviderCredentialRecord, timeout: TimeInterval) async throws -> (data: Data, response: HTTPURLResponse) {
        active += 1; calls += 1; peak = max(peak, active)
        defer { active -= 1 }
        let object = try JSONSerialization.jsonObject(with: body!) as! [String: Any]
        let inputs = object["input"] as! [[String: Any]]
        let text = inputs[0]["content"] as! String
        let items = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [[String: Any]]
        try await Task.sleep(nanoseconds: suspend ? 30_000_000_000 : (text.contains("Mathematics") ? 60_000_000 : 5_000_000))
        let values: [[String: Any]] = items.map { item in
            ["index": item["index"]!, "tags": [["name": (item["evidence"] as! String).contains("Mathematics") ? "Mathematics" : "Games", "confidence": 5]]]
        }
        let output = String(decoding: try JSONSerialization.data(withJSONObject: ["items": values]), as: UTF8.self)
        let data = try JSONSerialization.data(withJSONObject: ["status": "completed", "output": [["type": "message", "content": [["type": "output_text", "text": output]]]]])
        return (data, HTTPURLResponse(url: plan.url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    func counts() -> (Int, Int, Int) { (calls, peak, active) }
}

extension APIKeyClassificationTests {
    func testParallelAPIBatchesKeepOrderAndGlobalConcurrencyAcrossCallers() async throws {
        let transport = APIBatchTransport()
        let profile = APIKeyProviderProfile(id: "p", type: .openAI, credential: "fixture-not-real")
        let client = APIKeyClassificationClient(profiles: { _ in profile }, http: transport)
        let type = ClassifierTypeAsset(name: "Fixture", treeID: "t", treeRevision: 1, datasetID: "d", datasetRevision: 1,
            classificationProvider: .apiKey, apiKey: .init(profileID: "p", model: "fixture"))
        let engine = try await client.resolveCloudEngine(for: type)
        let requests = (0..<32).map { index in LLMClassificationRequest(staticPrefix: item.staticPrefix,
            dynamicSuffix: index < 16 ? "Mathematics" : "Games", allowedTagNames: item.allowedTagNames, maximumTags: 3) }
        try await withThrowingTaskGroup(of: [LLMClassificationResult].self) { group in
            for _ in 0..<3 { group.addTask { try await engine.classifyAll(requests) } }
            for try await values in group {
                XCTAssertEqual(values.map { $0.tags.first?.name }, Array(repeating: "Mathematics", count: 16) + Array(repeating: "Games", count: 16))
            }
        }
        let counts = await transport.counts(); XCTAssertEqual(counts.0, 6); XCTAssertEqual(counts.1, 2); XCTAssertEqual(counts.2, 0)
        await client.shutdown()
    }
    func testShutdownCancelsAPIInferenceWithoutSettingRetryFailure() async throws {
        let transport = APIBatchTransport(suspend: true)
        let profile = APIKeyProviderProfile(id: "p", type: .gemini, credential: "fixture-not-real")
        // Use OpenAI's fixture transport grammar so the held task reaches its await.
        let openAI = APIKeyProviderProfile(id: profile.id, type: .openAI, credential: profile.credential)
        let client = APIKeyClassificationClient(profiles: { _ in openAI }, http: transport)
        let type = ClassifierTypeAsset(name: "Fixture", treeID: "t", treeRevision: 1, datasetID: "d", datasetRevision: 1,
            classificationProvider: .apiKey, apiKey: .init(profileID: profile.id, model: "fixture"))
        let engine = try await client.resolveCloudEngine(for: type), request = item
        let task = Task { try await engine.classify(request) }
        while await transport.counts().0 == 0 { await Task.yield() }
        await client.shutdown()
        do { _ = try await task.value; XCTFail("shutdown must cancel") } catch { XCTAssertTrue(error is CancellationError) }
        let status = await client.status(); XCTAssertTrue(status.failedProfileIDs.isEmpty)
        let counts = await transport.counts(); XCTAssertEqual(counts.2, 0)
    }
    func testAPIKeyClientNeverActsAsFallbackForSubscriptionSelection() async throws {
        let profile = APIKeyProviderProfile(id: "p", type: .openAI, credential: "fixture-not-real")
        let client = APIKeyClassificationClient(profiles: { _ in profile }, http: APIBatchTransport())
        let group = ClassifierTypeAsset(name: "Fixture", treeID: "t", treeRevision: 1, datasetID: "d", datasetRevision: 1,
            classificationProvider: .chatGPT, apiKey: .init(profileID: "p", model: "previous-api-model"))
        do { _ = try await client.resolveCloudEngine(for: group); XCTFail("No fallback is permitted") }
        catch { XCTAssertEqual(error as? CloudClassificationError, .notConfigured) }
        let status = await client.status(); XCTAssertEqual(status.requestsToday, 0)
        await client.shutdown()
    }
    func testSchemaFivePreservesSubscriptionAndDiscardsRetiredLocalProvider() throws {
        var state = LocalClassifierState()
        let tree = state.workspaceCatalog.trees[0], dataset = state.workspaceCatalog.datasets[0]
        state.workspaceCatalog.classifierTypes = [.init(name: "Existing", treeID: tree.id, treeRevision: tree.revision,
            datasetID: dataset.id, datasetRevision: dataset.revision, chatGPT: .init(accountID: "saved", model: "selected", searchEnabled: true))]
        var root = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as! [String: Any]
        root["schemaVersion"] = 5
        var metadata = root["storageMetadata"] as! [String: Any]; metadata["schemaVersion"] = 5; root["storageMetadata"] = metadata
        var catalog = root["workspaceCatalog"] as! [String: Any]
        catalog["providerProfiles"] = [["id": "retired", "type": "ollama", "credential": ["malformed": true]]]
        root["workspaceCatalog"] = catalog
        let loaded = try JSONDecoder().decode(LocalClassifierState.self, from: JSONSerialization.data(withJSONObject: root))
        XCTAssertEqual(loaded.schemaVersion, 6)
        XCTAssertEqual(loaded.workspaceCatalog.classifierTypes, state.workspaceCatalog.classifierTypes)
        XCTAssertTrue(loaded.workspaceCatalog.providerProfiles.isEmpty)
        XCTAssertEqual(loaded.workspaceCatalog.classifierTypes[0].cloudModelVersion, state.workspaceCatalog.classifierTypes[0].cloudModelVersion)
    }
}
