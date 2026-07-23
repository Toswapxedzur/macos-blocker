import Security

/// Best-effort startup cleanup for the credential of a deliberately retired
/// feature. It has no read, migration, or replacement path.
public enum RetiredCredentialCleanup {
    public static func removePersonalAuditCredential() {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "com.adamancia.vault-classifier.personal-audit",
            kSecAttrAccount: "google-gemini-api-key-v1",
        ]
        _ = SecItemDelete(query as CFDictionary)
    }
}
