import Foundation
import VaultActivityCore

extension ActivityStore {
    /// The store under this environment's application-support tree
    /// (`~/Library/Application Support/macosBlocker[-Development]/Activity`).
    public static func standard(
        environment: VaultRuntimeEnvironment = .current,
        fileManager: FileManager = .default
    ) -> ActivityStore {
        let support = (try? fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? fileManager.temporaryDirectory
        let directory = support
            .appendingPathComponent(environment.sharedStoreDirectoryName, isDirectory: true)
            .appendingPathComponent("Activity", isDirectory: true)
        return ActivityStore(directory: directory)
    }

}
