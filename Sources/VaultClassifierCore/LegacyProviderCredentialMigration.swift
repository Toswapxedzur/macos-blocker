import Foundation
import Security

/// One-time cleanup for credentials saved by the retired provider-Keychain
/// feature. It is not a credential store: it consumes an old local item during
/// startup, hands the value to the local workspace migration, and deletes the
/// Keychain item regardless of whether its old payload was usable.
public enum LegacyProviderCredentialMigration {
    private static let service = "com.adamancia.vault-classifier.provider-credential"

    public static func consume(profileID: String) -> ProviderCredentialRecord? {
        guard isValidProfileID(profileID) else { return nil }
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: profileID,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let found = SecItemCopyMatching(query as CFDictionary, &result)
        // The Keychain-backed feature is retired even when an old record is
        // malformed: do not keep an unreachable secret behind a compatibility
        // path.
        _ = SecItemDelete(query as CFDictionary)
        guard found == errSecSuccess, let data = result as? Data else { return nil }
        if let record = try? JSONDecoder().decode(ProviderCredentialRecord.self, from: data) {
            return record
        }
        guard let raw = String(data: data, encoding: .utf8), ProviderCredentialRecord.isValid(raw) else {
            return nil
        }
        return .init(values: [.apiKey: raw])
    }

    /// Removes orphaned records for profiles that were deleted before this
    /// migration ran. The service name is exclusive to the retired provider
    /// credential feature, so this cannot affect pairing, backup, or audit
    /// Keychain items.
    public static func purgeRemaining() {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
        ]
        _ = SecItemDelete(query as CFDictionary)
    }

    private static func isValidProfileID(_ profileID: String) -> Bool {
        !profileID.isEmpty && profileID.count <= 128 && profileID.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x21 && scalar.value <= 0x7E
        }
    }
}
