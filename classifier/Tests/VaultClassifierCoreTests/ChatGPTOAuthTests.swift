import Foundation
import XCTest
@testable import VaultClassifierResearch
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Security)
import Security
#endif

final class ChatGPTOAuthTests: XCTestCase {
    // Public-only vector signed by a disposable Windows CNG key. The private
    // key was never exported. Exercise both macOS Security and Windows BCrypt.
    func testNativeRSAWithPortablePublicFixtureRejectsTampering() throws {
        let token = "eyJhbGciOiJSUzI1NiIsImtpZCI6InZhdWx0LW5hdGl2ZS1maXh0dXJlIn0.eyJzdWIiOiJuYXRpdmUtdGVzdC1vbmx5IiwiaXNzIjoiaHR0cHM6Ly9hdXRoLm9wZW5haS5jb20iLCJhdWQiOiJvYWlhcHBfZml4dHVyZSIsIm5vbmNlIjoibmF0aXZlLWZpeHR1cmUtbm9uY2UiLCJpYXQiOjE3MDAwMDAwMDAsImV4cCI6MTcwMDAwMDEyMH0.N9NqDLxft-oryFnqae5HM_y-b-sMnq9j-CJ-IqK9x-RjFFBpS-FvwGnbQfcqSy4hHPwEd4dYP2dPRzIkct1-3ke2bVhO94ZRvjIKqO7n6oIapxypdA99U0bF2St7fkML4AqcJcLF8OwlmMTQ1jAQkl3MVSm9KLZjr0oCOHWb-0RzQDa-JBkm1WqjAoRSXt7zYsmHOKswN9uJ8V1d45N1K-xcwFCiwRpF05K2SeSWRFu4G64Gbtlk_K8_99JtO-w98xOtA4-w9PXmJ3ClaHiOsw5RMlBy144v5pJ27QCDU3yUPXu8d5iiQfYJ0EYGiJBvR2NW5tqhL947lI-yf-da7w"
        let jwks = Data(#"{"keys":[{"kid":"vault-native-fixture","n":"6Dv9VIE4mYtq84BvjZ2NHqwR-9jMfBhfz3FUE6dY1DJxACo-9CzvN3T2Rjp4LyDTfCEur2ZZLeztDsjaH-9aXr9b32Iy5-gLdbSSLhjphoY1PQwYTzy_e74JMvPxlD7S-lDlx1QXoBfU06JQHP1dG12hP1YUm1LBHLbL6pICyFmp9nd4IGMHyD5wBjgSD9r9BbrlpSuYjz829hUjPe-2y6ZMWXH8hR8Cu4sBo5Uax7R7r-1lSqNpLICC4bADkbEoc9qbmnRjWN5pJ_4BwgJ9WFzfCW186FmbRdictb0Z74c03kdACtoZhyQYqRsZ49v-AtKR6FBAIkJE9OJRy24BgQ","alg":"RS256","e":"AQAB","kty":"RSA","use":"sig"}]}"#.utf8)
        let now = Date(timeIntervalSince1970: 1_700_000_060)
        let identity = try ChatGPTOAuth.verifyIdentity(token, jwks: jwks, clientID: "oaiapp_fixture", nonce: "native-fixture-nonce", now: now)
        XCTAssertEqual(identity.subject, "native-test-only")
        var parts = token.split(separator: ".").map(String.init)
        var signature = try XCTUnwrap(ChatGPTOAuth.decodeBase64URL(parts[2]))
        signature[signature.startIndex] ^= 1
        parts[2] = ChatGPTOAuth.base64URL(signature)
        XCTAssertThrowsError(try ChatGPTOAuth.verifyIdentity(parts.joined(separator: "."), jwks: jwks, clientID: "oaiapp_fixture", nonce: "native-fixture-nonce", now: now))
    }

    #if canImport(Security)
    func testIdentityRequiresNativeSignatureIssuerAudienceNonceAndExpiry() throws {
        let key = try XCTUnwrap(SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048] as CFDictionary, nil))
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(key))
        let exported = try XCTUnwrap(SecKeyCopyExternalRepresentation(publicKey, nil)) as Data
        var bytes = Array(exported); var index = 0
        func length() -> Int {
            let first = Int(bytes[index]); index += 1
            if first < 128 { return first }
            var result = 0
            for _ in 0..<(first & 127) { result = result * 256 + Int(bytes[index]); index += 1 }
            return result
        }
        XCTAssertEqual(bytes[index], 0x30); index += 1; _ = length()
        func integer() -> Data {
            XCTAssertEqual(bytes[index], 2); index += 1
            let count = length(); var value = Data(bytes[index..<(index + count)]); index += count
            if value.first == 0 { value.removeFirst() }
            return value
        }
        let modulus = integer(), exponent = integer()
        bytes.removeAll()
        let jwks = try JSONSerialization.data(withJSONObject: ["keys": [["kty": "RSA", "kid": "fixture", "alg": "RS256", "use": "sig",
            "n": ChatGPTOAuth.base64URL(modulus), "e": ChatGPTOAuth.base64URL(exponent)]]])
        let now = Date()
        let claims: [String: Any] = ["sub": "verified-subject", "iss": "https://auth.openai.com", "aud": "oaiapp_fixture",
            "iat": now.timeIntervalSince1970, "exp": now.addingTimeInterval(120).timeIntervalSince1970, "nonce": "fresh-fixture-nonce"]
        func signed(_ claims: [String: Any]) throws -> String {
            let header = ChatGPTOAuth.base64URL(try JSONSerialization.data(withJSONObject: ["alg": "RS256", "kid": "fixture"]))
            let payload = ChatGPTOAuth.base64URL(try JSONSerialization.data(withJSONObject: claims))
            let message = header + "." + payload
            let signature = try XCTUnwrap(SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data(message.utf8) as CFData, nil)) as Data
            return message + "." + ChatGPTOAuth.base64URL(signature)
        }
        let token = try signed(claims)
        let identity = try ChatGPTOAuth.verifyIdentity(token, jwks: jwks, clientID: "oaiapp_fixture", nonce: "fresh-fixture-nonce", now: now)
        XCTAssertEqual(identity.subject, "verified-subject")
        XCTAssertThrowsError(try ChatGPTOAuth.verifyIdentity(token, jwks: jwks, clientID: "oaiapp_other", nonce: "fresh-fixture-nonce", now: now))
        XCTAssertThrowsError(try ChatGPTOAuth.verifyIdentity(token, jwks: jwks, clientID: "oaiapp_fixture", nonce: "wrong", now: now))
        XCTAssertThrowsError(try ChatGPTOAuth.verifyIdentity(token, jwks: jwks, clientID: "oaiapp_fixture", nonce: nil, expectedSubject: "different", now: now))
        var expired = claims; expired["exp"] = now.addingTimeInterval(-120).timeIntervalSince1970
        XCTAssertThrowsError(try ChatGPTOAuth.verifyIdentity(signed(expired), jwks: jwks, clientID: "oaiapp_fixture", nonce: "fresh-fixture-nonce", now: now))
        var wrongIssuer = claims; wrongIssuer["iss"] = "https://example.invalid"
        XCTAssertThrowsError(try ChatGPTOAuth.verifyIdentity(signed(wrongIssuer), jwks: jwks, clientID: "oaiapp_fixture", nonce: "fresh-fixture-nonce", now: now))
        var tampered = token.split(separator: ".").map(String.init)
        tampered[1] = ChatGPTOAuth.base64URL(try JSONSerialization.data(withJSONObject: ["sub": "attacker"]))
        XCTAssertThrowsError(try ChatGPTOAuth.verifyIdentity(tampered.joined(separator: "."), jwks: jwks, clientID: "oaiapp_fixture", nonce: "fresh-fixture-nonce", now: now))
    }
    #endif

    func testLoopbackReceivesOneRealCallbackWithoutBrowserOrProvider() async throws {
        let listener = try ChatGPTLoopback()
        let callback = URL(string: "http://127.0.0.1:\(listener.port)/auth/callback")!
        let attempt = try ChatGPTPlanProtocol.AuthorizationAttempt(callbackURL: callback, hostID: "urn:uuid:fixture",
            state: "fixture-state", nonce: "fixture-nonce", verifier: String(repeating: "v", count: 43), s256Challenge: "fixture-challenge")
        let waiting = Task { try await listener.receive(attempt: attempt) }
        let url = URL(string: callback.absoluteString + "?state=fixture-state&code=test-only-code&client_id=oaiapp_fixture")!
        var request = URLRequest(url: url); request.timeoutInterval = 3
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let result = try await waiting.value
        XCTAssertEqual(result.clientID, "oaiapp_fixture")
        XCTAssertEqual(result.request.url, ChatGPTPlanProtocol.tokenEndpoint)
    }

    func testCancellingLoopbackStopsWithoutWaitingForSignInDeadline() async throws {
        let listener = try ChatGPTLoopback()
        let attempt = try ChatGPTPlanProtocol.AuthorizationAttempt(callbackURL: URL(string: "http://127.0.0.1:\(listener.port)/auth/callback")!,
            hostID: "urn:uuid:fixture", state: "s", nonce: "n", verifier: String(repeating: "v", count: 43), s256Challenge: "fixture")
        let start = Date()
        let task = Task { try await listener.receive(attempt: attempt) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled sign-in must not succeed") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }
}
