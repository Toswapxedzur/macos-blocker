import Foundation
import Security

/// Keychain-only storage for user-owned API credentials. A workspace profile
/// retains only its opaque ID and non-secret configuration; raw keys never
/// enter local state, the WKWebView snapshot, diagnostics, native messaging,
/// or server traffic.
public enum ProviderCredentialStore {
    private static let service = "com.adamancia.vault-classifier.provider-credential"
    public static let maximumCredentialCharacters = 2_048

    public static func hasCredential(for profileID: String) -> Bool {
        loadCredential(for: profileID) != nil
    }

    public static func loadCredential(for profileID: String) -> String? {
        guard isValidProfileID(profileID) else { return nil }
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: profileID,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let credential = String(data: data, encoding: .utf8),
              isValidCredential(credential) else {
            return nil
        }
        return credential
    }

    public static func saveCredential(_ credential: String, for profileID: String) throws {
        guard isValidProfileID(profileID), isValidCredential(credential) else {
            throw ProviderCredentialStoreError.invalidCredential
        }
        let identity: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: profileID,
        ]
        let attributes: [CFString: Any] = [
            kSecValueData: Data(credential.utf8),
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw ProviderCredentialStoreError.keychain(updateStatus)
        }
        var insert = identity
        for (key, value) in attributes { insert[key] = value }
        let insertStatus = SecItemAdd(insert as CFDictionary, nil)
        guard insertStatus == errSecSuccess else {
            throw ProviderCredentialStoreError.keychain(insertStatus)
        }
    }

    public static func removeCredential(for profileID: String) throws {
        guard isValidProfileID(profileID) else {
            throw ProviderCredentialStoreError.invalidCredential
        }
        let identity: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: profileID,
        ]
        let status = SecItemDelete(identity as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ProviderCredentialStoreError.keychain(status)
        }
    }

    private static func isValidProfileID(_ profileID: String) -> Bool {
        !profileID.isEmpty && profileID.count <= 128 && profileID.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x21 && scalar.value <= 0x7E
        }
    }

    private static func isValidCredential(_ credential: String) -> Bool {
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

public enum ProviderCredentialStoreError: Error, LocalizedError, Sendable {
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
