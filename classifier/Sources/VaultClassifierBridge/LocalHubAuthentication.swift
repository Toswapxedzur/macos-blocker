import CryptoKit
import Foundation
import Security
import VaultClassifierCore

/// Authentication for the fixed local Vault hub. Browser code never receives
/// this secret: Chromium asks its registered native host to answer a fresh hub
/// challenge for each new WebSocket connection.
public enum LocalHubAuthentication {
    public static let protocolVersion = 4
    public static let browserPrograms: Set<String> = ["chrome", "edge"]
    public static let desktopPrograms: Set<String> = ["classifier", "macapp"]

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

    /// The local-hub secret the Native Messaging host hands the browser. Mac
    /// Vault's ConnectionHub verifies browser/classifier proofs against this
    /// (rather than its own Keychain secret) so that, when it is the sole hub
    /// host, the extension authenticates with the single shared secret.
    public static func sharedSecret(environment: VaultRuntimeEnvironment = .current) throws -> Data {
        try ensureSecret(environment: environment)
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
        } catch LocalHubAuthenticationError.secretAlreadyExists {
            if let concurrentSecret = loadSecret(environment: environment), concurrentSecret.count == secretLength {
                return concurrentSecret
            }
            throw LocalHubAuthenticationError.fileSystem
        }
    }

    // MARK: - On-device secret storage
    //
    // The hub secret is a 32-byte HMAC key that authenticates browser↔app hub
    // connections. It lives in the app's own support directory (file mode
    // 0600) rather than the login keychain. This keeps it entirely on this Mac
    // — it is never uploaded — and avoids the per-launch keychain-access prompt
    // that an unsigned or development build otherwise triggers on every start.
    // The app and the browser's native-messaging host resolve the same path,
    // so they agree on the secret without needing a shared keychain item.
    private static let secretFileName = "local-hub-secret-v4"

    private static func secretFileURL(environment: VaultRuntimeEnvironment) throws -> URL {
        try environment.classifierSupportDirectoryURL()
            .appendingPathComponent(secretFileName, isDirectory: false)
    }

    private static func storeSecret(_ secret: Data, environment: VaultRuntimeEnvironment) throws {
        let url: URL
        do {
            url = try secretFileURL(environment: environment)
        } catch {
            throw LocalHubAuthenticationError.fileSystem
        }
        do {
            // Exclusive create: if another process wrote first, surface a
            // duplicate so the caller reads the winner's secret instead.
            try secret.write(to: url, options: [.withoutOverwriting])
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            if loadSecret(environment: environment) == secret { return }
            throw LocalHubAuthenticationError.secretAlreadyExists
        } catch {
            throw LocalHubAuthenticationError.fileSystem
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func loadSecret(environment: VaultRuntimeEnvironment) -> Data? {
        guard let url = try? secretFileURL(environment: environment),
              let data = try? Data(contentsOf: url) else { return nil }
        return data
    }

    private static func deleteSecret(environment: VaultRuntimeEnvironment) {
        guard let url = try? secretFileURL(environment: environment) else { return }
        try? FileManager.default.removeItem(at: url)
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
    case fileSystem
    case secretAlreadyExists
    case environmentConflict
    case environmentMigration

    public var errorDescription: String? {
        switch self {
        case .randomness: return "Could not create local hub authentication material."
        case .invalidInput: return "The local hub authentication request is invalid."
        case .fileSystem: return "Could not store local hub authentication material on this Mac."
        case .secretAlreadyExists: return "Local hub authentication material already exists."
        case .environmentConflict: return "Development and production local-hub authentication material conflict."
        case .environmentMigration: return "Could not move local-hub authentication material into development."
        }
    }
}
