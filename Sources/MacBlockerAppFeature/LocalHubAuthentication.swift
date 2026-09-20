#if os(macOS)
import CryptoKit
import Foundation
import MacBlockerCore
import Security
import VaultClassifierBridge

/// Mirrors the Vault Classifier protocol-v4 proof format. Both desktop apps and
/// the browser's native-messaging host share ONE on-device secret and challenge
/// grammar so either app can own the fixed local hub. That secret is the
/// classifier component's 0600 file (`VaultClassifierBridge`), never the
/// Keychain: an unsigned development build is rebuilt on every `swift build`, so
/// a Keychain item created by a previous binary would prompt for access on every
/// launch. The file has no such per-binary ACL, so the app launches headlessly.
enum LocalHubAuthentication {
    static let protocolVersion = 4
    static let browserPrograms: Set<String> = ["chrome", "edge"]
    static let desktopPrograms: Set<String> = ["classifier", "macapp"]

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

    static func sharedSecret() throws -> Data {
        try ensureSecret(environment: .current)
    }

    /// A stable bearer token for the local MCP server, derived from the shared
    /// hub secret via HMAC. This reuses the one Keychain item the app already
    /// unlocks at launch, so the MCP server needs no separate secret and no extra
    /// access prompt. Deterministic → the token written into a client's config
    /// stays valid across relaunches. Nil only if the hub secret is unavailable
    /// (in which case the caller should not expose an unauthenticated server).
    static func mcpBearerToken(environment: VaultRuntimeEnvironment = .current) -> String? {
        guard let secret = try? ensureSecret(environment: environment) else { return nil }
        let code = HMAC<SHA256>.authenticationCode(
            for: Data("vault-mcp-bearer-v1".utf8),
            using: SymmetricKey(data: secret)
        )
        return base64URL(Data(code))
    }

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

    private static func ensureSecret(environment: VaultRuntimeEnvironment) throws -> Data {
        // The single on-device file secret, shared with the classifier and the
        // browser's native-messaging host. `VaultClassifierBridge` resolves the
        // environment from the same variable this app reads, so passing its own
        // `.current` keeps development and production separated identically.
        try VaultClassifierBridge.LocalHubAuthentication.sharedSecret()
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
}

enum LocalHubAuthenticationError: Error {
    case randomness
    case invalidInput
}
#endif
