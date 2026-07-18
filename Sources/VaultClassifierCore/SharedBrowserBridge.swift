import Foundation
import Security

/// The browser-facing operation vocabulary carried by the shared Vault
/// localhost hub. The hub authenticates the WebSocket peer; these operation
/// names keep the classifier request surface deliberately small.
public enum SharedBrowserBridgeOperation: String, CaseIterable, Codable, Sendable {
    case bridgeInfo = "bridge-info"
    case collectionInfo = "collection-info"
    case collect
    case classify
    case correct
}

public enum SharedBrowserBridgeProtocol {
    public static let address = "ws://127.0.0.1:8787"
    public static let maximumBodyBytes = 88_000
    public static let maximumRequestIDLength = 128
    public static let maximumPeerIDLength = 128

    public static func isValidRequestID(_ value: String) -> Bool {
        isVisibleIdentifier(value, maximumLength: maximumRequestIDLength)
    }

    public static func isValidPeerID(_ value: String) -> Bool {
        isVisibleIdentifier(value, maximumLength: maximumPeerIDLength)
    }

    public static func isValidBody(_ value: Any) -> Bool {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else {
            return false
        }
        return data.count <= maximumBodyBytes
    }

    public static func bodyData(from value: Any) -> Data? {
        guard isValidBody(value) else { return nil }
        return try? JSONSerialization.data(withJSONObject: value)
    }

    private static func isVisibleIdentifier(_ value: String, maximumLength: Int) -> Bool {
        !value.isEmpty && value.count <= maximumLength && value.unicodeScalars.allSatisfy {
            $0.value >= 0x21 && $0.value <= 0x7e
        }
    }
}

/// The shared hub uses the same user-provided pairing key as Mac Vault and the
/// Vault extension. It is kept in Keychain and never appears in a WebView
/// snapshot, bridge frame, diagnostic, or local classifier state file.
public enum SharedHubPairingKeyStore {
    private static let service = "com.adamancia.vault-classifier.shared-hub"
    private static let account = "mac-vault-pairing-key"

    public static func load() -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              normalized(value) != nil else {
            return nil
        }
        return normalized(value)
    }

    public static func save(_ value: String) throws {
        guard let normalized = normalized(value), let data = normalized.data(using: .utf8) else {
            throw SharedHubPairingKeyStoreError.invalidKey
        }
        let identity: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw SharedHubPairingKeyStoreError.keychain(updateStatus)
        }
        var insert = identity
        for (key, value) in attributes { insert[key] = value }
        let insertStatus = SecItemAdd(insert as CFDictionary, nil)
        guard insertStatus == errSecSuccess else {
            throw SharedHubPairingKeyStoreError.keychain(insertStatus)
        }
    }

    public static func remove() throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SharedHubPairingKeyStoreError.keychain(status)
        }
    }

    public static func normalized(_ value: String) -> String? {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard cleaned.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            return nil
        }
        return cleaned
    }
}

public enum SharedHubPairingKeyStoreError: Error, LocalizedError, Sendable {
    case invalidKey
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .invalidKey:
            return "Enter the 64-character pairing key shown by Mac Vault."
        case .keychain:
            return "The Mac Vault pairing key could not be updated in Keychain."
        }
    }
}
