import Foundation
import Security

/// Keychain-backed secret shared only by the installed local app and its native
/// host. It is never exposed to a server or written into the classifier state.
public enum DevicePairingSecretStore {
    private static let service = "com.adamancia.vault-classifier.phase2"
    private static let account = "chrome-edge-extension"

    public static func load() -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    @discardableResult
    public static func ensure() throws -> Data {
        if let existing = load(), existing.count == 32 { return existing }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw DevicePairingSecretStoreError.randomness }
        let secret = Data(bytes)
        try replace(with: secret)
        return secret
    }

    public static func replace(with secret: Data) throws {
        guard secret.count == 32 else { throw DevicePairingSecretStoreError.invalidLength }
        let identity: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        SecItemDelete(identity as CFDictionary)
        var insert = identity
        insert[kSecValueData] = secret
        insert[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(insert as CFDictionary, nil)
        guard status == errSecSuccess else { throw DevicePairingSecretStoreError.keychain(status) }
    }
}

public enum DevicePairingSecretStoreError: Error, LocalizedError, Sendable {
    case randomness
    case invalidLength
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .randomness: return "Could not generate the local pairing secret."
        case .invalidLength: return "A Vault Classifier pairing secret must be 256 bits."
        case .keychain: return "Could not store the local pairing secret in Keychain."
        }
    }
}
