import Foundation
import Security

/// Keychain-backed credentials for provider profiles. The workspace catalog
/// stores the profile configuration only; a profile ID is the sole durable
/// reference to its secret.
public enum ProviderCredentialStore {
    private static let service = "com.adamancia.vault-classifier.provider-credential-v2"

    public static func hasCredential(
        profileID: String,
        descriptor: ProviderProtocolDescriptor
    ) -> Bool {
        (try? load(profileID: profileID, descriptor: descriptor)) != nil
    }

    public static func load(
        profileID: String,
        descriptor: ProviderProtocolDescriptor
    ) throws -> ProviderCredentialRecord? {
        guard isValidProfileID(profileID) else { throw ProviderCredentialStoreError.invalidProfileID }
        guard !descriptor.credentialFields.isEmpty else { return .init(values: [:]) }

        let query = identity(profileID: profileID).merging([
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]) { _, replacement in replacement }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw ProviderCredentialStoreError.keychain(status)
        }
        guard let credential = try? JSONDecoder().decode(ProviderCredentialRecord.self, from: data) else {
            throw ProviderCredentialStoreError.invalidStoredCredential
        }
        do {
            try credential.validate(for: descriptor)
            return credential
        } catch {
            throw ProviderCredentialStoreError.invalidStoredCredential
        }
    }

    public static func save(
        _ credential: ProviderCredentialRecord,
        profileID: String,
        descriptor: ProviderProtocolDescriptor
    ) throws {
        guard isValidProfileID(profileID) else { throw ProviderCredentialStoreError.invalidProfileID }
        try credential.validate(for: descriptor)
        let data = try JSONEncoder().encode(credential)
        let item = identity(profileID: profileID)
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(item as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw ProviderCredentialStoreError.keychain(updateStatus)
        }

        var insert = item
        for (key, value) in attributes { insert[key] = value }
        let insertStatus = SecItemAdd(insert as CFDictionary, nil)
        guard insertStatus == errSecSuccess else {
            throw ProviderCredentialStoreError.keychain(insertStatus)
        }
    }

    public static func remove(profileID: String) throws {
        guard isValidProfileID(profileID) else { throw ProviderCredentialStoreError.invalidProfileID }
        let status = SecItemDelete(identity(profileID: profileID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ProviderCredentialStoreError.keychain(status)
        }
    }

    private static func identity(profileID: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: profileID,
        ]
    }

    private static func isValidProfileID(_ profileID: String) -> Bool {
        !profileID.isEmpty && profileID.count <= 128 && profileID.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x21 && scalar.value <= 0x7E
        }
    }
}

public enum ProviderCredentialStoreError: Error, LocalizedError, Sendable {
    case invalidProfileID
    case invalidStoredCredential
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .invalidProfileID:
            return "The provider credential profile is invalid."
        case .invalidStoredCredential:
            return "The saved provider credential is invalid. Store it again before using this connection."
        case .keychain:
            return "The provider credential could not be updated in Keychain."
        }
    }
}
