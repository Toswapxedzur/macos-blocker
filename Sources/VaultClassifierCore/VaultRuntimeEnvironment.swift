import Foundation

/// Keeps development and production on disjoint local state and transport
/// surfaces. Production is the default for signed apps launched normally;
/// development launchers opt in explicitly through the process environment.
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

    public var classifierSupportDirectoryName: String {
        switch self {
        case .production: return "VaultClassifier"
        case .development: return "VaultClassifier-Development"
        }
    }

    public var classifierLogDirectoryName: String {
        classifierSupportDirectoryName
    }

    public var chromeExtensionOrigin: String {
        switch self {
        case .production:
            return "chrome-extension://mcbmcmephdaapjepopobikobjmfdeamm/"
        case .development:
            return "chrome-extension://fjichnkbaoilbfbjcjkggllmbicmeegk/"
        }
    }

    public var nativeMessagingHostName: String {
        switch self {
        case .production: return "com.adamancia.vault.local_hub"
        case .development: return "com.adamancia.vault.local_hub.development"
        }
    }

    public func keychainService(_ productionService: String) -> String {
        switch self {
        case .production: return productionService
        case .development: return productionService + ".development"
        }
    }

    /// The app's own local support directory (`~/Library/Application
    /// Support/VaultClassifier[-Development]`), created 0700 if missing. Both
    /// the app and the browser's native-messaging host resolve the same path,
    /// so it is a stable place for on-device state that must be shared between
    /// them without a keychain item. Everything here stays on this Mac.
    public func classifierSupportDirectoryURL(fileManager: FileManager = .default) throws -> URL {
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = appSupport.appendingPathComponent(
            classifierSupportDirectoryName,
            isDirectory: true
        )
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        return directory
    }
}
