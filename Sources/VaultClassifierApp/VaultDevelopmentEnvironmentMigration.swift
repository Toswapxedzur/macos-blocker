import Foundation
import VaultClassifierCore

/// One bounded migration for development builds that previously wrote into
/// production-named local state. The move is atomic at the directory level;
/// an existing destination is treated as a conflict rather than merged.
enum VaultDevelopmentEnvironmentMigration {
    private static let markerName = ".environment-isolation-v1"

    static func prepareClassifierDirectory(fileManager: FileManager = .default) throws -> URL {
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let environment = VaultRuntimeEnvironment.current
        let destination = appSupport.appendingPathComponent(
            environment.classifierSupportDirectoryName,
            isDirectory: true
        )
        guard environment == .development else { return destination }

        let marker = destination.appendingPathComponent(markerName)
        if fileManager.fileExists(atPath: marker.path) { return destination }

        let legacy = appSupport.appendingPathComponent(
            VaultRuntimeEnvironment.production.classifierSupportDirectoryName,
            isDirectory: true
        )
        let destinationExists = fileManager.fileExists(atPath: destination.path)
        let legacyExists = fileManager.fileExists(atPath: legacy.path)
        if destinationExists && legacyExists {
            throw VaultDevelopmentEnvironmentMigrationError.destinationConflict
        }
        if legacyExists {
            try fileManager.moveItem(at: legacy, to: destination)
        } else if !destinationExists {
            try fileManager.createDirectory(
                at: destination,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }

        try moveDevelopmentLogs(fileManager: fileManager)
        try LocalHubAuthentication.moveProductionSecretToDevelopmentOnce()
        try LocalBackupOwnerCodeStore.moveProductionVerifierToDevelopmentOnce()
        try Data("development-state-moved-from-shared-v1\n".utf8).write(
            to: marker,
            options: [.atomic]
        )
        return destination
    }

    private static func moveDevelopmentLogs(fileManager: FileManager) throws {
        let library = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
        let logs = library.appendingPathComponent("Logs", isDirectory: true)
        let source = logs.appendingPathComponent(
            VaultRuntimeEnvironment.production.classifierLogDirectoryName,
            isDirectory: true
        )
        let destination = logs.appendingPathComponent(
            VaultRuntimeEnvironment.development.classifierLogDirectoryName,
            isDirectory: true
        )
        let sourceExists = fileManager.fileExists(atPath: source.path)
        let destinationExists = fileManager.fileExists(atPath: destination.path)
        if sourceExists && destinationExists {
            throw VaultDevelopmentEnvironmentMigrationError.logDestinationConflict
        }
        if sourceExists {
            try fileManager.moveItem(at: source, to: destination)
        }
    }
}

enum VaultDevelopmentEnvironmentMigrationError: Error, LocalizedError {
    case destinationConflict
    case logDestinationConflict

    var errorDescription: String? {
        switch self {
        case .destinationConflict:
            return "Both shared and development Vault Classifier state directories exist; the one-time move stopped without merging them."
        case .logDestinationConflict:
            return "Both shared and development Vault Classifier log directories exist; the one-time move stopped without merging them."
        }
    }
}
