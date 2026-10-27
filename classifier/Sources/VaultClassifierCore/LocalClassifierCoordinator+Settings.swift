import Foundation

// Settings, backup configuration, workspace catalog and knowledge-entry updates.
// Split out of LocalStore.swift (CLASSIFIER-INDEPENDENCE §7, Phase 5):
// same type, same behaviour.
extension LocalClassifierCoordinator {

    public func updateSettings(_ settings: ClassifierSettings) throws {
        lock.lock()
        defer { lock.unlock() }
        var next = state
        next.settings = settings
        try stateFile.save(next)
        state = next
    }

    public func updateLocalBackupConfiguration(_ configuration: LocalBackupConfiguration?) throws {
        lock.lock()
        defer { lock.unlock() }
        if let configuration, configuration.isEnabled { _ = try configuration.directoryURL() }
        state.backupConfiguration = configuration
        try stateFile.save(state)
    }

    public func updateWorkspaceCatalog(_ catalog: WorkspaceCatalog) throws {
        lock.lock()
        defer { lock.unlock() }
        var reconciled = catalog
        reconciled.reconcileClassifierTypes()
        try reconciled.validate()
        state.workspaceCatalog = reconciled
        try stateFile.save(state)
    }

}
