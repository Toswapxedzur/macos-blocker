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
        XCTAssertEqual(parsed.usage, .init(tokenCount: 9))
    }

    func testAggregateUsageIncludesProviderReportedReasoningAndToolTokens() throws {
        let gemini = Data(#"""
        {
          "usageMetadata": {
            "promptTokenCount": 7,
            "candidatesTokenCount": 2,
            "thoughtsTokenCount": 3,
            "toolUsePromptTokenCount": 4
          }
        }
        """#.utf8)
        XCTAssertEqual(
            try ProviderTestProtocol.usage(from: gemini, format: .geminiGenerateContent),
            .init(tokenCount: 16)
        )

        let openAI = Data(#"{"usage":{"prompt_tokens":100,"completion_tokens":30,"completion_tokens_details":{"reasoning_tokens":20}}}"#.utf8)
        XCTAssertEqual(
            try ProviderTestProtocol.usage(from: openAI, format: .openAIChatCompletions),
            .init(tokenCount: 130)
        )

        let anthropic = Data(#"{"usage":{"input_tokens":10,"cache_creation_input_tokens":20,"cache_read_input_tokens":30,"output_tokens":5}}"#.utf8)
        XCTAssertEqual(
            try ProviderTestProtocol.usage(from: anthropic, format: .anthropicMessages),
            .init(tokenCount: 65)
        )

        let incomplete = Data(#"{"usage":{"prompt_tokens":100}}"#.utf8)
        XCTAssertEqual(
            try ProviderTestProtocol.usage(from: incomplete, format: .openAIChatCompletions),
            .init(tokenCount: nil)
        )
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
            allowedTagIDs: ["games"],
            tagDefinitions: readableTagDefinitions(["games"])
        )
        XCTAssertEqual(prepared.plan.bodyFormat, .openAIChatCompletions)
        let requestBody = try XCTUnwrap(JSONSerialization.jsonObject(with: prepared.body) as? [String: Any])
        XCTAssertEqual(requestBody["max_tokens"] as? Int, LLMAssistConfiguration.defaultMaximumOutputTokensPerRequest)
        let response = Data(#"{"usage":{"prompt_tokens":1000,"completion_tokens":500},"choices":[{"message":{"content":"OK"}}]}"#.utf8)
        let parsed = try ProviderTestProtocol.parseResponse(response, format: .openAIChatCompletions, operation: .generateText)
        XCTAssertEqual(parsed.content, "OK")
        XCTAssertEqual(parsed.usage, .init(tokenCount: 1_500))
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
            tokenCount: 4,
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
        XCTAssertTrue(encoded.contains("\"tokenCount\":4"))
        XCTAssertFalse(encoded.contains("inputTokens"))
        XCTAssertFalse(encoded.contains("outputTokens"))

        var legacyRecord = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        legacyRecord["estimatedCostUSD"] = 0.0001
        let decodedLegacyRecord = try JSONDecoder().decode(
            ProviderRequestRecord.self,
            from: JSONSerialization.data(withJSONObject: legacyRecord)
        )
        XCTAssertEqual(decodedLegacyRecord, record)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(decodedLegacyRecord), as: UTF8.self).contains("estimatedCostUSD"))

        legacyRecord.removeValue(forKey: "tokenCount")
        legacyRecord["inputTokens"] = 3
        legacyRecord["outputTokens"] = 1
        let migratedTokenRecord = try JSONDecoder().decode(
            ProviderRequestRecord.self,
            from: JSONSerialization.data(withJSONObject: legacyRecord)
        )
        XCTAssertEqual(migratedTokenRecord.tokenCount, 4)
        let migratedEncoding = String(decoding: try JSONEncoder().encode(migratedTokenRecord), as: UTF8.self)
        XCTAssertTrue(migratedEncoding.contains("\"tokenCount\":4"))
        XCTAssertFalse(migratedEncoding.contains("inputTokens"))
        XCTAssertFalse(migratedEncoding.contains("outputTokens"))

        let legacyUsage = Data(#"{"id":"usage","provider":"openAI","model":"gpt","inputTokens":10,"outputTokens":5,"status":"failed","createdAtMilliseconds":1}"#.utf8)
        let migratedUsage = try JSONDecoder().decode(TokenUsageRecord.self, from: legacyUsage)
        XCTAssertEqual(migratedUsage.tokenCount, 15)
        XCTAssertEqual(migratedUsage.status, "failed")
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
        let configuration = LLMAssistConfiguration(providerProfileID: profile.id, modelIdentifier: "gemini-3.1-flash-lite", dailyTokenLimit: 512)
        let entry = EntryEvidence(platform: "youtube", entryID: "entry", surface: .feed, evidence: .init(title: "Deck gameplay"))
        let prepared = try ProviderClassificationProtocol.prepare(
            profile: profile,
            configuration: configuration,
            entry: entry,
            allowedTagIDs: ["games", "technology"],
            tagDefinitions: readableTagDefinitions(["games", "technology"])
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

    func testClassificationRequestIncludesReadableTagDefinitionsAndExtraDirection() throws {
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
            tagDefinitions: [
                "games": .init(name: "Games", description: "Video games and game culture.")
            ]
        )
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: prepared.body) as? [String: Any])
        XCTAssertEqual(body["max_tokens"] as? Int, 4_096)
        let prompt = try XCTUnwrap((body["messages"] as? [[String: Any]])?.first?["content"] as? String)
        XCTAssertTrue(prompt.contains(#""name":"Games""#))
        XCTAssertTrue(prompt.contains("Video games and game culture."))
        XCTAssertTrue(prompt.contains("Prefer a creator's recurring topic."))
        XCTAssertTrue(prompt.contains("Return exactly one JSON object"))

        XCTAssertThrowsError(try ProviderClassificationProtocol.prepare(
            profile: profile,
            configuration: configuration,
            entry: .init(
                platform: "youtube",
                entryID: "entry",
                surface: .feed,
                evidence: .init(title: "Deck gameplay")
            ),
            allowedTagIDs: ["games"]
        ))
    }

    func testCreatorPromptExplicitlyAssociatesObservedVideosWithTheNamedCreator() throws {
        let profile = APIKeyProviderProfile(type: .deepSeek)
        let prepared = try ProviderClassificationProtocol.prepare(
            profile: profile,
            configuration: .init(
                providerProfileID: profile.id,
                modelIdentifier: "deepseek-chat"
            ),
            entry: .init(
                platform: "youtube",
                entryID: "youtube:video:final",
                sourceID: "youtube:handle:@442oons",
                surface: .page,
                evidence: .init(
                    title: "442oons",
                    text: #"[{"entryID":"final","entryType":"video","title":"SPAIN WIN THE WORLD CUP🏆 (Espana 1-0 Argentina Final Highlights 26)"}]"#,
                    metadata: [
                        "classificationTarget": .string("creator"),
                        "creatorName": .string("442oons"),
                        "classificationSourceKind": .string("creator"),
                        "browserObservedContentFormat": .string("typed-json-v1"),
                    ]
                )
            ),
            allowedTagIDs: ["football-animation"],
            tagDefinitions: [
                "football-animation": .init(
                    name: "Football animation",
                    description: "Animated recurring football content."
                )
            ]
        )

        XCTAssertTrue(prepared.prompt.contains(#""targetType" : "creator""#))
        XCTAssertTrue(prepared.prompt.contains(#""name" : "442oons""#))
        XCTAssertTrue(prepared.prompt.contains(#""identifier" : "youtube:handle:@442oons""#))
        XCTAssertTrue(prepared.prompt.contains("browserObservedContentItems"))
        XCTAssertTrue(prepared.prompt.contains(#""entryType" : "video""#))
        XCTAssertTrue(prepared.prompt.contains(#""targetSourceKind" : "creator""#))
        XCTAssertTrue(prepared.prompt.contains("typed public-content record observed from the named creator"))
        XCTAssertTrue(prepared.prompt.contains("SPAIN WIN THE WORLD CUP"))
        XCTAssertTrue(prepared.prompt.contains(#""name":"Football animation""#))
    }

    func testWebSearchModesUseNativeOrAttachedRequestGrammarsExplicitly() throws {
        let openAI = APIKeyProviderProfile(id: "openai", type: .openAI)
        let openAIConfiguration = LLMAssistConfiguration(
            providerProfileID: openAI.id,
            modelIdentifier: "gpt-4.1-mini",
            webSearchMode: .providerNative
        )
        let request = try ProviderClassificationProtocol.prepare(
            profile: openAI,
            configuration: openAIConfiguration,
            entry: .init(platform: "bilibili", entryID: "entry", surface: .page, evidence: .init(title: "Creator: RetroTech")),
            allowedTagIDs: ["technology"],
            tagDefinitions: readableTagDefinitions(["technology"])
        )
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        XCTAssertEqual((body["tools"] as? [[String: String]])?.first?["type"], "web_search")
        XCTAssertTrue(request.prompt.contains("Use it only when the supplied evidence is insufficient"))

        let gemini = APIKeyProviderProfile(id: "gemini", type: .gemini)
        let geminiConfiguration = LLMAssistConfiguration(
            providerProfileID: gemini.id,
            modelIdentifier: "gemini-3.1-flash-lite",
            webSearchMode: .providerNative
        )
        let geminiRequest = try ProviderClassificationProtocol.prepare(
            profile: gemini,
            configuration: geminiConfiguration,
            entry: .init(platform: "bilibili", entryID: "entry", surface: .page, evidence: .init(title: "Creator: RetroTech")),
            allowedTagIDs: ["technology"],
            tagDefinitions: readableTagDefinitions(["technology"])
        )
        let geminiBody = try XCTUnwrap(JSONSerialization.jsonObject(with: geminiRequest.body) as? [String: Any])
        XCTAssertEqual(((geminiBody["tools"] as? [[String: [String: Any]]])?.first?["google_search"] as? [String: Any])?.isEmpty, true)

        let anthropic = APIKeyProviderProfile(id: "anthropic", type: .anthropic)
        let anthropicRequest = try ProviderClassificationProtocol.prepare(
            profile: anthropic,
            configuration: .init(providerProfileID: anthropic.id, modelIdentifier: "claude-sonnet-4-5", webSearchMode: .providerNative),
            entry: .init(platform: "bilibili", entryID: "entry", surface: .page, evidence: .init(title: "Creator: RetroTech")),
            allowedTagIDs: ["technology"],
            tagDefinitions: readableTagDefinitions(["technology"])
        )
        let anthropicBody = try XCTUnwrap(JSONSerialization.jsonObject(with: anthropicRequest.body) as? [String: Any])
        XCTAssertEqual((anthropicBody["tools"] as? [[String: Any]])?.first?["type"] as? String, "web_search_20250305")
        XCTAssertEqual((anthropicBody["tools"] as? [[String: Any]])?.first?["max_uses"] as? Int, 3)

        let deepSeek = APIKeyProviderProfile(id: "deepseek", type: .deepSeek)
        let deepSeekRequest = try ProviderClassificationProtocol.prepare(
            profile: deepSeek,
            configuration: .init(
                providerProfileID: deepSeek.id,
                modelIdentifier: "deepseek-chat",
                webSearchMode: .attached,
                webSearchProviderProfileID: "search"
            ),
            entry: .init(platform: "bilibili", entryID: "entry", surface: .page, evidence: .init(title: "Creator: RetroTech")),
            allowedTagIDs: ["technology"],
            tagDefinitions: readableTagDefinitions(["technology"])
        )
        let deepSeekBody = try XCTUnwrap(JSONSerialization.jsonObject(with: deepSeekRequest.body) as? [String: Any])
        XCTAssertEqual(
            ((((deepSeekBody["tools"] as? [[String: Any]])?.first?["function"] as? [String: Any])?["name"] as? String)),
            ProviderClassificationProtocol.attachedWebSearchToolName
        )
        XCTAssertTrue(deepSeekRequest.prompt.contains("Use it only when the supplied evidence is insufficient"))
    }

    func testAttachedSearchToolCallsContinueTheSameModelConversationAcrossEveryGrammar() throws {
        let fixtures: [(APIKeyProviderProfile, String, Data)] = [
            (
                .init(id: "openai", type: .openAI),
                "gpt-5",
                Data(#"{"output":[{"type":"function_call","call_id":"call-1","name":"web_search","arguments":"{\"query\":\"RetroTech creator\"}"}],"usage":{"input_tokens":10,"output_tokens":3}}"#.utf8)
            ),
            (
                .init(id: "deepseek", type: .deepSeek),
                "deepseek-chat",
                Data(#"{"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"call-1","type":"function","function":{"name":"web_search","arguments":"{\"query\":\"RetroTech creator\"}"}}]}}],"usage":{"prompt_tokens":10,"completion_tokens":3}}"#.utf8)
            ),
            (
                .init(id: "anthropic", type: .anthropic),
                "claude-sonnet-4-5",
                Data(#"{"content":[{"type":"tool_use","id":"call-1","name":"web_search","input":{"query":"RetroTech creator"}}],"usage":{"input_tokens":10,"output_tokens":3}}"#.utf8)
            ),
            (
                .init(id: "gemini", type: .gemini),
                "gemini-3.1-flash-lite",
                Data(#"{"candidates":[{"content":{"role":"model","parts":[{"functionCall":{"name":"web_search","args":{"query":"RetroTech creator"}}}]}}],"usageMetadata":{"promptTokenCount":10,"candidatesTokenCount":3}}"#.utf8)
            ),
            (
                .init(id: "cohere", type: .cohere),
                "command-a-03-2025",
                Data(#"{"message":{"role":"assistant","tool_plan":"Search when unsure.","tool_calls":[{"id":"call-1","type":"function","function":{"name":"web_search","arguments":"{\"query\":\"RetroTech creator\"}"}}]},"usage":{"tokens":{"input_tokens":10,"output_tokens":3}}}"#.utf8)
            ),
            (
                .init(id: "ollama", type: .ollama),
                "qwen3",
                Data(#"{"message":{"role":"assistant","content":"","tool_calls":[{"type":"function","function":{"name":"web_search","arguments":{"query":"RetroTech creator"}}}]},"prompt_eval_count":10,"eval_count":3}"#.utf8)
            ),
        ]

        for (profile, model, firstResponse) in fixtures {
            let request = try ProviderClassificationProtocol.prepare(
                profile: profile,
                configuration: .init(
                    providerProfileID: profile.id,
                    modelIdentifier: model,
                    webSearchMode: .attached,
                    webSearchProviderProfileID: "search"
                ),
                entry: .init(
                    platform: "youtube",
                    entryID: "entry",
                    surface: .page,
                    evidence: .init(title: "Creator: RetroTech")
                ),
                allowedTagIDs: ["technology"],
                tagDefinitions: readableTagDefinitions(["technology"])
            )
            let call = try XCTUnwrap(ProviderClassificationProtocol.attachedWebSearchCall(
                from: firstResponse,
                format: request.plan.bodyFormat
            ), profile.type.rawValue)
            XCTAssertEqual(call.query, "RetroTech creator", profile.type.rawValue)
            let continuation = try ProviderClassificationProtocol.attachedWebSearchContinuation(
                initialRequest: request,
                firstResponse: firstResponse,
                call: call,
                toolOutput: "bounded public results",
                maximumOutputTokens: 2_048
            )
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: continuation.body) as? [String: Any])
            XCTAssertNotNil(body["tools"], profile.type.rawValue)
            XCTAssertTrue(
                String(decoding: continuation.body, as: UTF8.self).contains("bounded public results"),
                profile.type.rawValue
            )
            XCTAssertEqual(
                try ProviderTestProtocol.usage(from: firstResponse, format: request.plan.bodyFormat).tokenCount,
                13,
                profile.type.rawValue
            )
        }
    }

    func testAttachedSearchRejectsMultipleOrUnknownToolCalls() throws {
        let multiple = Data(#"{"choices":[{"message":{"tool_calls":[{"id":"one","function":{"name":"web_search","arguments":"{\"query\":\"one\"}"}},{"id":"two","function":{"name":"web_search","arguments":"{\"query\":\"two\"}"}}]}}]}"#.utf8)
        XCTAssertThrowsError(
            try ProviderClassificationProtocol.attachedWebSearchCall(
                from: multiple,
                format: .openAIChatCompletions
            )
        )

        let unknown = Data(#"{"choices":[{"message":{"tool_calls":[{"id":"one","function":{"name":"read_url","arguments":"{\"query\":\"example\"}"}}]}}]}"#.utf8)
        XCTAssertThrowsError(
            try ProviderClassificationProtocol.attachedWebSearchCall(
                from: unknown,
                format: .openAIChatCompletions
            )
        )

        let custom = APIKeyProviderProfile(
            type: .custom,
            customEndpoint: "https://example.test/v1"
        )
        XCTAssertThrowsError(try ProviderClassificationProtocol.prepare(
            profile: custom,
            configuration: .init(
                providerProfileID: custom.id,
                modelIdentifier: "unknown-model",
                webSearchMode: .attached,
                webSearchProviderProfileID: "search"
            ),
            entry: .init(
                platform: "youtube",
                entryID: "entry",
                surface: .page,
                evidence: .init(title: "Creator")
            ),
            allowedTagIDs: ["technology"],
            tagDefinitions: readableTagDefinitions(["technology"])
        ))
    }

    func testRawSearchProvidersPrepareAndParseBoundedResults() throws {
        let entry = EntryEvidence(
            platform: "youtube",
            entryID: "entry",
            sourceID: "creator",
            surface: .page,
            evidence: .init(title: "Creator: RetroTech", text: "Laptop restoration clips")
        )
        let serper = APIKeyProviderProfile(type: .serper, credential: "serper-key")
        let serperRequest = try RawWebSearchProtocol.prepare(profile: serper, entry: entry)
        XCTAssertEqual(serperRequest.operation, .searchWeb)
        XCTAssertEqual(serperRequest.plan.url.absoluteString, "https://google.serper.dev/search")
        XCTAssertEqual(serperRequest.plan.authenticationHeader, "X-API-KEY")
        let serperBody = try XCTUnwrap(JSONSerialization.jsonObject(with: serperRequest.body) as? [String: Any])
        XCTAssertEqual(serperBody["num"] as? Int, RawWebSearchProtocol.maximumResults)
        XCTAssertTrue((serperBody["q"] as? String)?.contains("RetroTech") == true)
        let serperResults = try RawWebSearchProtocol.parseResults(
            Data(#"{"organic":[{"title":"RetroTech channel","link":"https://example.com/creator#about","snippet":"Repairs old computers."}]}"#.utf8),
            format: .serperSearch
        )
        XCTAssertEqual(serperResults, [
            .init(title: "RetroTech channel", url: "https://example.com/creator", snippet: "Repairs old computers."),
        ])

        let you = APIKeyProviderProfile(type: .youSearch, credential: "you-key")
        let youRequest = try RawWebSearchProtocol.prepare(profile: you, entry: entry)
        XCTAssertEqual(youRequest.operation, .searchWeb)
        XCTAssertEqual(youRequest.plan.url.absoluteString, "https://api.you.com/v1/search")
        XCTAssertEqual(youRequest.plan.authenticationHeader, "X-API-Key")
        let youBody = try XCTUnwrap(JSONSerialization.jsonObject(with: youRequest.body) as? [String: Any])
        XCTAssertEqual(youBody["count"] as? Int, RawWebSearchProtocol.maximumResults)
        XCTAssertEqual(youBody["safesearch"] as? String, "moderate")
        let youResults = try RawWebSearchProtocol.parseResults(
            Data(#"{"results":{"web":[{"title":"RetroTech profile","url":"https://example.org/retro","description":"Creator profile","snippets":["Retro repair","Vintage PCs"]}],"news":[]}}"#.utf8),
            format: .youSearch
        )
        XCTAssertEqual(youResults, [
            .init(title: "RetroTech profile", url: "https://example.org/retro", snippet: "Retro repair Vintage PCs"),
        ])
        let evidence = try RawWebSearchProtocol.boundedEvidence(from: serperResults + youResults)
        XCTAssertTrue(evidence.contains("untrusted evidence"))
        XCTAssertLessThanOrEqual(evidence.count, RawWebSearchProtocol.maximumEvidenceCharacters)

        XCTAssertThrowsError(try RawWebSearchProtocol.prepare(
            profile: .init(type: .ollama),
            entry: entry
        )) { error in
            XCTAssertEqual(error as? RawWebSearchProtocolError, .unsupportedProvider)
        }
    }

    func testRawSearchProfilesPrepareBoundedConnectionTestsWithoutModels() throws {
        let fixtures: [(APIKeyProviderType, Data, ProviderRequestBodyFormat)] = [
            (.serper, Data(#"{"organic":[{"title":"Example Domain","link":"https://example.com","snippet":"Example"}]}"#.utf8), .serperSearch),
            (.youSearch, Data(#"{"results":{"web":[{"title":"Example Domain","url":"https://example.com","description":"Example"}]}}"#.utf8), .youSearch),
        ]

        for (type, response, format) in fixtures {
            let profile = APIKeyProviderProfile(type: type, credential: "test-key")
            let descriptor = ProviderProtocolRegistry.descriptor(for: type)
            XCTAssertFalse(descriptor.supportsLLMConfiguration, type.rawValue)
            XCTAssertTrue(descriptor.supportsRawWebSearch, type.rawValue)
            let prepared = try ProviderTestProtocol.prepare(profile: profile)
            XCTAssertEqual(prepared.operation, .searchWeb, type.rawValue)
            XCTAssertEqual(prepared.plan.bodyFormat, format, type.rawValue)
            XCTAssertEqual(
                try ProviderTestProtocol.parseResponse(response, format: format, operation: .searchWeb).content,
                "Web search test completed.",
                type.rawValue
            )
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
                allowedTagIDs: ["games"],
                tagDefinitions: readableTagDefinitions(["games"])
            )
            XCTAssertEqual(classification.operation, .generateText, profile.type.rawValue)
            if profile.type == .cohere {
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: classification.body) as? [String: Any])
                XCTAssertEqual(body["stream"] as? Bool, false)
            }
        }
    }

    func testEveryKnownProviderUsesItsStrongestSafeNativeClassificationOutputConstraint() throws {
        let profiles: [APIKeyProviderProfile] = [
            .init(type: .openAI),
            .init(type: .openAICompatible, customEndpoint: "https://api.example.com/v1"),
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
        let entry = EntryEvidence(
            platform: "youtube",
            entryID: "entry",
            surface: .feed,
            evidence: .init(title: "Deck gameplay")
        )

        for profile in profiles {
            let model = profile.type.defaultModelIdentifier.isEmpty
                ? "test-model"
                : profile.type.defaultModelIdentifier
            let prepared = try ProviderClassificationProtocol.prepare(
                profile: profile,
                configuration: .init(providerProfileID: profile.id, modelIdentifier: model),
                entry: entry,
                allowedTagIDs: ["games"],
                tagDefinitions: readableTagDefinitions(["games"])
            )
            let body = try XCTUnwrap(
                JSONSerialization.jsonObject(with: prepared.body) as? [String: Any],
                profile.type.rawValue
            )

            switch profile.type {
            case .openAI:
                let text = try XCTUnwrap(body["text"] as? [String: Any])
                let format = try XCTUnwrap(text["format"] as? [String: Any])
                XCTAssertEqual(format["type"] as? String, "json_schema")
                XCTAssertEqual(format["name"] as? String, "vault_classifier_labels")
                XCTAssertEqual(format["strict"] as? Bool, true)
                assertLabelResponseSchema(format["schema"], provider: profile.type)
            case .deepSeek, .groq:
                let format = try XCTUnwrap(body["response_format"] as? [String: Any])
                XCTAssertEqual(format["type"] as? String, "json_object")
            case .gemini:
                let generationConfig = try XCTUnwrap(body["generationConfig"] as? [String: Any])
                let responseFormat = try XCTUnwrap(generationConfig["responseFormat"] as? [String: Any])
                let text = try XCTUnwrap(responseFormat["text"] as? [String: Any])
                XCTAssertEqual(text["mimeType"] as? String, "application/json")
                assertLabelResponseSchema(text["schema"], provider: profile.type)
            case .anthropic:
                let outputConfig = try XCTUnwrap(body["output_config"] as? [String: Any])
                let format = try XCTUnwrap(outputConfig["format"] as? [String: Any])
                XCTAssertEqual(format["type"] as? String, "json_schema")
                assertLabelResponseSchema(format["schema"], provider: profile.type)
            case .mistral, .openRouter:
                let format = try XCTUnwrap(body["response_format"] as? [String: Any])
                XCTAssertEqual(format["type"] as? String, "json_schema")
                let jsonSchema = try XCTUnwrap(format["json_schema"] as? [String: Any])
                XCTAssertEqual(jsonSchema["name"] as? String, "vault_classifier_labels")
                XCTAssertEqual(jsonSchema["strict"] as? Bool, profile.type == .openRouter ? true : nil)
                assertLabelResponseSchema(jsonSchema["schema"], provider: profile.type)
                if profile.type == .openRouter {
                    XCTAssertEqual((body["provider"] as? [String: Any])?["require_parameters"] as? Bool, true)
                }
            case .cohere:
                let format = try XCTUnwrap(body["response_format"] as? [String: Any])
                XCTAssertEqual(format["type"] as? String, "json_object")
                assertLabelResponseSchema(format["schema"], provider: profile.type)
            case .ollama:
                assertLabelResponseSchema(body["format"], provider: profile.type)
            case .openAICompatible, .custom:
                XCTAssertNil(body["response_format"])
                XCTAssertNil(body["format"])
            default:
                XCTFail("Unexpected non-LLM profile \(profile.type.rawValue)")
            }
        }
    }

    func testNativeOutputConstraintsNeverDisplaceSelectedSearchTools() throws {
        let fixtures: [(APIKeyProviderType, LLMWebSearchMode)] = [
            (.openAI, .providerNative),
            (.gemini, .providerNative),
            (.anthropic, .providerNative),
            (.deepSeek, .attached),
            (.gemini, .attached),
            (.anthropic, .attached),
            (.mistral, .attached),
            (.cohere, .attached),
            (.groq, .attached),
            (.openRouter, .attached),
            (.ollama, .attached),
        ]

        for (type, mode) in fixtures {
            let profile = APIKeyProviderProfile(type: type)
            let prepared = try ProviderClassificationProtocol.prepare(
                profile: profile,
                configuration: .init(
                    providerProfileID: profile.id,
                    modelIdentifier: type.defaultModelIdentifier,
                    webSearchMode: mode,
                    webSearchProviderProfileID: mode == .attached ? "search" : nil
                ),
                entry: .init(
                    platform: "youtube",
                    entryID: "entry",
                    surface: .page,
                    evidence: .init(title: "Creator")
                ),
                allowedTagIDs: ["games"],
                tagDefinitions: readableTagDefinitions(["games"])
            )
            let body = try XCTUnwrap(
                JSONSerialization.jsonObject(with: prepared.body) as? [String: Any],
                type.rawValue
            )
            XCTAssertNotNil(body["tools"], type.rawValue)

            switch type {
            case .openAI:
                XCTAssertNotNil(body["text"], type.rawValue)
            case .deepSeek, .mistral, .openRouter:
                XCTAssertNotNil(body["response_format"], type.rawValue)
            case .anthropic:
                XCTAssertEqual(body["output_config"] == nil, mode == .providerNative, type.rawValue)
            case .gemini:
                let generationConfig = try XCTUnwrap(body["generationConfig"] as? [String: Any])
                XCTAssertNil(generationConfig["responseFormat"], type.rawValue)
            case .cohere, .groq:
                XCTAssertNil(body["response_format"], type.rawValue)
            case .ollama:
                XCTAssertNil(body["format"], type.rawValue)
            default:
                XCTFail("Unexpected provider \(type.rawValue)")
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
                .init(tokenCount: nil),
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
                evidence: .init(
                    title: "Creator",
                    text: #"[{"entryID":"tiktok:video:123"},{"entryID":"tiktok:video:789"}]"#,
                    metadata: ["browserObservedContentFormat": .string("typed-json-v1")]
                )
            ),
            maximumResults: 2
        )
        XCTAssertEqual(tikTok.target, .representativeEntry)
        XCTAssertEqual(tikTok.plan.method, "POST")
        let body = try XCTUnwrap(tikTok.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        XCTAssertEqual((body["filters"] as? [String: Any])?["video_ids"] as? [String], ["123", "789"])

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
        let xQuery = URLComponents(url: x.plan.url, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertTrue(xQuery?.first(where: { $0.name == "user.fields" })?.value?.contains("profile_banner_url") == true)
    }

    func testOfficialPlatformAdaptersRequestRecentCreatorContentWithoutYouTubeOnlyGates() throws {
        let fixtures: [(APIKeyProviderType, Data, String)] = [
            (.twitch, Data(#"{"data":[{"id":"42"}]}"#.utf8), "/videos"),
            (.reddit, Data(#"{"data":{"name":"swift"}}"#.utf8), "/user/swift/submitted"),
            (.xPlatform, Data(#"{"data":{"id":"2244994945"}}"#.utf8), "/users/2244994945/tweets"),
            (.instagramGraph, Data(#"{"id":"17841400000000000"}"#.utf8), "/17841400000000000/media"),
            (.facebookGraph, Data(#"{"id":"20531316728"}"#.utf8), "/20531316728/published_posts"),
        ]

        for (type, creatorData, suffix) in fixtures {
            let request = try XCTUnwrap(
                OfficialPlatformEvidenceProtocol.prepareCreatorContentRequest(
                    profile: platformProfile(type),
                    creatorData: creatorData,
                    maximumResults: 25
                )
            )
            XCTAssertTrue(request.plan.url.path.hasSuffix(suffix), type.rawValue)
            XCTAssertEqual(request.target, .creator, type.rawValue)
            XCTAssertEqual(request.providerType, type, type.rawValue)
            if type == .xPlatform {
                let query = URLComponents(url: request.plan.url, resolvingAgainstBaseURL: false)?.queryItems
                XCTAssertTrue(query?.first(where: { $0.name == "tweet.fields" })?.value?.contains("note_tweet") == true)
                XCTAssertTrue(query?.first(where: { $0.name == "media.fields" })?.value?.contains("variants") == true)
            }
        }
    }

    func testGenericOfficialEvidenceKeepsPublicContentAndResponseContextAsValidBoundedJSON() throws {
        let creatorData = Data(#"{"data":{"id":"42","name":"Creator","description":"Public profile"}}"#.utf8)
        let contentData = Data(#"""
        {
          "data": [
            {"id":"one","text":"First post","public_metrics":{"like_count":10}},
            {"id":"two","text":"Second post","public_metrics":{"like_count":20}}
          ],
          "includes": {"media":[{"media_key":"key","type":"photo","width":640}]}
        }
        """#.utf8)
        let evidence = try OfficialPlatformEvidenceProtocol.boundedCreatorEvidence(
            creatorData: creatorData,
            contentData: contentData,
            providerType: .xPlatform,
            maximumContentCount: 2
        )
        XCTAssertLessThanOrEqual(evidence.count, OfficialPlatformEvidenceProtocol.maximumEvidenceCharacters)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(evidence.utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["requestedContentCount"] as? Int, 2)
        XCTAssertEqual(object["returnedContentCount"] as? Int, 2)
        XCTAssertEqual((object["recentContentItems"] as? [[String: Any]])?.count, 2)
        XCTAssertNotNil((object["contentContext"] as? [String: Any])?["includes"])

        let tikTok = try OfficialPlatformEvidenceProtocol.boundedEvidence(
            data: Data(#"{"data":{"videos":[{"id":"123","title":"One"},{"id":"789","title":"Two"}]},"error":{"code":"ok"}}"#.utf8),
            providerType: .tikTok,
            target: .representativeEntry,
            maximumContentCount: 2
        )
        let tikTokObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(tikTok.utf8)) as? [String: Any]
        )
        XCTAssertEqual((tikTokObject["recentContentItems"] as? [[String: Any]])?.count, 2)
    }

    func testGenericOfficialEvidenceCompactsVerboseFieldsBeforeDroppingContentRecords() throws {
        let creatorData = try JSONSerialization.data(withJSONObject: [
            "data": [
                "id": "42",
                "name": "Creator",
                "description": String(repeating: "profile ", count: 2_000),
            ],
        ])
        let records: [[String: Any]] = (0..<25).map { index in
            [
                "id": "post-\(index)",
                "text": String(repeating: "classification context ", count: 120),
                "public_metrics": ["like_count": index, "view_count": index * 10],
            ]
        }
        let contentData = try JSONSerialization.data(withJSONObject: [
            "data": records,
            "includes": ["description": String(repeating: "context ", count: 2_000)],
        ])

        let evidence = try OfficialPlatformEvidenceProtocol.boundedCreatorEvidence(
            creatorData: creatorData,
            contentData: contentData,
            providerType: .xPlatform,
            maximumContentCount: records.count
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(evidence.utf8)) as? [String: Any]
        )

        XCTAssertLessThanOrEqual(evidence.count, OfficialPlatformEvidenceProtocol.maximumEvidenceCharacters)
        XCTAssertEqual(object["returnedContentCount"] as? Int, records.count)
        XCTAssertEqual((object["recentContentItems"] as? [[String: Any]])?.count, records.count)
    }

    func testYouTubeOfficialEvidenceFetchesRecentFullVideoRecordsInUploadOrder() throws {
        let profile = platformProfile(.youtubeData)
        let channelData = Data(#"""
        {
          "items": [{
            "id": "UC442",
            "snippet": {"title": "442oons", "description": "Animated football comedy"},
            "contentDetails": {"relatedPlaylists": {"uploads": "UU442"}},
            "statistics": {"subscriberCount": "5000000", "videoCount": "600"}
          }]
        }
        """#.utf8)
        let uploads = try OfficialPlatformEvidenceProtocol.prepareYouTubeUploadsRequest(
            profile: profile,
            channelData: channelData,
            maximumResults: 2
        )
        XCTAssertTrue(uploads.plan.url.path.hasSuffix("/playlistItems"))
        let uploadsQuery = URLComponents(url: uploads.plan.url, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(uploadsQuery?.first(where: { $0.name == "playlistId" })?.value, "UU442")
        XCTAssertEqual(uploadsQuery?.first(where: { $0.name == "maxResults" })?.value, "2")

        let playlistData = Data(#"""
        {"items":[
          {"contentDetails":{"videoId":"new-video"}},
          {"contentDetails":{"videoId":"old-video"}}
        ]}
        """#.utf8)
        let videos = try XCTUnwrap(OfficialPlatformEvidenceProtocol.prepareYouTubeVideoRecordsRequest(
            profile: profile,
            playlistData: playlistData,
            maximumResults: 2
        ))
        XCTAssertTrue(videos.plan.url.path.hasSuffix("/videos"))
        let videosQuery = URLComponents(url: videos.plan.url, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(videosQuery?.first(where: { $0.name == "id" })?.value, "new-video,old-video")
        XCTAssertTrue(videosQuery?.first(where: { $0.name == "part" })?.value?.contains("statistics") == true)
        XCTAssertTrue(videosQuery?.first(where: { $0.name == "part" })?.value?.contains("topicDetails") == true)
        XCTAssertTrue(videosQuery?.first(where: { $0.name == "part" })?.value?.contains("brandPartner") == true)

        let videoData = Data(#"""
        {"items":[
          {
            "id":"old-video",
            "snippet":{"title":"Older football animation","publishedAt":"2026-06-01T00:00:00Z"},
            "contentDetails":{"duration":"PT1M"},
            "statistics":{"viewCount":"200","likeCount":"20"}
          },
          {
            "id":"new-video",
            "snippet":{"title":"SPAIN WIN THE WORLD CUP","publishedAt":"2026-07-25T00:00:00Z"},
            "contentDetails":{"duration":"PT2M"},
            "statistics":{"viewCount":"1000","likeCount":"100","commentCount":"10"}
          }
        ]}
        """#.utf8)
        let evidence = try OfficialPlatformEvidenceProtocol.boundedYouTubeCreatorEvidence(
            channelData: channelData,
            playlistData: playlistData,
            videoData: videoData,
            maximumVideoCount: 2
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(evidence.utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["requestedContentCount"] as? Int, 2)
        XCTAssertEqual(object["returnedContentCount"] as? Int, 2)
        let recentContentItems = try XCTUnwrap(object["recentContentItems"] as? [[String: Any]])
        XCTAssertEqual(recentContentItems.map { $0["id"] as? String }, ["new-video", "old-video"])
        XCTAssertEqual((recentContentItems[0]["snippet"] as? [String: Any])?["title"] as? String, "SPAIN WIN THE WORLD CUP")
        XCTAssertEqual((recentContentItems[0]["statistics"] as? [String: Any])?["viewCount"] as? String, "1000")
    }

    func testYouTubeOfficialEvidenceKeepsAllFiftyConfiguredVideoCoresWithinThePromptBound() throws {
        let profile = platformProfile(.youtubeData)
        let channelData = try JSONSerialization.data(withJSONObject: [
            "items": [[
                "id": "UCBOUND",
                "snippet": ["title": "Bounded creator", "description": String(repeating: "c", count: 5_000)],
                "contentDetails": ["relatedPlaylists": ["uploads": "UUBOUND"]],
                "statistics": ["videoCount": "50"],
            ]]
        ])
        let identifiers = (0..<50).map { "video_\($0)" }
        let playlistData = try JSONSerialization.data(withJSONObject: [
            "items": identifiers.map { ["contentDetails": ["videoId": $0]] }
        ])
        let videoData = try JSONSerialization.data(withJSONObject: [
            "items": identifiers.reversed().map { identifier in
                [
                    "id": identifier,
                    "snippet": [
                        "title": "A bounded title for \(identifier)",
                        "publishedAt": "2026-07-25T00:00:00Z",
                        "description": String(repeating: "d", count: 5_000),
                        "tags": (0..<20).map { "tag-\($0)" },
                    ],
                    "contentDetails": ["duration": "PT2M"],
                    "statistics": ["viewCount": "1000", "likeCount": "100", "commentCount": "10"],
                ] as [String: Any]
            }
        ])

        _ = try OfficialPlatformEvidenceProtocol.prepareYouTubeUploadsRequest(
            profile: profile,
            channelData: channelData,
            maximumResults: 50
        )
        let evidence = try OfficialPlatformEvidenceProtocol.boundedYouTubeCreatorEvidence(
            channelData: channelData,
            playlistData: playlistData,
            videoData: videoData,
            maximumVideoCount: 50
        )

        XCTAssertLessThanOrEqual(evidence.count, OfficialPlatformEvidenceProtocol.maximumEvidenceCharacters)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(evidence.utf8)) as? [String: Any]
        )
        let recentContentItems = try XCTUnwrap(object["recentContentItems"] as? [[String: Any]])
        XCTAssertEqual(recentContentItems.count, 50)
        XCTAssertEqual(recentContentItems.first?["id"] as? String, "video_0")
        XCTAssertEqual(recentContentItems.last?["id"] as? String, "video_49")
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
        let payload = Data(#"{"token":"secret","apiKey":"secret","title":"Kept","nested":{"access_token":"secret","clientSecret":"secret","description":"Kept"}}"#.utf8)
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
        catalog.bindings = [
            .init(id: "youtube", name: "YouTube", treeID: tree.id, datasetID: dataset.id)
        ]
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
        XCTAssertEqual(try plan(.cohere).url.absoluteString, "https://api.cohere.com/v1/models?page_size=256&endpoint=chat")
        XCTAssertEqual(try plan(.groq).url.absoluteString, "https://api.groq.com/openai/v1/models")
        XCTAssertEqual(try plan(.openRouter).url.absoluteString, "https://openrouter.ai/api/v1/models")
        let openAIModels = try ProviderModelCatalogProtocol.parse(
            Data(#"{"data":[{"id":"gpt-5"},{"id":"gpt-4.1"},{"id":"text-embedding-3-large"}]}"#.utf8),
            providerType: .openAI
        )
        XCTAssertEqual(openAIModels.map(\.identifier), ["gpt-4.1", "gpt-5", "text-embedding-3-large"])
        XCTAssertTrue(openAIModels.allSatisfy { $0.supportsTools == nil })

        let geminiModels = try ProviderModelCatalogProtocol.parse(
            Data(#"{"models":[{"name":"models/gemini-usable","supportedGenerationMethods":["generateContent"]},{"name":"models/embedding-only","supportedGenerationMethods":["embedContent"]}]}"#.utf8),
            providerType: .gemini
        )
        XCTAssertEqual(geminiModels.map(\.identifier), ["gemini-usable"])

        let mistralUnknown = try ProviderModelCatalogProtocol.parse(
            Data(#"[{"id":"mistral-small"}]"#.utf8),
            providerType: .mistral
        )
        XCTAssertEqual(mistralUnknown.map(\.identifier), ["mistral-small"])
        XCTAssertNil(mistralUnknown.first?.supportsTools)
        XCTAssertEqual(mistralUnknown.first?.supportsNativeWebSearch, false)

        let mistralModels = try ProviderModelCatalogProtocol.parse(
            Data(#"[{"id":"mistral-tools","capabilities":{"completion_chat":true,"function_calling":true}},{"id":"mistral-plain","capabilities":{"completion_chat":true,"function_calling":false}}]"#.utf8),
            providerType: .mistral
        )
        XCTAssertEqual(mistralModels.map(\.identifier), ["mistral-plain", "mistral-tools"])
        XCTAssertEqual(mistralModels.first(where: { $0.identifier == "mistral-plain" })?.supportsTools, false)
        XCTAssertEqual(mistralModels.first(where: { $0.identifier == "mistral-tools" })?.supportsTools, true)

        let routerModels = try ProviderModelCatalogProtocol.parse(
            Data(#"{"data":[{"id":"router-tools","supported_parameters":["tools","max_tokens"]},{"id":"router-plain","supported_parameters":["max_tokens"]}]}"#.utf8),
            providerType: .openRouter
        )
        XCTAssertEqual(routerModels.map(\.identifier), ["router-plain", "router-tools"])
        XCTAssertEqual(routerModels.first(where: { $0.identifier == "router-plain" })?.supportsTools, false)
        XCTAssertEqual(routerModels.first(where: { $0.identifier == "router-tools" })?.supportsTools, true)

        let groqModels = try ProviderModelCatalogProtocol.parse(
            Data(#"{"data":[{"id":"llama-3.3-70b-versatile"},{"id":"groq/compound"}]}"#.utf8),
            providerType: .groq
        )
        XCTAssertEqual(groqModels.map(\.identifier), ["groq/compound", "llama-3.3-70b-versatile"])
        XCTAssertTrue(groqModels.allSatisfy { $0.supportsTools == nil })
        let custom = try plan(.custom, endpoint: "https://example.test")
        XCTAssertEqual(custom.url.absoluteString, "https://example.test/models")
        let compatible = try plan(.openAICompatible, endpoint: "https://example.test/v1")
        XCTAssertEqual(compatible.url.absoluteString, "https://example.test/v1/models")
        let ollama = try plan(.ollama)
        XCTAssertEqual(ollama.url.absoluteString, "http://127.0.0.1:11434/api/tags")
        XCTAssertEqual(ollama.authentication, .none)
        let ollamaCapability = try ProviderModelCatalogProtocol.prepareOllamaToolCapabilityProbe(
            profile: .init(type: .ollama),
            modelIdentifier: "qwen3"
        )
        XCTAssertEqual(ollamaCapability.plan.url.absoluteString, "http://127.0.0.1:11434/api/show")
        XCTAssertEqual(
            ProviderModelCatalogProtocol.ollamaModelSupportsTools(
                Data(#"{"capabilities":["completion","tools"]}"#.utf8)
            ),
            true
        )
        XCTAssertEqual(
            ProviderModelCatalogProtocol.ollamaModelSupportsTools(
                Data(#"{"capabilities":["completion"]}"#.utf8)
            ),
            false
        )
        XCTAssertNil(ProviderModelCatalogProtocol.ollamaModelSupportsTools(
            Data(#"{"details":{"family":"qwen3"}}"#.utf8)
        ))
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

    func testClassificationAcceptsOneCompleteJSONFenceAndAnExplicitNoTagAnswer() throws {
        XCTAssertEqual(
            try ProviderClassificationProtocol.parseLabelIDs(
                "```json\n{\"labelIDs\":[\"gaming\"]}\n```",
                allowedTagIDs: ["gaming"]
            ),
            ["gaming"]
        )
        XCTAssertEqual(
            try ProviderClassificationProtocol.parseLabelIDs(
                "```\n{\"labelIDs\":[]}\n```",
                allowedTagIDs: ["gaming"]
            ),
            []
        )
        XCTAssertThrowsError(try ProviderClassificationProtocol.parseLabelIDs(
            "Here is the result:\n```json\n{\"labelIDs\":[\"gaming\"]}\n```",
            allowedTagIDs: ["gaming"]
        ))
    }

    private func assertLabelResponseSchema(
        _ value: Any?,
        provider: APIKeyProviderType,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let schema = value as? [String: Any] else {
            XCTFail("Missing label schema for \(provider.rawValue)", file: file, line: line)
            return
        }
        XCTAssertEqual(schema["type"] as? String, "object", provider.rawValue, file: file, line: line)
        XCTAssertEqual(schema["required"] as? [String], ["labelIDs"], provider.rawValue, file: file, line: line)
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false, provider.rawValue, file: file, line: line)
        let properties = schema["properties"] as? [String: Any]
        let labels = properties?["labelIDs"] as? [String: Any]
        XCTAssertEqual(labels?["type"] as? String, "array", provider.rawValue, file: file, line: line)
        XCTAssertEqual(
            (labels?["items"] as? [String: Any])?["type"] as? String,
            "string",
            provider.rawValue,
            file: file,
            line: line
        )
    }

    private func readableTagDefinitions(
        _ identifiers: [String]
    ) -> [String: ProviderClassificationTagDefinition] {
        Dictionary(uniqueKeysWithValues: identifiers.map { identifier in
            (identifier, .init(name: identifier.capitalized))
        })
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
