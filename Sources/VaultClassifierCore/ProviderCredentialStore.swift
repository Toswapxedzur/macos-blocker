import Foundation
import Security

/// Keychain-only storage for user-owned API credentials. A workspace profile
/// retains only its opaque ID and non-secret configuration; raw keys never
/// enter local state, the WKWebView snapshot, diagnostics, native messaging,
/// or server traffic.
public struct ProviderCredentialRecord: Codable, Equatable, Sendable {
    public var values: [ProviderCredentialField: String]

    public init(values: [ProviderCredentialField: String]) {
        // Clipboard copies commonly include a harmless trailing newline. Keep
        // the actual Keychain value clean without exposing it anywhere else.
        self.values = Dictionary(uniqueKeysWithValues: values.map { field, value in
            (field, value.trimmingCharacters(in: .whitespacesAndNewlines))
        })
    }

    public func validate(for descriptor: ProviderProtocolDescriptor) throws {
        guard Set(values.keys) == Set(descriptor.credentialFields) else {
            throw ProviderCredentialStoreError.invalidCredential
        }
        for field in descriptor.credentialFields {
            guard let value = values[field], ProviderCredentialStore.isValidCredential(value) else {
                throw ProviderCredentialStoreError.missingCredential(field)
            }
        }
    }
}

public enum ProviderCredentialStore {
    private static let service = "com.adamancia.vault-classifier.provider-credential"
    public static let maximumCredentialCharacters = 2_048

    public static func hasCredential(for profileID: String) -> Bool {
        guard isValidProfileID(profileID) else { return false }
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: profileID,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// Retrieves a native-only structured record. This function must never be
    /// used to form a WebView snapshot, log record, or browser message.
    public static func loadCredentialRecord(for profileID: String) -> ProviderCredentialRecord? {
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
              let credential = String(data: data, encoding: .utf8) else {
            return nil
        }
        if let record = try? JSONDecoder().decode(ProviderCredentialRecord.self, from: data) {
            return record
        }
        // A profile created before protocol revision 1 stored one raw key.
        // Treat it as an API-key record so the native panel can migrate it on
        // the next explicit replacement; do not expose it to the WebView.
        guard isValidCredential(credential) else { return nil }
        return .init(values: [.apiKey: credential])
    }

    public static func saveCredentialRecord(
        _ record: ProviderCredentialRecord,
        for profileID: String,
        descriptor: ProviderProtocolDescriptor
    ) throws {
        try record.validate(for: descriptor)
        guard isValidProfileID(profileID),
              let encoded = try? JSONEncoder().encode(record),
              encoded.count <= maximumCredentialCharacters * 2 else {
            throw ProviderCredentialStoreError.invalidCredential
        }
        let identity: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: profileID,
        ]
        let attributes: [CFString: Any] = [
            kSecValueData: encoded,
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

    static func isValidCredential(_ credential: String) -> Bool {
        guard !credential.isEmpty,
              credential.count <= maximumCredentialCharacters else {
            return false
        }
        return credential.unicodeScalars.allSatisfy { $0.properties.generalCategory != .control }
    }
}

public enum ProviderCredentialStoreError: Error, LocalizedError, Sendable {
    case invalidCredential
    case missingCredential(ProviderCredentialField)
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .invalidCredential:
            return "The provider credential is malformed."
        case .missingCredential(let field):
            return "Enter a valid \(field.rawValue) before storing this provider credential."
        case .keychain:
            return "The provider credential could not be updated in Keychain."
        }
    }
}
