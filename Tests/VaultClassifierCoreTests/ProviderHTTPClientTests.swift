import Foundation
import XCTest
@testable import VaultClassifierCore

private final class ProviderRequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequest: URLRequest?

    var request: URLRequest? { lock.withLock { storedRequest } }

    func record(_ request: URLRequest) {
        lock.withLock { storedRequest = request }
    }
}

final class ProviderHTTPClientTests: XCTestCase {
    private func plan(
        authentication: ProviderAuthenticationMethod,
        header: String? = nil,
        url: String = "https://example.test/request"
    ) -> ProviderRequestPlan {
        .init(
            url: URL(string: url)!,
            method: "POST",
            bodyFormat: .openAIChatCompletions,
            headers: ["Content-Type": "application/json", "X-Static": "yes"],
            authentication: authentication,
            authenticationHeader: header,
            requiredCredentialFields: authentication == .none ? [] : [.apiKey]
        )
    }

    private func client(
        capture: ProviderRequestCapture,
        statusCode: Int = 200
    ) -> URLSessionProviderHTTPClient {
        URLSessionProviderHTTPClient { request in
            capture.record(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: statusCode,
                httpVersion: nil, headerFields: nil
            )!
            return (Data("ok".utf8), response)
        }
    }

    func testAppliesBearerCredentialHeadersAndBody() async throws {
        let capture = ProviderRequestCapture()
        let client = client(capture: capture)
        let body = Data(#"{"hello":"world"}"#.utf8)

        _ = try await client.send(
            plan: plan(authentication: .bearerToken),
            body: body,
            credential: .init(values: [.apiKey: "secret"]),
            timeout: 7
        )

        let request = try XCTUnwrap(capture.request)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Static"), "yes")
        XCTAssertEqual(request.httpBody, body)
        XCTAssertEqual(request.timeoutInterval, 7)
    }

    func testAppliesAPIKeyHeaderAndQuery() async throws {
        let headerCapture = ProviderRequestCapture()
        _ = try await client(capture: headerCapture).send(
            plan: plan(authentication: .apiKeyHeader, header: "X-Research-Key"),
            body: nil,
            credential: .init(values: [.apiKey: "header-secret"]),
            timeout: 5
        )
        XCTAssertEqual(
            headerCapture.request?.value(forHTTPHeaderField: "X-Research-Key"),
            "header-secret"
        )

        let queryCapture = ProviderRequestCapture()
        _ = try await client(capture: queryCapture).send(
            plan: plan(authentication: .apiKeyQuery, header: "key", url: "https://example.test/search?q=safe"),
            body: nil,
            credential: .init(values: [.apiKey: "query-secret"]),
            timeout: 5
        )
        let components = try XCTUnwrap(URLComponents(url: XCTUnwrap(queryCapture.request?.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "q" })?.value, "safe")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "key" })?.value, "query-secret")
    }

    func testRejectsUnsupportedSigningAndNonSuccessStatus() async throws {
        let capture = ProviderRequestCapture()
        let subject = client(capture: capture)
        await XCTAssertThrowsErrorAsync {
            _ = try await subject.send(
                plan: self.plan(authentication: .awsSignatureV4),
                body: nil,
                credential: .init(values: [.accessKeyID: "id", .secretAccessKey: "secret"]),
                timeout: 5
            )
        } verify: { error in
            XCTAssertEqual(error as? ProviderTestProtocolError, .unsupportedProvider)
        }

        let failing = client(capture: capture, statusCode: 429)
        await XCTAssertThrowsErrorAsync {
            _ = try await failing.send(
                plan: self.plan(authentication: .none),
                body: nil,
                credential: .init(values: [:]),
                timeout: 5
            )
        } verify: { error in
            XCTAssertEqual(error as? ProviderTestHTTPError, .status(429))
        }
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    verify: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        verify(error)
    }
}
