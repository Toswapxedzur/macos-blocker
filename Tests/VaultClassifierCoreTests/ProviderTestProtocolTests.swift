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
        let requestBody = try XCTUnwrap(JSONSerialization.jsonObject(with: prepared.body) as? [String: Any])
        XCTAssertEqual(requestBody["max_tokens"] as? Int, LLMAssistConfiguration.defaultMaximumOutputTokensPerRequest)
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
            responseShape: "JSON object; top-level fields: choices, usage",
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

    func testResponseShapeDescribesOnlySafeStructure() {
        let response = Data(#"{"choices":[{"message":{"content":"private model response","reasoning_content":"private reasoning","role":"assistant"}}],"usage":{"completion_tokens":2}}"#.utf8)

        let shape = ProviderTestProtocol.responseShape(for: response)

        XCTAssertEqual(
            shape,
            "JSON object; top-level fields: choices, usage; choices: 1; first choice fields: message; message fields: content, reasoning_content, role; content: non-empty string"
        )
        XCTAssertFalse(shape.contains("private model response"))
        XCTAssertFalse(shape.contains("private reasoning"))
    }

    func testResponseShapeRecognizesANonJSONResponseWithoutRetainingIt() {
        let shape = ProviderTestProtocol.responseShape(for: Data("provider response body".utf8))
        XCTAssertEqual(shape, "non-JSON response")
        XCTAssertFalse(shape.contains("provider response body"))
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

    func testClassificationRequestIncludesTagDescriptionsAndExtraDirection() throws {
        let profile = APIKeyProviderProfile(type: .deepSeek)
        let configuration = LLMAssistConfiguration(
            providerProfileID: profile.id,
            modelIdentifier: "deepseek-chat",
            maximumOutputTokensPerRequest: 4_096,
            extraDirection: "Prefer a creator's recurring topic."
        )
        let prepared = try ProviderClassificationProtocol.prepare(
            profile: profile,
            configuration: configuration,
            entry: .init(platform: "youtube", entryID: "entry", surface: .feed, evidence: .init(title: "Deck gameplay")),
            allowedTagIDs: ["games"],
            tagDescriptions: ["games": "Tag name: Games\nDescription: Video games and game culture."]
        )
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: prepared.body) as? [String: Any])
        XCTAssertEqual(body["max_tokens"] as? Int, 4_096)
        let prompt = try XCTUnwrap((body["messages"] as? [[String: Any]])?.first?["content"] as? String)
        XCTAssertTrue(prompt.contains("Tag name: Games"))
        XCTAssertTrue(prompt.contains("Video games and game culture."))
        XCTAssertTrue(prompt.contains("Prefer a creator's recurring topic."))
        XCTAssertTrue(prompt.contains("Return exactly one JSON object"))
    }

    func testProviderNativeWebSearchUsesEachDocumentedDirectRequestGrammar() throws {
        let openAI = APIKeyProviderProfile(id: "openai", type: .openAI)
        let openAIConfiguration = LLMAssistConfiguration(
            providerProfileID: openAI.id,
            modelIdentifier: "gpt-4.1-mini",
            webSearchEnabled: true
        )
        let request = try ProviderClassificationProtocol.prepare(
            profile: openAI,
            configuration: openAIConfiguration,
            entry: .init(platform: "bilibili", entryID: "entry", surface: .page, evidence: .init(title: "Creator: RetroTech")),
            allowedTagIDs: ["technology"]
        )
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        XCTAssertEqual((body["tools"] as? [[String: String]])?.first?["type"], "web_search")
        XCTAssertTrue(request.prompt.contains("Use web search only when the provided evidence is insufficient"))

        let openAIWithSeparateGeminiResearch = try ProviderClassificationProtocol.prepare(
            profile: openAI,
            configuration: .init(
                providerProfileID: openAI.id,
                modelIdentifier: "gpt-4.1-mini",
                webSearchEnabled: true,
                webResearchProviderProfileID: "gemini-research",
                webResearchModelIdentifier: "gemini-3.1-flash-lite"
            ),
            entry: .init(platform: "youtube", entryID: "entry", surface: .page, evidence: .init(title: "Creator: RetroTech")),
            allowedTagIDs: ["technology"]
        )
        let openAIWithSeparateResearchBody = try XCTUnwrap(
            JSONSerialization.jsonObject(with: openAIWithSeparateGeminiResearch.body) as? [String: Any]
        )
        XCTAssertNil(openAIWithSeparateResearchBody["tools"])

        let gemini = APIKeyProviderProfile(id: "gemini", type: .gemini)
        let geminiConfiguration = LLMAssistConfiguration(
            providerProfileID: gemini.id,
            modelIdentifier: "gemini-3.1-flash-lite",
            webSearchEnabled: true
        )
        let geminiRequest = try ProviderClassificationProtocol.prepare(
            profile: gemini,
            configuration: geminiConfiguration,
            entry: .init(platform: "bilibili", entryID: "entry", surface: .page, evidence: .init(title: "Creator: RetroTech")),
            allowedTagIDs: ["technology"]
        )
        let geminiBody = try XCTUnwrap(JSONSerialization.jsonObject(with: geminiRequest.body) as? [String: Any])
        XCTAssertEqual(((geminiBody["tools"] as? [[String: [String: Any]]])?.first?["google_search"] as? [String: Any])?.isEmpty, true)

        let anthropic = APIKeyProviderProfile(id: "anthropic", type: .anthropic)
        let anthropicRequest = try ProviderClassificationProtocol.prepare(
            profile: anthropic,
            configuration: .init(providerProfileID: anthropic.id, modelIdentifier: "claude-sonnet-4-5", webSearchEnabled: true),
            entry: .init(platform: "bilibili", entryID: "entry", surface: .page, evidence: .init(title: "Creator: RetroTech")),
            allowedTagIDs: ["technology"]
        )
        let anthropicBody = try XCTUnwrap(JSONSerialization.jsonObject(with: anthropicRequest.body) as? [String: Any])
        XCTAssertEqual((anthropicBody["tools"] as? [[String: Any]])?.first?["type"] as? String, "web_search_20250305")
        XCTAssertEqual((anthropicBody["tools"] as? [[String: Any]])?.first?["max_uses"] as? Int, 3)

        let deepSeek = APIKeyProviderProfile(id: "deepseek", type: .deepSeek)
        let deepSeekRequest = try ProviderClassificationProtocol.prepare(
            profile: deepSeek,
            configuration: .init(providerProfileID: deepSeek.id, modelIdentifier: "deepseek-chat", webSearchEnabled: true),
            entry: .init(platform: "bilibili", entryID: "entry", surface: .page, evidence: .init(title: "Creator: RetroTech")),
            allowedTagIDs: ["technology"]
        )
        let deepSeekBody = try XCTUnwrap(JSONSerialization.jsonObject(with: deepSeekRequest.body) as? [String: Any])
        XCTAssertNil(deepSeekBody["tools"])
    }

    func testSeparateWebResearchUsesOnlyADeclaredHostedSearchProvider() throws {
        let entry = EntryEvidence(
            platform: "youtube",
            entryID: "entry",
            sourceID: "creator",
            surface: .page,
            evidence: .init(title: "Creator: RetroTech", text: "Laptop restoration clips")
        )
        let openAI = APIKeyProviderProfile(type: .openAI)
        let openAIRequest = try ProviderWebResearchProtocol.prepare(
            profile: openAI,
            modelIdentifier: "gpt-4.1-mini",
            entry: entry
        )
        let openAIBody = try XCTUnwrap(JSONSerialization.jsonObject(with: openAIRequest.body) as? [String: Any])
        XCTAssertEqual((openAIBody["tools"] as? [[String: String]])?.first?["type"], "web_search")
        XCTAssertTrue(openAIRequest.prompt.contains("not individual videos"))
        XCTAssertTrue(openAIRequest.prompt.contains("Use hosted web search only when that evidence is insufficient"))

        let gemini = APIKeyProviderProfile(type: .gemini)
        let geminiRequest = try ProviderWebResearchProtocol.prepare(
            profile: gemini,
            modelIdentifier: "gemini-3.1-flash-lite",
            entry: entry
        )
        let geminiBody = try XCTUnwrap(JSONSerialization.jsonObject(with: geminiRequest.body) as? [String: Any])
        XCTAssertNotNil(geminiBody["tools"])

        XCTAssertThrowsError(try ProviderWebResearchProtocol.prepare(
            profile: .init(type: .ollama),
            modelIdentifier: "llama3.3",
            entry: entry
        )) { error in
            XCTAssertEqual(error as? ProviderWebResearchProtocolError, .unsupportedProvider)
        }
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

    func testOfficialPlatformEvidenceAlwaysUsesTheLocalCreatorOrRepresentativeEntry() throws {
        let youtube = platformProfile(.youtubeData)
        let handle = try OfficialPlatformEvidenceProtocol.prepare(
            profile: youtube,
            entry: .init(
                platform: "youtube",
                entryID: "youtube:video:dQw4w9WgXcQ",
                sourceID: "youtube:handle:@GoogleDevelopers",
                surface: .page,
                evidence: .init(title: "Creator")
            )
        )
        XCTAssertEqual(handle.target, .creator)
        let handleQuery = URLComponents(url: handle.plan.url, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(handleQuery?.first(where: { $0.name == "forHandle" })?.value, "@GoogleDevelopers")
        XCTAssertNil(handleQuery?.first(where: { $0.name == "id" }))

        let channel = try OfficialPlatformEvidenceProtocol.prepare(
            profile: youtube,
            entry: .init(
                platform: "youtube",
                entryID: "youtube:video:dQw4w9WgXcQ",
                sourceID: "youtube:channel:UC123",
                surface: .page,
                evidence: .init(title: "Creator")
            )
        )
        XCTAssertEqual(URLComponents(url: channel.plan.url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value, "UC123")

        let tikTok = try OfficialPlatformEvidenceProtocol.prepare(
            profile: platformProfile(.tikTok),
            entry: .init(
                platform: "tiktok",
                entryID: "tiktok:video:123",
                sourceID: "tiktok:creator:456",
                surface: .page,
                evidence: .init(title: "Creator")
            )
        )
        XCTAssertEqual(tikTok.target, .representativeEntry)
        XCTAssertEqual(tikTok.plan.method, "POST")
        let body = try XCTUnwrap(tikTok.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        XCTAssertEqual(((body["filters"] as? [String: Any])?["video_ids"] as? [String])?.first, "123")

        let x = try OfficialPlatformEvidenceProtocol.prepare(
            profile: platformProfile(.xPlatform),
            entry: .init(
                platform: "twitter",
                entryID: "twitter:status:123",
                sourceID: "twitter:account:XDevelopers",
                surface: .page,
                evidence: .init(title: "Creator")
            )
        )
        XCTAssertTrue(x.plan.url.path.hasSuffix("/users/by/username/XDevelopers"))
    }

    func testPlatformConnectionTestsUseProviderSpecificHealthRoutes() throws {
        let profiles = [
            platformProfile(.youtubeData), platformProfile(.twitch), platformProfile(.reddit),
            platformProfile(.xPlatform), platformProfile(.tikTok), platformProfile(.instagramGraph),
            platformProfile(.facebookGraph),
        ]
        for profile in profiles {
            let request = try OfficialPlatformEvidenceProtocol.prepareConnectionTest(profile: profile)
            XCTAssertFalse(request.plan.url.absoluteString.contains("contentID"), profile.type.rawValue)
            XCTAssertEqual(request.plan.method, profile.type == .tikTok ? "POST" : "GET", profile.type.rawValue)
            XCTAssertEqual(request.plan.bodyFormat, profile.type == .tikTok ? .customJSON : .queryOnly, profile.type.rawValue)
            XCTAssertNil(URLComponents(url: request.plan.url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "access_token" }), profile.type.rawValue)
        }
        let twitch = try OfficialPlatformEvidenceProtocol.prepareConnectionTest(profile: platformProfile(.twitch))
        XCTAssertEqual(twitch.plan.headers["Client-Id"], "client-id")
        let tikTok = try OfficialPlatformEvidenceProtocol.prepareConnectionTest(profile: platformProfile(.tikTok))
        let body = try XCTUnwrap(tikTok.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        XCTAssertEqual(body["max_count"] as? Int, 1)
    }

    func testOfficialPlatformEvidenceRedactsTokenLikeFieldsAndCapsPayload() throws {
        let payload = Data(#"{"token":"secret","title":"Kept","nested":{"access_token":"secret","description":"Kept"}}"#.utf8)
        let result = try OfficialPlatformEvidenceProtocol.boundedEvidence(data: payload, providerType: .youtubeData, target: .creator)
        XCTAssertTrue(result.contains("Kept"))
        XCTAssertFalse(result.contains("secret"))
    }

    func testCatalogAllowsAClassifierLLMWithAnOfficialPlatformAPIProfile() throws {
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
                modelIdentifier: "deepseek-chat"
            )
        )]
        XCTAssertNoThrow(try catalog.validate())

        catalog.providerProfiles = [model]
        XCTAssertNoThrow(try catalog.validate())

        catalog.classifierTypes[0].llmAssistConfiguration?.providerProfileID = youtube.id
        XCTAssertThrowsError(try catalog.validate())
    }

    func testModelCatalogProbesEachProviderAtItsOwnModelsEndpoint() throws {
        func plan(_ type: APIKeyProviderType, endpoint: String? = nil) throws -> ProviderRequestPlan {
            try ProviderModelCatalogProtocol.prepare(profile: .init(type: type, customEndpoint: endpoint))
        }

        let openAI = try plan(.openAI)
        XCTAssertEqual(openAI.method, "GET")
        XCTAssertEqual(openAI.url.absoluteString, "https://api.openai.com/v1/models")
        XCTAssertEqual(openAI.authentication, .bearerToken)
        XCTAssertEqual(openAI.requiredCredentialFields, [.apiKey])
        XCTAssertEqual(try plan(.deepSeek).url.absoluteString, "https://api.deepseek.com/v1/models")
        XCTAssertEqual(try plan(.gemini).url.absoluteString, "https://generativelanguage.googleapis.com/v1beta/models?pageSize=256")
        XCTAssertEqual(try plan(.anthropic).url.absoluteString, "https://api.anthropic.com/v1/models?limit=256")
        XCTAssertEqual(try plan(.mistral).url.absoluteString, "https://api.mistral.ai/v1/models")
        XCTAssertEqual(try plan(.cohere).url.absoluteString, "https://api.cohere.com/v1/models?page_size=256")
        XCTAssertEqual(try plan(.groq).url.absoluteString, "https://api.groq.com/openai/v1/models")
        XCTAssertEqual(try plan(.openRouter).url.absoluteString, "https://openrouter.ai/api/v1/models")
        XCTAssertEqual(
            try ProviderModelCatalogProtocol.parse(Data(#"{"data":[{"id":"gpt-5"},{"id":"gpt-4.1"}]}"#.utf8), providerType: .openAI),
            ["gpt-4.1", "gpt-5"]
        )
        XCTAssertEqual(
            try ProviderModelCatalogProtocol.parse(Data(#"{"models":[{"name":"models/gemini-usable","supportedGenerationMethods":["generateContent"]},{"name":"models/embedding-only","supportedGenerationMethods":["embedContent"]}]}"#.utf8), providerType: .gemini),
            ["gemini-usable"]
        )
        XCTAssertEqual(
            try ProviderModelCatalogProtocol.parse(Data(#"[{"id":"mistral-small"}]"#.utf8), providerType: .mistral),
            ["mistral-small"]
        )
        let custom = try plan(.custom, endpoint: "https://example.test")
        XCTAssertEqual(custom.url.absoluteString, "https://example.test/models")
        let compatible = try plan(.openAICompatible, endpoint: "https://example.test/v1")
        XCTAssertEqual(compatible.url.absoluteString, "https://example.test/v1/models")
        let ollama = try plan(.ollama)
        XCTAssertEqual(ollama.url.absoluteString, "http://127.0.0.1:11434/api/tags")
        XCTAssertEqual(ollama.authentication, .none)
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
