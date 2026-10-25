import Foundation
#if canImport(CoreFoundation)
import CoreFoundation
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// An application identity supplied by the native browser host, never by a
/// browser user agent. It is transient connection metadata, not a group key.
public struct BrowserApplicationIdentity: Equatable, Sendable {
    public let kind: String
    public let value: String

    public init?(kind: String, value: String) {
        let bytes = Array(value.utf8)
        switch kind {
        case "mac-bundle-id":
            guard let first = bytes.first, bytes.count <= 255,
                  (97...122).contains(first) || (48...57).contains(first),
                  bytes.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 }) else { return nil }
        case "windows-exe-sha256":
            guard bytes.count == 64,
                  bytes.allSatisfy({ (97...102).contains($0) || (48...57).contains($0) }) else { return nil }
        default:
            return nil
        }
        self.kind = kind
        self.value = value
    }
}

extension LocalHubAuthentication {
    public static let browserIdentityVersion = 1

    /// JSON booleans and floating-point representations are not version integers.
    public static func isBrowserIdentityVersion(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber else { return false }
        #if canImport(CoreFoundation)
        guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
        #else
        // Windows Foundation does not export CoreFoundation. As in ActivityWire,
        // reject its boolean encodings before accepting integer JSON values.
        guard !["c", "B"].contains(String(cString: number.objCType)) else { return false }
        #endif
        guard ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(String(cString: number.objCType)) else { return false }
        return number.int64Value == Int64(browserIdentityVersion)
    }

    public static func makeBrowserIdentityProof(
        program: String, challenge: String, identity: BrowserApplicationIdentity, secret: Data
    ) throws -> String {
        guard isBrowserProgram(program), validBrowserIdentityChallenge(challenge), secret.count == 32 else {
            throw LocalHubAuthenticationError.invalidInput
        }
        let canonical = "vault-local-hub-browser-v1\nprogram=\(program)\nchallenge=\(challenge)\nkind=\(identity.kind)\nvalue=\(identity.value)"
        return browserIdentityHMAC(Data(canonical.utf8), secret: secret)
    }

    public static func verifyBrowserIdentityProof(
        program: String, challenge: String, identity: BrowserApplicationIdentity, proof: String, secret: Data
    ) -> Bool {
        guard validBrowserIdentityChallenge(proof),
              let expected = try? makeBrowserIdentityProof(program: program, challenge: challenge, identity: identity, secret: secret) else { return false }
        let left = Array(expected.utf8), right = Array(proof.utf8)
        guard left.count == right.count else { return false }
        return zip(left, right).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// Checks the complete v1 object. The hub separately checks top-level
    /// capability/object pairing and the unchanged mandatory v4 base proof.
    public static func verifyBrowserIdentityAttestation(
        _ object: [String: Any], program: String, challenge: String, secret: Data
    ) -> BrowserApplicationIdentity? {
        guard Set(object.keys) == ["v", "kind", "value", "proof"],
              isBrowserIdentityVersion(object["v"]),
              let kind = object["kind"] as? String, let value = object["value"] as? String,
              let identity = BrowserApplicationIdentity(kind: kind, value: value),
              let proof = object["proof"] as? String,
              verifyBrowserIdentityProof(program: program, challenge: challenge, identity: identity, proof: proof, secret: secret) else { return nil }
        return identity
    }

    private static func validBrowserIdentityChallenge(_ value: String) -> Bool {
        value.utf8.count == 43 && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }

    private static func browserIdentityHMAC(_ data: Data, secret: Data) -> String {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: secret)))
            .base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
