import Foundation
import VaultClassifierCore

/// Resolves (and creates) this environment's Vault Classifier support directory.
/// The development environment has its own directory, isolated from production.
enum VaultClassifierDirectory {
    static func prepare(fileManager: FileManager = .default) throws -> URL {
        try VaultRuntimeEnvironment.current.classifierSupportDirectoryURL(fileManager: fileManager)
    }
}
