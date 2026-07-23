#if os(macOS)
import CryptoKit
import Foundation
import Security

/// Mirrors the Vault Classifier protocol-v4 proof format. The two desktop apps
/// intentionally share only this Keychain secret and challenge grammar so
/// either one can own the fixed local hub.
enum LocalHubAuthentication {
    static let protocolVersion = 4
    static let browserPrograms: Set<String> = ["chrome", "edge"]
    static let desktopPrograms: Set<String> = ["classifier", "macapp"]

    private static let service = "com.adamancia.vault.local-hub"
    private static let account = "protocol-v4-challenge-secret"
    private static let secretLength = 32
    private static let challengeLength = 43

    static func isBrowserProgram(_ program: String) -> Bool { browserPrograms.contains(program) }
    static func isDesktopProgram(_ program: String) -> Bool { desktopPrograms.contains(program) }

    static func makeChallenge() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw LocalHubAuthenticationError.randomness
        }
        return base64URL(Data(bytes))
    }

    static func makeProof(program: String, challenge: String) throws -> String {
        try makeProof(program: program, challenge: challenge, secret: sharedSecret())
    }

    static func sharedSecret() throws -> Data { try ensureSecret() }

    static func makeProof(program: String, challenge: String, secret: Data) throws -> String {
        guard (isBrowserProgram(program) || isDesktopProgram(program)),
              isValidChallenge(challenge),
              secret.count == secretLength else {
            throw LocalHubAuthenticationError.invalidInput
        }
        let code = HMAC<SHA256>.authenticationCode(
            for: Data(canonicalString(program: program, challenge: challenge).utf8),
            using: SymmetricKey(data: secret)
        )
        return base64URL(Data(code))
    }

    static func verifyProof(program: String, challenge: String, proof: String) -> Bool {
        guard let secret = try? ensureSecret() else { return false }
        return verifyProof(program: program, challenge: challenge, proof: proof, secret: secret)
    }

    static func verifyProof(program: String, challenge: String, proof: String, secret: Data) -> Bool {
        guard let expected = try? makeProof(program: program, challenge: challenge, secret: secret),
              let expectedData = base64URLData(expected),
              let suppliedData = base64URLData(proof) else {
            return false
        }
        return constantTimeEquals(expectedData, suppliedData)
    }

    private static func ensureSecret() throws -> Data {
        if let existing = loadSecret(), existing.count == secretLength { return existing }
        if loadSecret() != nil { SecItemDelete(identity as CFDictionary) }
        var bytes = [UInt8](repeating: 0, count: secretLength)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw LocalHubAuthenticationError.randomness
        }
        let secret = Data(bytes)
        var item = identity
        item[kSecValueData] = secret
        item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecSuccess { return secret }
        if status == errSecDuplicateItem,
           let concurrentSecret = loadSecret(), concurrentSecret.count == secretLength {
            return concurrentSecret
        }
        throw LocalHubAuthenticationError.keychain(status)
    }

    private static var identity: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    }

    private static func loadSecret() -> Data? {
        var query = identity
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func canonicalString(program: String, challenge: String) -> String {
        "vault-local-hub-v4\nprogram=\(program)\nchallenge=\(challenge)"
    }

    private static func isValidChallenge(_ challenge: String) -> Bool {
        challenge.count == challengeLength && challenge.unicodeScalars.allSatisfy {
            ($0.value >= 0x41 && $0.value <= 0x5a) ||
            ($0.value >= 0x61 && $0.value <= 0x7a) ||
            ($0.value >= 0x30 && $0.value <= 0x39) ||
            $0.value == 0x2d || $0.value == 0x5f
        }
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private static func base64URLData(_ value: String) -> Data? {
        guard value.count >= 32, value.count <= 128,
              value.unicodeScalars.allSatisfy({
                  ($0.value >= 0x41 && $0.value <= 0x5a) ||
                  ($0.value >= 0x61 && $0.value <= 0x7a) ||
                  ($0.value >= 0x30 && $0.value <= 0x39) ||
                  $0.value == 0x2d || $0.value == 0x5f
              }) else { return nil }
        let normalized = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        return Data(base64Encoded: normalized + String(repeating: "=", count: (4 - normalized.count % 4) % 4))
    }

    private static func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

enum LocalHubAuthenticationError: Error {
    case randomness
    case invalidInput
    case keychain(OSStatus)
}
#endif
