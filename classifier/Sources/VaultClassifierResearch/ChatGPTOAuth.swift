import Foundation
import CVaultOAuth
import VaultClassifierCore
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(Security)
import Security
#elseif os(Windows)
import CVaultWindows
#endif

enum ChatGPTOAuth {
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func decodeBase64URL(_ text: String) -> Data? {
        var text = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        return Data(base64Encoded: text)
    }
    static func random() throws -> String {
        #if os(Windows)
        return base64URL(try VaultPrivateFile.randomData(count: 32))
        #else
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw ChatGPTPlanError.invalidAuthorization }
        return base64URL(Data(bytes))
        #endif
    }

    struct Identity: Equatable, Sendable { let subject: String; let email: String? }

    static func verifyIdentity(_ token: String, jwks: Data, clientID: String, nonce: String?, expectedSubject: String? = nil, now: Date = Date()) throws -> Identity {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard token.utf8.count <= 32768, jwks.count <= 262144, parts.count == 3,
              let headerData = decodeBase64URL(parts[0]), let payload = decodeBase64URL(parts[1]),
              let signature = decodeBase64URL(parts[2]),
              let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              header["alg"] as? String == "RS256", header["crit"] == nil,
              let kid = header["kid"] as? String,
              let set = try? JSONSerialization.jsonObject(with: jwks) as? [String: Any],
              let keys = set["keys"] as? [[String: Any]] else { throw ChatGPTPlanError.invalidAuthorization }
        let matches = keys.filter { $0["kid"] as? String == kid && $0["kty"] as? String == "RSA" }
        guard matches.count == 1, let key = matches.first,
              key["alg"] == nil || key["alg"] as? String == "RS256",
              key["use"] == nil || key["use"] as? String == "sig",
              let n = key["n"] as? String, let modulus = decodeBase64URL(n),
              (256...1024).contains(modulus.count),
              let e = key["e"] as? String, let exponent = decodeBase64URL(e),
              !exponent.isEmpty, exponent.count <= 8,
              verifyRSA(message: Data((parts[0] + "." + parts[1]).utf8), signature: signature, modulus: modulus, exponent: exponent),
              let claims = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              claims["iss"] as? String == "https://auth.openai.com",
              let sub = claims["sub"] as? String, !sub.isEmpty,
              let exp = claims["exp"] as? Double, exp > now.timeIntervalSince1970 - 5,
              let issued = claims["iat"] as? Double, issued <= now.timeIntervalSince1970 + 5,
              nonce == nil || claims["nonce"] as? String == nonce,
              expectedSubject == nil || expectedSubject == sub else { throw ChatGPTPlanError.invalidAuthorization }
        let audiences = (claims["aud"] as? [String]) ?? (claims["aud"] as? String).map { [$0] } ?? []
        guard audiences.contains(clientID), audiences.count == 1 || claims["azp"] as? String == clientID,
              (claims["nbf"] as? Double ?? 0) <= now.timeIntervalSince1970 + 5 else { throw ChatGPTPlanError.invalidAuthorization }
        return Identity(subject: sub, email: claims["email"] as? String)
    }

    static func verifyRSA(message: Data, signature: Data, modulus: Data, exponent: Data) -> Bool {
        #if canImport(Security)
        func tlv(_ tag: UInt8, _ value: Data) -> Data {
            let length: [UInt8] = value.count < 128 ? [UInt8(value.count)]
                : value.count < 256 ? [0x81, UInt8(value.count)] : [0x82, UInt8(value.count >> 8), UInt8(value.count & 255)]
            return Data([tag] + length) + value
        }
        func integer(_ bytes: Data) -> Data { tlv(2, bytes.first.map { $0 >= 128 } == true ? Data([0]) + bytes : bytes) }
        let der = tlv(0x30, integer(modulus) + integer(exponent))
        guard let key = SecKeyCreateWithData(der as CFData, [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary, nil) else { return false }
        return SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, signature as CFData, nil)
        #elseif os(Windows)
        let digest = Data(SHA256.hash(data: message))
        return modulus.withUnsafeBytes { n in exponent.withUnsafeBytes { e in signature.withUnsafeBytes { s in digest.withUnsafeBytes { d in
            vault_windows_verify_rs256(n.bindMemory(to: UInt8.self).baseAddress, n.count,
                e.bindMemory(to: UInt8.self).baseAddress, e.count,
                s.bindMemory(to: UInt8.self).baseAddress, s.count, d.bindMemory(to: UInt8.self).baseAddress) == 0
        }}}}
        #else
        return false
        #endif
    }
}

/// Owns a bound loopback socket from before browser authorization until one
/// validated callback, cancellation, or a five-minute deadline. No UI control.
final class ChatGPTLoopback: @unchecked Sendable {
    let port: UInt16
    private let descriptor: Int
    init() throws {
        var port: UInt16 = 0
        let descriptor = vault_oauth_listen(&port)
        guard descriptor >= 0 else { throw ChatGPTPlanError.invalidAuthorization }
        self.descriptor = descriptor; self.port = port
    }
    deinit { vault_oauth_close_listener(descriptor) }
    func receive(attempt: ChatGPTPlanProtocol.AuthorizationAttempt) async throws -> (clientID: String, request: ChatGPTPlanProtocol.Request) {
        let work = Task.detached { [self] in
            let deadline = ProcessInfo.processInfo.systemUptime + 300
            while ProcessInfo.processInfo.systemUptime < deadline {
                try Task.checkCancellation()
                let client = vault_oauth_accept(descriptor, 250)
                if client == -2 { continue }
                guard client >= 0 else { throw ChatGPTPlanError.invalidAuthorization }
                defer { vault_oauth_close(client) }
                var buffer = [CChar](repeating: 0, count: 8192)
                guard vault_oauth_read(client, &buffer, buffer.count) > 0 else { continue }
                let line = String(cString: buffer).components(separatedBy: "\r\n").first ?? ""
                let fields = line.split(separator: " ", omittingEmptySubsequences: false)
                guard fields.count == 3, fields[0] == "GET", fields[2] == "HTTP/1.1",
                      fields[1].hasPrefix("/auth/callback?"),
                      let url = URL(string: "http://127.0.0.1:\(port)" + fields[1]) else {
                    vault_oauth_reply(client, 0); continue
                }
                do {
                    let result = try attempt.exchangeRequest(for: url)
                    vault_oauth_reply(client, 1)
                    return result
                } catch {
                    vault_oauth_reply(client, 0)
                    throw error // Each transaction is consumed once, including an invalid return.
                }
            }
            throw ChatGPTPlanError.invalidAuthorization
        }
        return try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
    }
}
