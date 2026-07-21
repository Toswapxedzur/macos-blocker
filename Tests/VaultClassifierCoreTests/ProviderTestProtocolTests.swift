import XCTest
@testable import VaultClassifierCore

final class ProviderTestProtocolTests: XCTestCase {
    func testGeminiTestUsesTheFixedBoundedPromptAndParsesUsage() throws {
        let profile = APIKeyProviderProfile(type: .gemini)
        let prepared = try ProviderTestProtocol.prepare(profile: profile)

        XCTAssertEqual(prepared.operation, .generateText)
        XCTAssertEqual(prepared.plan.url.absoluteString, "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-lite:generateContent")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: prepared.body) as? [String: Any])
        XCTAssertEqual((((body["contents"] as? [[String: Any]])?.first?["parts"] as? [[String: Any]])?.first?["text"] as? String), ProviderTestProtocol.prompt)
        XCTAssertEqual((body["generationConfig"] as? [String: Any])?["maxOutputTokens"] as? Int, ProviderTestProtocol.maximumOutputTokens)

        let response = Data(#"{"usageMetadata":{"promptTokenCount":7,"candidatesTokenCount":2},"candidates":[{"content":{"parts":[{"text":"OK"}]}}]}"#.utf8)
        let parsed = try ProviderTestProtocol.parseResponse(response, format: .geminiGenerateContent, operation: .generateText)
        XCTAssertEqual(parsed.content, "OK")
        XCTAssertEqual(parsed.usage, .init(inputTokens: 7, outputTokens: 2))
    }

    func testOpenAIStyleClassificationParsesUsage() throws {
        let profile = APIKeyProviderProfile(
            type: .openAICompatible,
            customEndpoint: "https://api.deepseek.com/v1"
        )
        let configuration = LLMAssistConfiguration(
            providerProfileID: profile.id,
            modelIdentifier: "deepseek-chat"
        )
        let prepared = try ProviderClassificationProtocol.prepare(
            profile: profile,
            configuration: configuration,
            entry: .init(platform: "youtube", entryID: "entry", surface: .feed, evidence: .init(title: "A test entry")),
            allowedLeafTagIDs: ["games"]
        )
        XCTAssertEqual(prepared.plan.bodyFormat, .openAIChatCompletions)
        let response = Data(#"{"usage":{"prompt_tokens":1000,"completion_tokens":500},"choices":[{"message":{"content":"OK"}}]}"#.utf8)
        let parsed = try ProviderTestProtocol.parseResponse(response, format: .openAIChatCompletions, operation: .generateText)
        XCTAssertEqual(parsed.content, "OK")
        XCTAssertEqual(parsed.usage, .init(inputTokens: 1_000, outputTokens: 500))
    }

    func testRequestRecordPreservesMetadataAndOnlyExplicitContent() throws {
        let profile = APIKeyProviderProfile(id: "gemini", type: .gemini, storesFullRequestRecords: true)
        let record = ProviderRequestRecord(
            profileID: profile.id,
            provider: profile.type.rawValue,
            model: profile.type.defaultModelIdentifier,
            operation: ProviderOperation.generateText.rawValue,
            endpoint: "https://example.test/v1",
            method: "POST",
            statusCode: 200,
            durationMilliseconds: 41,
            inputTokens: 3,
            outputTokens: 1,
            outcome: "succeeded",
            requestContent: ProviderTestProtocol.prompt,
            responseContent: "OK"
        )
        var catalog = WorkspaceCatalog.starter()
        catalog.providerProfiles = [profile]
        catalog.providerRequestRecords = [record]
        XCTAssertNoThrow(try catalog.validate())

        let restored = try JSONDecoder().decode(WorkspaceCatalog.self, from: JSONEncoder().encode(catalog))
        XCTAssertEqual(restored.providerRequestRecords, [record])
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(restored), as: UTF8.self).contains("apiKey"))

        var legacyRecord = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        legacyRecord["estimatedCostUSD"] = 0.0001
        let decodedLegacyRecord = try JSONDecoder().decode(
            ProviderRequestRecord.self,
            from: JSONSerialization.data(withJSONObject: legacyRecord)
        )
        XCTAssertEqual(decodedLegacyRecord, record)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(decodedLegacyRecord), as: UTF8.self).contains("estimatedCostUSD"))
    }

    func testExplicitProviderClassificationUsesOnlyKnownLeafIDs() throws {
        let profile = APIKeyProviderProfile(type: .gemini)
        let configuration = LLMAssistConfiguration(providerProfileID: profile.id, modelIdentifier: "gemini-3.1-flash-lite", maximumTokens: 512)
        let entry = EntryEvidence(platform: "youtube", entryID: "entry", surface: .feed, evidence: .init(title: "Deck gameplay"))
        let prepared = try ProviderClassificationProtocol.prepare(
            profile: profile,
            configuration: configuration,
            entry: entry,
            allowedLeafTagIDs: ["games", "technology"]
        )
        XCTAssertEqual(prepared.operation, .generateText)
        XCTAssertTrue(prepared.prompt.contains("games"))
        XCTAssertFalse(prepared.prompt.contains("apiKey"))
        XCTAssertEqual(
            try ProviderClassificationProtocol.parseLabelIDs(#"{"labelIDs":["games"]}"#, allowedLeafTagIDs: ["games", "technology"]),
            ["games"]
        )
        XCTAssertThrowsError(
            try ProviderClassificationProtocol.parseLabelIDs(#"{"labelIDs":["unknown"]}"#, allowedLeafTagIDs: ["games", "technology"])
        )
    }

    func testEveryExposedLanguageModelPreparesTestAndClassificationRequests() throws {
        let profiles: [APIKeyProviderProfile] = [
            .init(type: .openAI),
            .init(type: .openAICompatible, customEndpoint: "https://api.deepseek.com/v1"),
            .init(type: .deepSeek),
            .init(type: .gemini),
            .init(type: .anthropic),
            .init(type: .mistral),
            .init(type: .cohere),
            .init(type: .groq),
            .init(type: .openRouter),
            .init(type: .ollama),
            .init(type: .custom, customEndpoint: "https://api.example.com/v1"),
        ]
        let entry = EntryEvidence(platform: "youtube", entryID: "entry", surface: .feed, evidence: .init(title: "Deck gameplay"))
        for profile in profiles {
            let modelIdentifier = profile.type.defaultModelIdentifier.isEmpty ? "test-model" : profile.type.defaultModelIdentifier
            if profile.type.defaultModelIdentifier.isEmpty {
                XCTAssertThrowsError(try ProviderTestProtocol.prepare(profile: profile), profile.type.rawValue)
            } else {
                XCTAssertEqual(try ProviderTestProtocol.prepare(profile: profile).operation, .generateText, profile.type.rawValue)
            }
            XCTAssertEqual(
                try ProviderClassificationProtocol.prepare(
                    profile: profile,
                    configuration: .init(providerProfileID: profile.id, modelIdentifier: modelIdentifier),
                    entry: entry,
                    allowedLeafTagIDs: ["games"]
                ).operation,
                .generateText,
                profile.type.rawValue
            )
        }
    }

    func testPlatformDataProfilesDoNotPrepareLanguageModelRequests() throws {
        let platformTypes: [APIKeyProviderType] = [
            .youtubeData, .twitch, .reddit, .xPlatform, .tikTok,
            .instagramGraph, .facebookGraph,
        ]

        for type in platformTypes {
            let profile = APIKeyProviderProfile(type: type)
            let descriptor = ProviderProtocolRegistry.descriptor(for: type)
            XCTAssertFalse(descriptor.supportsLLMConfiguration, type.rawValue)
            XCTAssertTrue(descriptor.requestFormats.contains(where: { $0.operation == .readPublicContent }), type.rawValue)
            XCTAssertNoThrow(try profile.validate(), type.rawValue)
            XCTAssertThrowsError(try ProviderTestProtocol.prepare(profile: profile), type.rawValue)
        }
    }

    func testEveryLanguageModelBuildsAndContinuesABoundedToolExchange() throws {
        let profiles: [APIKeyProviderProfile] = [
            .init(type: .openAI),
            .init(type: .openAICompatible, customEndpoint: "https://api.example.test/v1"),
            .init(type: .deepSeek),
            .init(type: .gemini),
            .init(type: .anthropic),
            .init(type: .mistral),
            .init(type: .cohere),
            .init(type: .groq),
            .init(type: .openRouter),
            .init(type: .ollama),
            .init(type: .custom, customEndpoint: "https://api.example.test/v1"),
        ]
        let entry = EntryEvidence(platform: "youtube", entryID: "video-id", sourceID: "creator-id", surface: .feed, evidence: .init(title: "Deck gameplay"))
        let platformProfile = APIKeyProviderProfile(id: "youtube-data", type: .youtubeData)

        for profile in profiles {
            let modelIdentifier = profile.type.defaultModelIdentifier.isEmpty ? "test-model" : profile.type.defaultModelIdentifier
            let prepared = try ProviderToolCallingProtocol.prepare(
                profile: profile,
                configuration: .init(providerProfileID: profile.id, modelIdentifier: modelIdentifier),
                entry: entry,
                allowedLeafTagIDs: ["games"],
                toolProfiles: [platformProfile]
            )
            XCTAssertEqual(prepared.toolDefinitions.count, 1, profile.type.rawValue)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: prepared.body) as? [String: Any])
            XCTAssertNotNil(body["tools"], profile.type.rawValue)
            let response = toolCallResponse(format: prepared.plan.bodyFormat, name: prepared.toolDefinitions[0].name)
            let turn = try ProviderToolCallingProtocol.parseResponse(response, format: prepared.plan.bodyFormat)
            XCTAssertEqual(turn.toolCalls.count, 1, profile.type.rawValue)
            let continued = try ProviderToolCallingProtocol.continueRequest(
                prepared: prepared,
                profile: profile,
                configuration: .init(providerProfileID: profile.id, modelIdentifier: modelIdentifier),
                turn: turn,
                results: [.init(id: turn.toolCalls[0].id, name: turn.toolCalls[0].name, content: #"{"ok":true}"#)]
            )
            XCTAssertFalse(continued.body.isEmpty, profile.type.rawValue)
        }
    }

    func testEveryPlatformProfileHasABoundedToolDefinitionAndRoute() throws {
        let types: [APIKeyProviderType] = [
            .youtubeData, .twitch, .reddit, .xPlatform, .tikTok,
            .instagramGraph, .facebookGraph,
        ]
        let entry = EntryEvidence(platform: "youtube", entryID: "at://did:plc:creator/app.bsky.feed.post/post", sourceID: "creator-id", surface: .feed, evidence: .init(title: "Public entry"))
        let profiles = types.map(platformProfile)
        XCTAssertEqual(try ExternalPlatformToolProtocol.definitions(profiles: profiles, entry: entry).count, types.count)

        for profile in profiles {
            let call = ExternalPlatformToolCall(
                id: "call-\(profile.type.rawValue)",
                name: ExternalPlatformToolProtocol.toolName(for: profile),
                arguments: #"{"target":"entry"}"#
            )
            let request = try ExternalPlatformToolProtocol.prepare(profile: profile, entry: entry, call: call)
            XCTAssertEqual(request.plan.method, profile.type == .tikTok ? "POST" : "GET", profile.type.rawValue)
            if profile.type == .tikTok {
                XCTAssertNotNil(request.body)
                XCTAssertEqual(request.plan.bodyFormat, .customJSON)
            }
            XCTAssertNil(URLComponents(url: request.plan.url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "access_token" }), profile.type.rawValue)
        }
    }

    func testPlatformToolResultRedactsTokenLikeFieldsAndCapsPayload() throws {
        let payload = Data(#"{"token":"secret","title":"Kept","nested":{"access_token":"secret","description":"Kept"}}"#.utf8)
        let result = ExternalPlatformToolProtocol.result(data: payload, statusCode: 200, providerType: .youtubeData, target: .entry)
        XCTAssertTrue(result.contains("Kept"))
        XCTAssertFalse(result.contains("secret"))
    }

    func testCatalogAllowsOnlyOneMatchingPlatformProfileForAClassifierLLM() throws {
        let model = APIKeyProviderProfile(id: "llm-tool-model", type: .deepSeek)
        let youtube = APIKeyProviderProfile(id: "provider-tool-youtube", type: .youtubeData)
        var catalog = WorkspaceCatalog.starter()
        catalog.providerProfiles = [model, youtube]
        let tree = try XCTUnwrap(catalog.trees.first)
        let dataset = try XCTUnwrap(catalog.datasets.first)
        catalog.classifierTypes = [.init(
            id: "youtube-type",
            name: "YouTube LLM",
            treeID: tree.id,
            treeRevision: tree.revision,
            datasetID: dataset.id,
            datasetRevision: dataset.revision,
            applicablePlatformID: "youtube",
            llmAssistConfiguration: .init(
                providerProfileID: model.id,
                modelIdentifier: "deepseek-chat",
                externalToolProfileID: youtube.id
            )
        )]
        XCTAssertNoThrow(try catalog.validate())

        catalog.classifierTypes[0].llmAssistConfiguration?.externalToolProfileID = "missing"
        XCTAssertThrowsError(try catalog.validate())

        catalog.classifierTypes[0].llmAssistConfiguration?.externalToolProfileID = nil
        catalog.classifierTypes[0].llmAssistConfiguration?.providerProfileID = youtube.id
        XCTAssertThrowsError(try catalog.validate())
    }

    private func platformProfile(_ type: APIKeyProviderType) -> APIKeyProviderProfile {
        let configuration: [String: String]? = type == .twitch
            ? [ProviderConfigurationField.clientID.rawValue: "client-id"]
            : nil
        return .init(id: "platform-\(type.rawValue)", type: type, protocolConfiguration: configuration)
    }

    private func toolCallResponse(format: ProviderRequestBodyFormat, name: String) -> Data {
        let arguments = #"{"target":"entry"}"#
        let object: [String: Any]
        switch format {
        case .openAIResponses:
            object = ["output": [["type": "function_call", "call_id": "call-1", "name": name, "arguments": arguments]]]
        case .openAIChatCompletions:
            object = ["choices": [["message": ["role": "assistant", "tool_calls": [["id": "call-1", "type": "function", "function": ["name": name, "arguments": arguments]]]]]]]
        case .anthropicMessages:
            object = ["content": [["type": "tool_use", "id": "call-1", "name": name, "input": ["target": "entry"]]]]
        case .geminiGenerateContent, .vertexGenerateContent:
            object = ["candidates": [["content": ["role": "model", "parts": [["functionCall": ["id": "call-1", "name": name, "args": ["target": "entry"]]]]]]]]
        case .cohereChat:
            object = ["message": ["role": "assistant", "tool_calls": [["id": "call-1", "type": "function", "function": ["name": name, "arguments": arguments]]]]]
        case .ollamaChat:
            object = ["message": ["role": "assistant", "tool_calls": [["function": ["name": name, "arguments": ["target": "entry"]]]]]]
        default:
            XCTFail("Unexpected provider format")
            return Data()
        }
        return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
