import Foundation
import XCTest
import VaultClassifierCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import VaultClassifierResearch

final class ChatGPTPlanProtocolTests: XCTestCase {
    private func attempt(clientID: String? = nil) throws -> ChatGPTPlanProtocol.AuthorizationAttempt {
        try .init(
            callbackURL: URL(string: "http://127.0.0.1:1455/auth/callback")!,
            hostID: "urn:uuid:00000000-0000-4000-8000-000000000001",
            state: "expected-state", nonce: "fresh-nonce", verifier: String(repeating: "v", count: 43),
            s256Challenge: "challenge", issuedClientID: clientID)
    }

    func testDynamicRegistrationAndReturningRegistrationAreDistinct() throws {
        let first = try attempt()
        let query = try XCTUnwrap(URLComponents(url: first.authorizationURL, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.first { $0.name == "client_id" }?.value, "dynamic_agent_client")
        XCTAssertEqual(query.first { $0.name == "agent_name_hint" }?.value, "Adamancia Vault")
        XCTAssertEqual(query.first { $0.name == "resource" }?.value, ChatGPTPlanProtocol.resource)
        let returning = try attempt(clientID: "oaiapp_existing")
        let values = try XCTUnwrap(URLComponents(url: returning.authorizationURL, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertFalse(values.contains { $0.name == "agent_name_hint" })
        XCTAssertEqual(values.first { $0.name == "client_id" }?.value, "oaiapp_existing")
    }

    func testCallbackRejectsWrongStateDuplicateFieldsRedirectAndClientReplacement() throws {
        let first = try attempt()
        for url in [
            "http://127.0.0.1:1455/auth/callback?state=wrong&code=c&client_id=oaiapp_new",
            "http://127.0.0.1:1455/auth/callback?state=expected-state&state=expected-state&code=c&client_id=oaiapp_new",
            "http://localhost:1455/auth/callback?state=expected-state&code=c&client_id=oaiapp_new",
            "http://127.0.0.1:1456/auth/callback?state=expected-state&code=c&client_id=oaiapp_new",
            "http://127.0.0.1:1455/callback?state=expected-state&code=c&client_id=oaiapp_new",
            "http://127.0.0.1:1455/auth/callback?state=expected-state&code=c",
            "http://127.0.0.1:1455/auth/callback?state=expected-state&code=c&client_id=dynamic_agent_client",
        ] { XCTAssertThrowsError(try first.exchangeRequest(for: URL(string: url)!)) }
        let returning = try attempt(clientID: "oaiapp_existing")
        XCTAssertThrowsError(try returning.exchangeRequest(for: URL(string: "http://127.0.0.1:1455/auth/callback?state=expected-state&code=c&client_id=oaiapp_other")!))
        let exchanged = try returning.exchangeRequest(for: URL(string: "http://127.0.0.1:1455/auth/callback?state=expected-state&code=c")!)
        XCTAssertEqual(exchanged.clientID, "oaiapp_existing")
        XCTAssertEqual(exchanged.request.url, ChatGPTPlanProtocol.tokenEndpoint)
    }

    func testDeclineCannotBeAcceptedWithoutState() throws {
        let first = try attempt()
        XCTAssertThrowsError(try first.exchangeRequest(for: URL(string: "http://127.0.0.1:1455/auth/callback?state=wrong&error=access_denied")!)) {
            XCTAssertEqual($0 as? ChatGPTPlanError, .invalidAuthorization)
        }
        XCTAssertThrowsError(try first.exchangeRequest(for: URL(string: "http://127.0.0.1:1455/auth/callback?state=expected-state&error=access_denied")!)) {
            XCTAssertEqual($0 as? ChatGPTPlanError, .authorizationDeclined)
        }
    }

    func testTokenFormsEscapeLiteralPlusAndRedactDescriptions() throws {
        let request = try ChatGPTPlanProtocol.refreshRequest(clientID: "oaiapp_existing", refreshToken: "secret+&=value")
        let form = try XCTUnwrap(String(data: XCTUnwrap(request.body), encoding: .utf8))
        XCTAssertTrue(form.contains("refresh_token=secret%2B%26%3Dvalue"))
        XCTAssertFalse(String(describing: request).contains("secret"))
        XCTAssertFalse(String(reflecting: request).contains("secret"))
        XCTAssertFalse(String(describing: try attempt()).contains("fresh-nonce"))
    }

    func testModelsUseAccountCatalogVisibilityAndServerOrder() throws {
        let models = try ChatGPTPlanProtocol.parseModels(Data(#"{"models":[{"slug":"second","display_name":"Second","visibility":"list"},{"slug":"hidden","display_name":"Hidden","visibility":"hide"},{"slug":"first","display_name":"First","visibility":"list"},{"slug":"second","display_name":"Duplicate","visibility":"list"}]}"#.utf8))
        XCTAssertEqual(models.map(\.identifier), ["second", "first"])
        XCTAssertEqual(models.map(\.displayName), ["Second", "First"])
        XCTAssertThrowsError(try ChatGPTPlanProtocol.parseModels(Data(#"{"data":[{"id":"api-key-model"}]}"#.utf8)))
    }

    func testInferenceUsesPublicStreamingStatelessContractWithoutUnsupportedFields() throws {
        let request = try ChatGPTPlanProtocol.inferenceRequest(model: "account-selected", instructions: "Classify.", input: "Untrusted title")
        XCTAssertEqual(request.url.absoluteString, "https://api.openai.com/v1/responses")
        let data = try XCTUnwrap(request.body)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["model", "instructions", "input", "store", "stream"])
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual((body["input"] as? [[String: String]])?.first?["content"], "Untrusted title")
    }

    func testLiveStreamMayOmitContentTypeButCannotDeclareAnotherFormat() throws {
        let url = URL(string: "https://api.openai.com/v1/responses")!
        for headers in [[:], ["Content-Type": "text/event-stream"], ["Content-Type": "Text/Event-Stream; charset=UTF-8"]] {
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/2", headerFields: headers))
            XCTAssertNoThrow(try ChatGPTHTTP.validateResponse(response, streaming: true))
        }
        for type in ["application/json", "text/html", "text/event-stream, application/json"] {
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/2", headerFields: ["Content-Type": type]))
            XCTAssertThrowsError(try ChatGPTHTTP.validateResponse(response, streaming: true))
        }
        // Missing headers never make a JSON response or partial delta successful.
        for wire in [#"{"status":"completed","output_text":"Games"}"#, "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Games\"}\n\n"] {
            var parser = ChatGPTPlanStream()
            try parser.append(Data(wire.utf8))
            XCTAssertThrowsError(try parser.finish())
        }
        var parser = ChatGPTPlanStream(); try parser.append(Data(terminal.utf8))
        XCTAssertNoThrow(try parser.finish())
    }

    func testStreamHTTPStatusFailuresCannotBeAcceptedAsSuccessfulBodies() throws {
        let url = URL(string: "https://api.openai.com/v1/responses")!
        for status in [204, 302, 400, 401, 402, 403, 429, 500] {
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/2", headerFields: [:]))
            XCTAssertThrowsError(try ChatGPTHTTP.validateResponse(response, streaming: true)) { error in
                if status == 400 { XCTAssertEqual(error as? ChatGPTPlanError, .rejectedRequest) }
                if status == 401 { XCTAssertEqual(error as? CloudClassificationError, .signInRequired) }
                if status == 402 || status == 403 { XCTAssertEqual(error as? ChatGPTPlanError, .accountUnavailable) }
                if status == 429 { XCTAssertEqual(error as? ChatGPTPlanError, .usageUnavailable) }
            }
        }
    }

    private let terminal = "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"usage\":{\"total_tokens\":12}}}\r\n\r\n"

    func testStreamHandlesEveryByteBoundaryIncludingUTF8AndCRLF() throws {
        let wire = Data(("event: response.output_text.delta\r\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"学习\"}\r\n\r\n" + terminal + "data: [DONE]\n\n").utf8)
        for split in 0...wire.count {
            var parser = ChatGPTPlanStream()
            try parser.append(wire.prefix(split))
            try parser.append(wire.suffix(wire.count - split))
            XCTAssertEqual(try parser.finish(), "学习")
            XCTAssertEqual(parser.totalTokens, 12)
        }
    }

    func testDoneAndDeltasCannotSubstituteForSuccessfulCompletion() throws {
        for wire in [
            "data: [DONE]\n\n",
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Gaming\"}\n\n",
            String(terminal.dropLast(2)),
        ] {
            var parser = ChatGPTPlanStream()
            try parser.append(Data(wire.utf8))
            XCTAssertThrowsError(try parser.finish())
        }
    }

    func testUsageFailureAfterDeltasIsTerminalAndRedacted() throws {
        var parser = ChatGPTPlanStream()
        try parser.append(Data("data: {\"type\":\"response.output_text.delta\",\"delta\":\"Gaming\"}\n\n".utf8))
        let failure = Data(#"data: {"type":"response.failed","response":{"error":{"code":"subscription_sharing_usage_limit_exceeded","message":"sensitive content"}}}"#.utf8) + Data("\n\n".utf8)
        XCTAssertThrowsError(try parser.append(failure)) {
            XCTAssertEqual($0 as? ChatGPTPlanError, .usageUnavailable)
            XCTAssertFalse($0.localizedDescription.contains("sensitive"))
        }
        XCTAssertThrowsError(try parser.append(Data(terminal.utf8)))
        XCTAssertThrowsError(try parser.finish())
    }

    func testStreamBufferIsBoundedAndFinalRefusalFails() throws {
        var large = ChatGPTPlanStream()
        XCTAssertThrowsError(try large.append(Data(repeating: 120, count: ChatGPTPlanStream.maximumBytes + 1)))
        var refusal = ChatGPTPlanStream()
        XCTAssertThrowsError(try refusal.append(Data((#"data: {"type":"response.completed","response":{"status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"refusal","refusal":"No"}]}]}}"# + "\n\n").utf8)))
    }
}
