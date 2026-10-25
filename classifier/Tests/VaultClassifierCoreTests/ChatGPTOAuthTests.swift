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
