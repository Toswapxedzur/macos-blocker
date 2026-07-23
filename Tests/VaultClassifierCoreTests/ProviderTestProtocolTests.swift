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
            allowedTagIDs: ["games"]
        )
        XCTAssertEqual(prepared.plan.bodyFormat, .openAIChatCompletions)
        let response = Data(#"{"usage":{"prompt_tokens":1000,"completion_tokens":500},"choices":[{"message":{"content":"OK"}}]}"#.utf8)
        let parsed = try ProviderTestProtocol.parseResponse(response, format: .openAIChatCompletions, operation: .generateText)
        XCTAssertEqual(parsed.content, "OK")
        XCTAssertEqual(parsed.usage, .init(inputTokens: 1_000, outputTokens: 500))
    }

    func testCompatibleProviderTestUsesItsSavedTestModel() throws {
        let profile = APIKeyProviderProfile(
            type: .openAICompatible,
            customEndpoint: "https://api.deepseek.com/v1",
            testModelIdentifier: "deepseek-chat"
        )
        let prepared = try ProviderTestProtocol.prepare(profile: profile)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: prepared.body) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "deepseek-chat")
    }

    func testCustomProviderTestRequiresAnEnteredModel() {
        let profile = APIKeyProviderProfile(
            type: .custom,
            customEndpoint: "https://api.example.test/v1"
        )

        XCTAssertThrowsError(try ProviderTestProtocol.prepare(profile: profile)) { error in
            XCTAssertEqual(error as? ProviderTestProtocolError, .modelRequired)
        }
    }

    func testOllamaTestCanUseAnEnteredModelInsteadOfItsDefault() throws {
        let profile = APIKeyProviderProfile(
            type: .ollama,
            testModelIdentifier: "qwen3:8b"
        )

        let prepared = try ProviderTestProtocol.prepare(profile: profile)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: prepared.body) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "qwen3:8b")
    }

    func testLanguageModelTestsRequireGeneratedTextAndRequestCompleteResponses() throws {
        let profiles: [APIKeyProviderProfile] = [
            .init(type: .openAI),
            .init(type: .openAICompatible, customEndpoint: "https://api.example.test/v1", testModelIdentifier: "test-model"),
            .init(type: .deepSeek),
            .init(type: .gemini),
            .init(type: .anthropic),
            .init(type: .mistral),
            .init(type: .cohere),
            .init(type: .groq),
            .init(type: .openRouter),
            .init(type: .ollama),
            .init(type: .custom, customEndpoint: "https://api.example.test/v1", testModelIdentifier: "test-model"),
        ]

        for profile in profiles {
            let prepared = try ProviderTestProtocol.prepare(profile: profile)
            XCTAssertThrowsError(
                try ProviderTestProtocol.parseResponse(Data("{}".utf8), format: prepared.plan.bodyFormat, operation: prepared.operation),
                profile.type.rawValue
            )
            let parsed = try ProviderTestProtocol.parseResponse(
                testResponse(format: prepared.plan.bodyFormat),
                format: prepared.plan.bodyFormat,
                operation: prepared.operation
            )
            XCTAssertEqual(parsed.content, "OK", profile.type.rawValue)

            if profile.type == .cohere {
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: prepared.body) as? [String: Any])
                XCTAssertEqual(body["stream"] as? Bool, false)
            }
        }
    }

    func testRequestRecordPreservesMetadataWithoutRequestOrResponseBodies() throws {
        let profile = APIKeyProviderProfile(id: "gemini", type: .gemini)
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
            classifierTypeID: "youtube-type",
            outcome: "succeeded"
        )
        var catalog = WorkspaceCatalog.starter()
        catalog.providerProfiles = [profile]
        catalog.providerRequestRecords = [record]
        XCTAssertNoThrow(try catalog.validate())

        let restored = try JSONDecoder().decode(WorkspaceCatalog.self, from: JSONEncoder().encode(catalog))
        XCTAssertEqual(restored.providerRequestRecords, [record])
        let encoded = String(decoding: try JSONEncoder().encode(restored), as: UTF8.self)
        XCTAssertFalse(encoded.contains("apiKey"))
        XCTAssertFalse(encoded.contains("requestContent"))
        XCTAssertFalse(encoded.contains("responseContent"))

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
        let configuration = LLMAssistConfiguration(providerProfileID: profile.id, modelIdentifier: "gemini-3.1-flash-lite", dailyOutputTokenLimit: 512)
        let entry = EntryEvidence(platform: "youtube", entryID: "entry", surface: .feed, evidence: .init(title: "Deck gameplay"))
        let prepared = try ProviderClassificationProtocol.prepare(
            profile: profile,
            configuration: configuration,
            entry: entry,
            allowedTagIDs: ["games", "technology"]
        )
        XCTAssertEqual(prepared.operation, .generateText)
        XCTAssertTrue(prepared.prompt.contains("games"))
        XCTAssertFalse(prepared.prompt.contains("apiKey"))
        XCTAssertEqual(
            try ProviderClassificationProtocol.parseLabelIDs(#"{"labelIDs":["games"]}"#, allowedTagIDs: ["games", "technology"]),
            ["games"]
        )
        XCTAssertThrowsError(
            try ProviderClassificationProtocol.parseLabelIDs(#"{"labelIDs":["unknown"]}"#, allowedTagIDs: ["games", "technology"])
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
            if profile.type.defaultModelIdentifier.isEmpty || profile.type == .custom {
                XCTAssertThrowsError(try ProviderTestProtocol.prepare(profile: profile), profile.type.rawValue)
            } else {
                XCTAssertEqual(try ProviderTestProtocol.prepare(profile: profile).operation, .generateText, profile.type.rawValue)
            }
            let classification = try ProviderClassificationProtocol.prepare(
                profile: profile,
                configuration: .init(providerProfileID: profile.id, modelIdentifier: modelIdentifier),
                entry: entry,
                allowedTagIDs: ["games"]
            )
            XCTAssertEqual(classification.operation, .generateText, profile.type.rawValue)
            if profile.type == .cohere {
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: classification.body) as? [String: Any])
                XCTAssertEqual(body["stream"] as? Bool, false)
            }
        }
    }

    func testPlatformDataProfilesPrepareBoundedConnectionTestsWithoutLanguageModels() throws {
        let platformTypes: [APIKeyProviderType] = [
            .youtubeData, .twitch, .reddit, .xPlatform, .tikTok,
            .instagramGraph, .facebookGraph,
        ]

        for type in platformTypes {
            let profile = platformProfile(type)
            let descriptor = ProviderProtocolRegistry.descriptor(for: type)
            XCTAssertFalse(descriptor.supportsLLMConfiguration, type.rawValue)
            XCTAssertTrue(descriptor.requestFormats.contains(where: { $0.operation == .readPublicContent }), type.rawValue)
            XCTAssertNoThrow(try profile.validate(), type.rawValue)
            let prepared = try ProviderTestProtocol.prepare(profile: profile)
            XCTAssertEqual(prepared.operation, .readPublicContent, type.rawValue)
            XCTAssertFalse(prepared.plan.url.absoluteString.contains("entry"), type.rawValue)
            XCTAssertEqual(
                try ProviderTestProtocol.parseResponse(Data("{}".utf8), format: prepared.plan.bodyFormat, operation: prepared.operation).usage,
                .init(inputTokens: nil, outputTokens: nil),
                type.rawValue
            )
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
                allowedTagIDs: ["games"],
                toolProfiles: [platformProfile]
            )
            XCTAssertEqual(prepared.toolDefinitions.count, 1, profile.type.rawValue)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: prepared.body) as? [String: Any])
            XCTAssertNotNil(body["tools"], profile.type.rawValue)
            if profile.type == .cohere {
                XCTAssertEqual(body["stream"] as? Bool, false)
            }
            let response = toolCallResponse(format: prepared.plan.bodyFormat, name: prepared.toolDefinitions[0].name)
            let turn = try ProviderToolCallingProtocol.parseResponse(response, format: prepared.plan.bodyFormat)
            XCTAssertEqual(turn.toolCalls.count, 1, profile.type.rawValue)
            let continued = try ProviderToolCallingProtocol.continueRequest(
                prepared: prepared,
                profile: profile,
                configuration: .init(providerProfileID: profile.id, modelIdentifier: modelIdentifier),
                turn: turn,
                results: [.init(id: turn.toolCalls[0].id, name: turn.toolCalls[0].name, content: #"{"ok":true}"#)],
                maximumOutputTokens: ProviderToolCallingProtocol.maximumOutputTokens
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

    func testPlatformConnectionTestsUseProviderSpecificHealthRoutes() throws {
        let profiles = [
            platformProfile(.youtubeData), platformProfile(.twitch), platformProfile(.reddit),
            platformProfile(.xPlatform), platformProfile(.tikTok), platformProfile(.instagramGraph),
            platformProfile(.facebookGraph),
        ]
        for profile in profiles {
            let request = try ExternalPlatformToolProtocol.prepareConnectionTest(profile: profile)
            XCTAssertFalse(request.plan.url.absoluteString.contains("contentID"), profile.type.rawValue)
            XCTAssertEqual(request.plan.method, profile.type == .tikTok ? "POST" : "GET", profile.type.rawValue)
            XCTAssertEqual(request.plan.bodyFormat, profile.type == .tikTok ? .customJSON : .queryOnly, profile.type.rawValue)
            XCTAssertNil(URLComponents(url: request.plan.url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "access_token" }), profile.type.rawValue)
        }
        let twitch = try ExternalPlatformToolProtocol.prepareConnectionTest(profile: platformProfile(.twitch))
        XCTAssertEqual(twitch.plan.headers["Client-Id"], "client-id")
        let tikTok = try ExternalPlatformToolProtocol.prepareConnectionTest(profile: platformProfile(.tikTok))
        let body = try XCTUnwrap(tikTok.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        XCTAssertEqual(body["max_count"] as? Int, 1)
    }

    func testPlatformToolResultRedactsTokenLikeFieldsAndCapsPayload() throws {
        let payload = Data(#"{"token":"secret","title":"Kept","nested":{"access_token":"secret","description":"Kept"}}"#.utf8)
        let result = ExternalPlatformToolProtocol.result(data: payload, statusCode: 200, providerType: .youtubeData, target: .entry)
        XCTAssertTrue(result.contains("Kept"))
        XCTAssertFalse(result.contains("secret"))
    }

    func testPlatformCreatorAvatarExtractionUsesOnlyKnownResponseFields() {
        XCTAssertTrue(ExternalPlatformToolProtocol.supportsCreatorAvatarLookup(providerType: .youtubeData))
        XCTAssertFalse(ExternalPlatformToolProtocol.supportsCreatorAvatarLookup(providerType: .tikTok))
        XCTAssertEqual(
            ExternalPlatformToolProtocol.creatorAvatarURL(
                data: Data(#"{"items":[{"snippet":{"thumbnails":{"high":{"url":"https://yt3.googleusercontent.com/avatar"}}}}]}"#.utf8),
                providerType: .youtubeData
            ),
            "https://yt3.googleusercontent.com/avatar"
        )
        XCTAssertEqual(
            ExternalPlatformToolProtocol.creatorAvatarURL(
                data: Data(#"{"data":[{"profile_image_url":"https://static-cdn.jtvnw.net/avatar.png"}]}"#.utf8),
                providerType: .twitch
            ),
            "https://static-cdn.jtvnw.net/avatar.png"
        )
        XCTAssertNil(ExternalPlatformToolProtocol.creatorAvatarURL(
            data: Data(#"{"unexpected":"https://example.invalid/avatar.png"}"#.utf8),
            providerType: .youtubeData
        ))
    }

    func testCatalogAllowsAutomaticMatchingPlatformToolForAClassifierLLM() throws {
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
                externalToolEnabled: true
            )
        )]
        XCTAssertNoThrow(try catalog.validate())

        catalog.providerProfiles = [model]
        XCTAssertNoThrow(try catalog.validate())

        catalog.classifierTypes[0].llmAssistConfiguration?.providerProfileID = youtube.id
        XCTAssertThrowsError(try catalog.validate())
    }

    func testModelCatalogUsesVaultServiceForFixedProvidersAndDirectEndpointsForCustomProviders() throws {
        let openAI = APIKeyProviderProfile(type: .openAI)
        let localVault = try VaultServiceEndpoint(baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:8080")))
        let plan = try ProviderModelCatalogProtocol.prepare(profile: openAI, vaultService: localVault)
        XCTAssertEqual(plan.method, "GET")
        XCTAssertEqual(plan.url.absoluteString, "http://127.0.0.1:8080/api/vault-classifier/llm-model-catalog/openAI")
        XCTAssertEqual(plan.authentication, .none)
        XCTAssertEqual(
            try ProviderModelCatalogProtocol.parse(Data(#"{"data":[{"id":"gpt-5"},{"id":"gpt-4.1"}]}"#.utf8), providerType: .openAI),
            ["gpt-4.1", "gpt-5"]
        )
        XCTAssertEqual(
            try ProviderModelCatalogProtocol.parse(Data(#"{"models":[{"name":"models/gemini-usable","supportedGenerationMethods":["generateContent"]},{"name":"models/embedding-only","supportedGenerationMethods":["embedContent"]}]}"#.utf8), providerType: .gemini),
            ["gemini-usable"]
        )
        let custom = try ProviderModelCatalogProtocol.prepare(profile: .init(type: .custom, customEndpoint: "https://example.test"), vaultService: localVault)
        XCTAssertEqual(custom.url.absoluteString, "https://example.test/models")
        let compatible = try ProviderModelCatalogProtocol.prepare(profile: .init(type: .openAICompatible, customEndpoint: "https://example.test/v1"), vaultService: localVault)
        XCTAssertEqual(compatible.url.absoluteString, "https://example.test/v1/models")
        let ollama = try ProviderModelCatalogProtocol.prepare(profile: .init(type: .ollama))
        XCTAssertEqual(ollama.url.absoluteString, "http://127.0.0.1:11434/api/tags")
    }

    func testClassificationAllowsConfiguredGenericTagsWhenTheyAreInThePromptVocabulary() throws {
        let profile = APIKeyProviderProfile(type: .gemini)
        let configuration = LLMAssistConfiguration(
            providerProfileID: profile.id,
            modelIdentifier: "gemini-3.1-flash-lite",
            maximumTagCount: 2,
            restrictToLeafTags: false
        )
        let labels = try ProviderClassificationProtocol.parseLabelIDs(
            #"{"labelIDs":["gaming"]}"#,
            allowedTagIDs: ["gaming", "gaming.minecraft"],
            maximumTagCount: configuration.maximumTagCount
        )
        XCTAssertEqual(labels, ["gaming"])
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

    private func testResponse(format: ProviderRequestBodyFormat) -> Data {
        let object: [String: Any]
        switch format {
        case .openAIResponses:
            object = ["output": [["content": [["text": "OK"]]]]]
        case .openAIChatCompletions:
            object = ["choices": [["message": ["content": "OK"]]]]
        case .anthropicMessages:
            object = ["content": [["text": "OK"]]]
        case .geminiGenerateContent, .vertexGenerateContent:
            object = ["candidates": [["content": ["parts": [["text": "OK"]]]]]]
        case .cohereChat:
            object = ["message": ["content": [["text": "OK"]]]]
        case .ollamaChat:
            object = ["message": ["content": "OK"]]
        default:
            XCTFail("Unexpected provider format")
            return Data()
        }
        return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
