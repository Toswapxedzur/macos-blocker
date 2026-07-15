import Foundation
import Security

/// Keychain-only storage for an explicitly user-supplied Gemini personal-audit
/// credential. The provider key is never written to classifier state, logs,
/// diagnostic exports, native messaging, or a server request.
public enum PersonalAuditCredentialStore {
    private static let service = "com.adamancia.vault-classifier.personal-audit"
    private static let geminiAccount = "google-gemini-api-key-v1"
    public static let maximumCredentialCharacters = 512

    public static func hasGeminiAPIKey() -> Bool {
        loadGeminiAPIKey() != nil
    }

    public static func loadGeminiAPIKey() -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: geminiAccount,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let credential = String(data: data, encoding: .utf8),
              isValid(credential) else {
            return nil
        }
        return credential
    }

    public static func saveGeminiAPIKey(_ credential: String) throws {
        guard isValid(credential) else {
            throw PersonalAuditCredentialStoreError.invalidCredential
        }
        let identity: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: geminiAccount,
        ]
        let attributes: [CFString: Any] = [
            kSecValueData: Data(credential.utf8),
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw PersonalAuditCredentialStoreError.keychain(updateStatus)
        }
        var insert = identity
        for (key, value) in attributes { insert[key] = value }
        let insertStatus = SecItemAdd(insert as CFDictionary, nil)
        guard insertStatus == errSecSuccess else {
            throw PersonalAuditCredentialStoreError.keychain(insertStatus)
        }
    }

    public static func removeGeminiAPIKey() throws {
        let identity: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: geminiAccount,
        ]
        let status = SecItemDelete(identity as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PersonalAuditCredentialStoreError.keychain(status)
        }
    }

    private static func isValid(_ credential: String) -> Bool {
        guard !credential.isEmpty,
              credential == credential.trimmingCharacters(in: .whitespacesAndNewlines),
              credential.count <= maximumCredentialCharacters else {
            return false
        }
        return credential.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x21 && scalar.value <= 0x7E
        }
    }
}

public enum PersonalAuditCredentialStoreError: Error, LocalizedError, Sendable {
    case invalidCredential
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .invalidCredential:
            return "The provider credential is malformed."
        case .keychain:
            return "The provider credential could not be updated in Keychain."
        }
    }
}
