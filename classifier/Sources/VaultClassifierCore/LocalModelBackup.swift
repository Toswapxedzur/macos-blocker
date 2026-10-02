#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
#if canImport(Security)
import Security
#else
public typealias OSStatus = Int32
#endif

/// The local-only backup policy. The app UI gates changing this setting behind
/// an owner code kept in Keychain; the state file contains only a user-chosen
/// local directory and never the code itself.
public struct LocalBackupConfiguration: Codable, Equatable, Sendable {
    public static let retainedSnapshotCount = 4 // current + three prior snapshots

    public var isEnabled: Bool
    public var directoryPath: String

    public init(isEnabled: Bool, directoryPath: String) {
        self.isEnabled = isEnabled
        self.directoryPath = directoryPath
    }

    public func directoryURL() throws -> URL {
        let trimmed = directoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LocalBackupError.missingDirectory }
        let url = URL(fileURLWithPath: trimmed).standardizedFileURL
        guard url.isFileURL, url.path != "/" else { throw LocalBackupError.invalidDirectory }
        return url
    }
}

public struct LocalModelBackupManifest: Codable, Equatable, Sendable {
    public var createdAtMilliseconds: Int64
    public var activeModelIdentity: ActiveModelIdentity?
    public var packageChecksum: String
    public var collectedEntryCount: Int
    public var videoClassificationCount: Int

    public init(
        createdAtMilliseconds: Int64,
        activeModelIdentity: ActiveModelIdentity?,
        packageChecksum: String,
        collectedEntryCount: Int,
        videoClassificationCount: Int
    ) {
        self.createdAtMilliseconds = createdAtMilliseconds
        self.activeModelIdentity = activeModelIdentity
        self.packageChecksum = packageChecksum
        self.collectedEntryCount = collectedEntryCount
        self.videoClassificationCount = videoClassificationCount
    }

    private enum CodingKeys: String, CodingKey {
        case createdAtMilliseconds, activeModelIdentity, packageChecksum
        case collectedEntryCount, videoClassificationCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        createdAtMilliseconds = try container.decode(Int64.self, forKey: .createdAtMilliseconds)
        activeModelIdentity = try container.decodeIfPresent(ActiveModelIdentity.self, forKey: .activeModelIdentity)
        packageChecksum = try container.decode(String.self, forKey: .packageChecksum)
        collectedEntryCount = try container.decodeIfPresent(Int.self, forKey: .collectedEntryCount) ?? 0
        videoClassificationCount = try container.decodeIfPresent(Int.self, forKey: .videoClassificationCount) ?? 0
    }
}

/// The local backup payload contains current authored and collected state only.
public struct LocalModelBackupPayload: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var settings: ClassifierSettings
    public var workspaceCatalog: WorkspaceCatalog
    public var activeModelIdentity: ActiveModelIdentity?
    public var highestAcceptedSignedRelease: PackageReleaseStamp?
    public var signedRollbackIdentities: [ActiveModelIdentity]

    public init(state: LocalClassifierState) {
        schemaVersion = state.schemaVersion
        settings = state.settings
        workspaceCatalog = state.workspaceCatalog
        activeModelIdentity = state.activeModelIdentity
        highestAcceptedSignedRelease = state.highestAcceptedSignedRelease
        signedRollbackIdentities = state.signedRollbackIdentities
    }
}

public enum LocalBackupError: Error, Equatable, LocalizedError, Sendable {
    case missingDirectory
    case invalidDirectory
    case unsafeDirectory
    case backupDisabled
    case invalidOwnerCode
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .missingDirectory: return "Choose a local folder for Vault Classifier backups."
        case .invalidDirectory: return "The backup folder must be a local directory other than the filesystem root."
        case .unsafeDirectory: return "The backup folder cannot be a symbolic link."
        case .backupDisabled: return "Enable local backup mode before creating a snapshot."
        case .invalidOwnerCode: return "Use an owner code with at least eight characters."
        case .keychain: return "The local backup owner code could not be stored securely on this device."
        }
    }
}

/// Private snapshots of the active package and current local workspace. The
/// output is an ordinary directory intended for a user-controlled disk or Mac
/// mini share; this type never opens a network connection or uploads anything.
public struct LocalModelBackup: Sendable {
    public init() {}

    @discardableResult
    public func backup(
        state: LocalClassifierState,
        package: VerifiedSeedPackage,
        in directory: URL,
        at date: Date = .now
    ) throws -> URL {
        let fileManager = FileManager.default
        let root = directory.standardizedFileURL
        if fileManager.fileExists(atPath: root.path) {
            let attributes = try fileManager.attributesOfItem(atPath: root.path)
            guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else {
                throw LocalBackupError.unsafeDirectory
            }
        } else {
            try VaultPrivateFile.createDirectory(at: root, fileManager: fileManager)
        }
        try VaultPrivateFile.restrict(root, directory: true, fileManager: fileManager)

        let milliseconds = Int64((date.timeIntervalSince1970 * 1_000).rounded(.towardZero))
        let staging = root.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        let destination = root.appendingPathComponent("model-\(milliseconds)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try VaultPrivateFile.createDirectory(at: staging, fileManager: fileManager)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(LocalModelBackupPayload(state: state)).write(to: staging.appendingPathComponent("model-state.json"), options: .atomic)
            try package.rawData.write(to: staging.appendingPathComponent("seed-package.json"), options: .atomic)
            let manifest = LocalModelBackupManifest(
                createdAtMilliseconds: milliseconds,
                activeModelIdentity: state.activeModelIdentity,
                packageChecksum: package.checksum,
                collectedEntryCount: state.workspaceCatalog.datasets.reduce(0) { $0 + $1.collectedEntries.count },
                videoClassificationCount: state.workspaceCatalog.videoClassifications.count
            )
            try encoder.encode(manifest).write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)
            for file in ["model-state.json", "seed-package.json", "manifest.json"] {
                try VaultPrivateFile.restrict(staging.appendingPathComponent(file), fileManager: fileManager)
            }
            try fileManager.moveItem(at: staging, to: destination)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }

        let snapshots = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.hasDirectoryPath && $0.lastPathComponent.hasPrefix("model-") }
        .sorted {
            let left = (try? JSONDecoder().decode(LocalModelBackupManifest.self, from: Data(contentsOf: $0.appendingPathComponent("manifest.json"))).createdAtMilliseconds) ?? Int64.min
            let right = (try? JSONDecoder().decode(LocalModelBackupManifest.self, from: Data(contentsOf: $1.appendingPathComponent("manifest.json"))).createdAtMilliseconds) ?? Int64.min
            if left != right { return left > right }
            return $0.lastPathComponent > $1.lastPathComponent
        }
        for stale in snapshots.dropFirst(LocalBackupConfiguration.retainedSnapshotCount) {
            try fileManager.removeItem(at: stale)
        }
        return destination
    }
}

/// A Keychain-held verifier for the optional local backup-mode lock. The code
/// itself never enters classifier state, backups, diagnostics, or IPC.
public enum LocalBackupOwnerCodeStore {
    private static let productionService = "com.adamancia.vault-classifier.local-backup"
    private static let account = "owner-code-sha256"

    public static var hasOwnerCode: Bool { loadVerifier(environment: .current) != nil }

    public static func setOwnerCode(_ code: String) throws {
        guard code.count >= 8 else { throw LocalBackupError.invalidOwnerCode }
        let verifier = Data(SHA256.hash(data: Data(code.utf8)))
        #if os(Windows)
        let directory = try VaultRuntimeEnvironment.current.classifierSupportDirectoryURL()
        let url = directory.appendingPathComponent("backup-owner-verifier.dpapi")
        try VaultPrivateFile.protectedData(verifier).write(to: url, options: .atomic)
        try VaultPrivateFile.restrict(url)
        #else
        let identity: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service(environment: .current),
            kSecAttrAccount: account,
        ]
        SecItemDelete(identity as CFDictionary)
        var insert = identity
        insert[kSecValueData] = verifier
        insert[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(insert as CFDictionary, nil)
        guard status == errSecSuccess else { throw LocalBackupError.keychain(status) }
        #endif
    }

    public static func verifyOwnerCode(_ code: String) -> Bool {
        guard let expected = loadVerifier(environment: .current) else { return false }
        let actual = Data(SHA256.hash(data: Data(code.utf8)))
        guard actual.count == expected.count else { return false }
        return zip(actual, expected).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }


    private static func service(environment: VaultRuntimeEnvironment) -> String {
        environment.keychainService(productionService)
    }

    #if canImport(Security)
    private static func identity(environment: VaultRuntimeEnvironment) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service(environment: environment),
            kSecAttrAccount: account,
        ]
    }

    #endif

    private static func loadVerifier(environment: VaultRuntimeEnvironment) -> Data? {
        #if os(Windows)
        guard let directory = try? environment.classifierSupportDirectoryURL(),
              let encrypted = try? Data(contentsOf: directory.appendingPathComponent("backup-owner-verifier.dpapi")),
              let verifier = try? VaultPrivateFile.protectedData(encrypted, decrypt: true),
              verifier.count == 32 else { return nil }
        return verifier
        #else
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service(environment: environment),
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
        #endif
    }
}
