import XCTest
@testable import VaultClassifierCore

final class VaultServiceEndpointTests: XCTestCase {
    func testLoopbackDevelopmentEndpointBuildsTheModelCatalogURL() throws {
        let endpoint = try VaultServiceEndpoint(baseURL: try XCTUnwrap(URL(string: "http://localhost:8080")))
        XCTAssertEqual(
            try endpoint.url(path: "api/vault-classifier/llm-model-catalog/deepSeek").absoluteString,
            "http://localhost:8080/api/vault-classifier/llm-model-catalog/deepSeek"
        )
    }

    func testProductionDefaultAndUnsafeCleartextEndpointHandling() throws {
        XCTAssertEqual(VaultServiceEndpoint.current(environment: [:]).baseURL.absoluteString, "https://customblocker.com")
        XCTAssertThrowsError(try VaultServiceEndpoint(baseURL: try XCTUnwrap(URL(string: "http://customblocker.com"))))
        XCTAssertEqual(
            VaultServiceEndpoint.current(environment: [VaultServiceEndpoint.environmentKey: "http://example.test"]).baseURL.absoluteString,
            "https://customblocker.com"
        )
    }
}
