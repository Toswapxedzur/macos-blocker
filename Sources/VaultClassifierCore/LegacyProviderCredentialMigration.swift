import Foundation
import Security

/// One-time migration away from retired provider-Keychain storage. It consumes
/// the old local value during startup, copies a valid value into the ordinary
/// workspace field, and deletes the old Keychain item in every case.
public enum LegacyProviderCredentialMigration {
    private static let productionServices = [
        "com.adamancia.vault-classifier.provider-credential-v2",
        "com.adamancia.vault-classifier.provider-credential",
    ]

    public static func consume(profileID: String) -> ProviderCredentialRecord? {
        guard isValidProfileID(profileID) else { return nil }
        var firstRecord: ProviderCredentialRecord?
        for service in services(environment: .current) {
            let query: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: profileID,
                kSecReturnData: true,
                kSecMatchLimit: kSecMatchLimitOne,
            ]
            var result: CFTypeRef?
            let found = SecItemCopyMatching(query as CFDictionary, &result)
            _ = SecItemDelete(query as CFDictionary)
            guard found == errSecSuccess, let data = result as? Data else { continue }
            if let record = try? JSONDecoder().decode(ProviderCredentialRecord.self, from: data) {
                firstRecord = firstRecord ?? record
            } else if let raw = String(data: data, encoding: .utf8), ProviderCredentialRecord.isValid(raw) {
                firstRecord = firstRecord ?? .init(values: [.apiKey: raw])
            }
        }
        return firstRecord
    }

    /// Removes orphaned retired records for profiles that were deleted before
    /// this migration ran. These two services belonged only to the retired
    /// provider-credential feature.
    public static func purgeRemaining() {
        for service in services(environment: .current) {
            let query: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
            ]
            _ = SecItemDelete(query as CFDictionary)
        }
    }

    private static func services(environment: VaultRuntimeEnvironment) -> [String] {
        productionServices.map(environment.keychainService)
    }

    private static func isValidProfileID(_ profileID: String) -> Bool {
        !profileID.isEmpty && profileID.count <= 128 && profileID.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x21 && scalar.value <= 0x7E
        }
    }
}
