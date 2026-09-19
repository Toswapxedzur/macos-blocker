import Foundation
import VaultClassifierCore

/// Resolves (and creates) this environment's Vault Classifier support directory.
/// The development environment has its own directory, isolated from production.
enum VaultClassifierDirectory {
    static func prepare(fileManager: FileManager = .default) throws -> URL {
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = appSupport.appendingPathComponent(
            VaultRuntimeEnvironment.current.classifierSupportDirectoryName,
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
