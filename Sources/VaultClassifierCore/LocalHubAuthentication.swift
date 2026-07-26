import CryptoKit
import Foundation
import Security

/// Authentication for the fixed local Vault hub. Browser code never receives
/// this secret: Chromium asks its registered native host to answer a fresh hub
/// challenge for each new WebSocket connection.
public enum LocalHubAuthentication {
    public static let protocolVersion = 4
    public static let browserPrograms: Set<String> = ["chrome", "edge"]
    public static let desktopPrograms: Set<String> = ["classifier", "macapp"]

    private static let productionService = "com.adamancia.vault.local-hub"
    private static let account = "protocol-v4-challenge-secret"
    private static let secretLength = 32
    private static let challengeLength = 43

    public static func isBrowserProgram(_ program: String) -> Bool {
        browserPrograms.contains(program)
    }

    public static func isDesktopProgram(_ program: String) -> Bool {
        desktopPrograms.contains(program)
    }

    public static func makeChallenge() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw LocalHubAuthenticationError.randomness
        }
        return base64URL(Data(bytes))
    }

    public static func makeProof(
        program: String,
        challenge: String,
        environment: VaultRuntimeEnvironment = .current
    ) throws -> String {
        try makeProof(program: program, challenge: challenge, secret: ensureSecret(environment: environment))
    }

    public static func makeProof(program: String, challenge: String, secret: Data) throws -> String {
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

    public static func verifyProof(
        program: String,
        challenge: String,
        proof: String,
        environment: VaultRuntimeEnvironment = .current
    ) -> Bool {
        guard let secret = try? ensureSecret(environment: environment) else { return false }
        return verifyProof(program: program, challenge: challenge, proof: proof, secret: secret)
    }

    public static func verifyProof(program: String, challenge: String, proof: String, secret: Data) -> Bool {
        guard let expected = try? makeProof(program: program, challenge: challenge, secret: secret),
              let expectedData = base64URLData(expected),
              let suppliedData = base64URLData(proof) else {
            return false
        }
        return constantTimeEquals(expectedData, suppliedData)
    }

    public static func moveProductionSecretToDevelopmentOnce() throws {
        let source = loadSecret(environment: .production)
        let destination = loadSecret(environment: .development)
        if let source, let destination, source != destination {
            throw LocalHubAuthenticationError.environmentConflict
        }
        if let source, destination == nil {
            try storeSecret(source, environment: .development)
        }
        if source != nil {
            guard loadSecret(environment: .development) == source else {
                throw LocalHubAuthenticationError.environmentMigration
            }
            deleteSecret(environment: .production)
        }
    }

    private static func ensureSecret(environment: VaultRuntimeEnvironment) throws -> Data {
        if let existing = loadSecret(environment: environment), existing.count == secretLength { return existing }

        if loadSecret(environment: environment) != nil { deleteSecret(environment: environment) }
        var bytes = [UInt8](repeating: 0, count: secretLength)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw LocalHubAuthenticationError.randomness
        }
        let secret = Data(bytes)
        do {
            try storeSecret(secret, environment: environment)
            return secret
        } catch LocalHubAuthenticationError.keychain(let status) where status == errSecDuplicateItem {
            if let concurrentSecret = loadSecret(environment: environment), concurrentSecret.count == secretLength {
                return concurrentSecret
            }
            throw LocalHubAuthenticationError.keychain(status)
        }
    }

    private static func storeSecret(_ secret: Data, environment: VaultRuntimeEnvironment) throws {
        var item: [CFString: Any] = identity(environment: environment)
        item[kSecValueData] = secret
        item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecSuccess { return }
        if status == errSecDuplicateItem,
           loadSecret(environment: environment) == secret { return }
        throw LocalHubAuthenticationError.keychain(status)
    }

    private static func identity(environment: VaultRuntimeEnvironment) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: environment.keychainService(productionService),
            kSecAttrAccount: account,
        ]
    }

    private static func loadSecret(environment: VaultRuntimeEnvironment) -> Data? {
        var query = identity(environment: environment)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func deleteSecret(environment: VaultRuntimeEnvironment) {
        SecItemDelete(identity(environment: environment) as CFDictionary)
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
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func base64URLData(_ value: String) -> Data? {
        guard value.count >= 32, value.count <= 128,
              value.unicodeScalars.allSatisfy({
                  ($0.value >= 0x41 && $0.value <= 0x5a) ||
                  ($0.value >= 0x61 && $0.value <= 0x7a) ||
                  ($0.value >= 0x30 && $0.value <= 0x39) ||
                  $0.value == 0x2d || $0.value == 0x5f
              }) else {
            return nil
        }
        let normalized = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = String(repeating: "=", count: (4 - normalized.count % 4) % 4)
        return Data(base64Encoded: normalized + padding)
    }

    private static func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

public enum LocalHubAuthenticationError: Error, LocalizedError, Sendable {
    case randomness
    case invalidInput
    case keychain(OSStatus)
    case environmentConflict
    case environmentMigration

    public var errorDescription: String? {
        switch self {
        case .randomness: return "Could not create local hub authentication material."
        case .invalidInput: return "The local hub authentication request is invalid."
        case .keychain: return "Could not store local hub authentication material."
        case .environmentConflict: return "Development and production local-hub authentication material conflict."
        case .environmentMigration: return "Could not move local-hub authentication material into development."
        }
    }
}
