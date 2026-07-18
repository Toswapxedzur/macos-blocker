import XCTest
@testable import VaultClassifierCore

final class ProviderTestProtocolTests: XCTestCase {
    func testGeminiTestUsesTheFixedBoundedPromptAndParsesUsage() throws {
        let profile = APIKeyProviderProfile(type: .gemini, maximumTokens: 4)
        let prepared = try ProviderTestProtocol.prepare(profile: profile)

        XCTAssertEqual(prepared.operation, .generateText)
        XCTAssertEqual(prepared.plan.url.absoluteString, "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-lite:generateContent")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: prepared.body) as? [String: Any])
        XCTAssertEqual((((body["contents"] as? [[String: Any]])?.first?["parts"] as? [[String: Any]])?.first?["text"] as? String), ProviderTestProtocol.prompt)
        XCTAssertEqual((body["generationConfig"] as? [String: Any])?["maxOutputTokens"] as? Int, 4)

        let response = Data(#"{"usageMetadata":{"promptTokenCount":7,"candidatesTokenCount":2},"candidates":[{"content":{"parts":[{"text":"OK"}]}}]}"#.utf8)
        let parsed = try ProviderTestProtocol.parseResponse(response, format: .geminiGenerateContent, operation: .generateText)
        XCTAssertEqual(parsed.content, "OK")
        XCTAssertEqual(parsed.usage, .init(inputTokens: 7, outputTokens: 2))
    }

    func testOpenAIStyleTestParsesUsageAndCalculatesOnlyConfiguredCost() throws {
        var profile = APIKeyProviderProfile(
            type: .openAICompatible,
            modelIdentifier: "deepseek-chat",
            customEndpoint: "https://api.deepseek.com/v1",
            inputCostUSDPerMillion: 0.28,
            outputCostUSDPerMillion: 0.42
        )
        let prepared = try ProviderTestProtocol.prepare(profile: profile)
        XCTAssertEqual(prepared.plan.bodyFormat, .openAIChatCompletions)
        let response = Data(#"{"usage":{"prompt_tokens":1000,"completion_tokens":500},"choices":[{"message":{"content":"OK"}}]}"#.utf8)
        let parsed = try ProviderTestProtocol.parseResponse(response, format: .openAIChatCompletions, operation: .generateText)
        XCTAssertEqual(parsed.content, "OK")
        XCTAssertEqual(try XCTUnwrap(ProviderTestProtocol.estimatedCost(profile: profile, usage: parsed.usage)), 0.00049, accuracy: 0.0000001)

        profile.outputCostUSDPerMillion = nil
        XCTAssertNil(ProviderTestProtocol.estimatedCost(profile: profile, usage: parsed.usage))
    }

    func testRequestRecordPreservesMetadataAndOnlyExplicitContent() throws {
        let profile = APIKeyProviderProfile(id: "gemini", type: .gemini, storesFullRequestRecords: true)
        let record = ProviderRequestRecord(
            profileID: profile.id,
            provider: profile.type.rawValue,
            model: profile.modelIdentifier,
            operation: ProviderOperation.generateText.rawValue,
            endpoint: "https://example.test/v1",
            method: "POST",
            statusCode: 200,
            durationMilliseconds: 41,
            inputTokens: 3,
            outputTokens: 1,
            estimatedCostUSD: 0.0001,
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
    }

    func testExplicitProviderClassificationUsesOnlyKnownLeafIDs() throws {
        let profile = APIKeyProviderProfile(type: .gemini, maximumTokens: 512)
        let entry = EntryEvidence(platform: "youtube", entryID: "entry", surface: .feed, evidence: .init(title: "Deck gameplay"))
        let prepared = try ProviderClassificationProtocol.prepare(
            profile: profile,
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
            .init(type: .openAICompatible, modelIdentifier: "deepseek-chat", customEndpoint: "https://api.deepseek.com/v1"),
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
            XCTAssertEqual(try ProviderTestProtocol.prepare(profile: profile).operation, .generateText, profile.type.rawValue)
            XCTAssertEqual(
                try ProviderClassificationProtocol.prepare(profile: profile, entry: entry, allowedLeafTagIDs: ["games"]).operation,
                .generateText,
                profile.type.rawValue
            )
        }
    }

    func testPlatformDataProfilesDoNotPrepareLanguageModelRequests() throws {
        let platformTypes: [APIKeyProviderType] = [
            .youtubeData, .twitch, .reddit, .xPlatform, .tikTok,
            .instagramGraph, .facebookGraph, .linkedIn, .pinterest, .bluesky,
            .mastodon, .vimeo, .dailyMotion, .spotify,
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
}
