import Foundation

/// Runtime boundary shared by the Mac Vault development launcher and its
/// libraries. Signed production apps default to production; development must
/// opt in explicitly so the two environments never share local state or hub
/// authentication material.
public enum VaultRuntimeEnvironment: String, Codable, Sendable {
    case production
    case development

    public static let variableName = "ADAMANCIA_VAULT_ENVIRONMENT"

    public static var current: VaultRuntimeEnvironment {
        resolve(ProcessInfo.processInfo.environment[variableName])
    }

    public static func resolve(_ value: String?) -> VaultRuntimeEnvironment {
        value == development.rawValue ? .development : .production
    }

    public var hubPort: UInt16 {
        switch self {
        case .production: return 8_787
        case .development: return 18_787
        }
    }

    public var hubAddress: String {
        "ws://127.0.0.1:\(hubPort)"
    }

    public var appGroupIdentifier: String {
        switch self {
        case .production: return "group.com.adamancia.vault"
        case .development: return "group.com.adamancia.vault.development"
        }
    }

    public var sharedStoreDirectoryName: String {
        switch self {
        case .production: return "macosBlocker"
        case .development: return "macosBlocker-Development"
        }
    }

    public var policyDirectoryName: String {
        switch self {
        case .production: return "Blocker"
        case .development: return "Blocker-Development"
        }
    }

    public var localFilesDirectoryName: String {
        switch self {
        case .production: return "MacBlocker"
        case .development: return "MacBlocker-Development"
        }
    }

    public func keychainService(_ productionService: String) -> String {
        switch self {
        case .production: return productionService
        case .development: return productionService + ".development"
        }
    }
}
