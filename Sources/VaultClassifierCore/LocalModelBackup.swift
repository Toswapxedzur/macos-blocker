import CryptoKit
import Foundation
import Security

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
    public var trainingExampleCount: Int
    public var personalFeatureCount: Int

    public init(
        createdAtMilliseconds: Int64,
        activeModelIdentity: ActiveModelIdentity?,
        packageChecksum: String,
        trainingExampleCount: Int,
        personalFeatureCount: Int
    ) {
        self.createdAtMilliseconds = createdAtMilliseconds
        self.activeModelIdentity = activeModelIdentity
        self.packageChecksum = packageChecksum
        self.trainingExampleCount = trainingExampleCount
        self.personalFeatureCount = personalFeatureCount
    }
}

/// The intentionally narrow backup payload. Browsing cache, decision ledger,
/// audit queue/results, source observations, and local-hub authentication data are not
/// copied: a model backup is for restoring the package and explicit local
/// training material, not for archiving activity history.
public struct LocalModelBackupPayload: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var settings: ClassifierSettings
    public var policies: [NamedPolicy]
    public var personalModel: PersonalFTRLModel
    public var trainingCorpus: LocalTrainingCorpus
    public var activeModelIdentity: ActiveModelIdentity?
    public var highestAcceptedSignedRelease: PackageReleaseStamp?
    public var signedRollbackIdentities: [ActiveModelIdentity]

    public init(state: LocalClassifierState) {
        schemaVersion = state.schemaVersion
        settings = state.settings
        policies = state.policies
        personalModel = state.personalModel
        trainingCorpus = state.trainingCorpus
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
        case .keychain: return "The local backup owner code could not be stored in Keychain."
        }
    }
}

/// Private snapshots of the active package and local model material. The
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
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)

        let milliseconds = Int64((date.timeIntervalSince1970 * 1_000).rounded(.towardZero))
        let staging = root.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        let destination = root.appendingPathComponent("model-\(milliseconds)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(LocalModelBackupPayload(state: state)).write(to: staging.appendingPathComponent("model-state.json"), options: .atomic)
            try package.rawData.write(to: staging.appendingPathComponent("seed-package.json"), options: .atomic)
            let manifest = LocalModelBackupManifest(
                createdAtMilliseconds: milliseconds,
                activeModelIdentity: state.activeModelIdentity,
                packageChecksum: package.checksum,
                trainingExampleCount: state.trainingCorpus.examples.count,
                personalFeatureCount: state.personalModel.state.values.reduce(0) { $0 + $1.count }
            )
            try encoder.encode(manifest).write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)
            for file in ["model-state.json", "seed-package.json", "manifest.json"] {
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staging.appendingPathComponent(file).path)
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
    private static let service = "com.adamancia.vault-classifier.local-backup"
    private static let account = "owner-code-sha256"

    public static var hasOwnerCode: Bool { loadVerifier() != nil }

    public static func setOwnerCode(_ code: String) throws {
        guard code.count >= 8 else { throw LocalBackupError.invalidOwnerCode }
        let verifier = Data(SHA256.hash(data: Data(code.utf8)))
        let identity: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        SecItemDelete(identity as CFDictionary)
        var insert = identity
        insert[kSecValueData] = verifier
        insert[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(insert as CFDictionary, nil)
        guard status == errSecSuccess else { throw LocalBackupError.keychain(status) }
    }

    public static func verifyOwnerCode(_ code: String) -> Bool {
        guard let expected = loadVerifier() else { return false }
        return Data(SHA256.hash(data: Data(code.utf8))).elementsEqual(expected)
    }

    private static func loadVerifier() -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }
}
