import Foundation

// Signed model-package activation/rollback and local backups.
// Split out of LocalStore.swift (CLASSIFIER-INDEPENDENCE §7, Phase 5):
// same type, same behaviour.
extension LocalClassifierCoordinator {
    @discardableResult
    public func backupLocalModelNow(at date: Date = .now) throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        guard let configuration = state.backupConfiguration, configuration.isEnabled else {
            throw LocalBackupError.backupDisabled
        }
        return try LocalModelBackup().backup(
            state: state,
            package: activeVerifiedPackage,
            in: configuration.directoryURL(),
            at: date
        )
    }

    public func activateVerifiedModelPackage(_ verifiedPackage: VerifiedModelPackage) throws {
        try replacePackage(verifiedPackage, disposition: .forward)
    }

    public func activateRecordedRollbackModelPackage(_ verifiedPackage: VerifiedModelPackage) throws {
        try replacePackage(verifiedPackage, disposition: .explicitRollback)
    }

    func replacePackage(
        _ verifiedPackage: VerifiedModelPackage,
        disposition: SignedActivationDisposition
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        let manifest = verifiedPackage.manifest
        let identity = ActiveModelIdentity(
            kind: .signedPackage,
            packageID: manifest.packageID,
            taxonomyVersion: manifest.taxonomyVersion,
            modelVersion: manifest.modelVersion,
            seedChecksum: nil,
            releaseSequence: manifest.releaseSequence,
            payloadSHA256: manifest.payloadSHA256
        )
        guard identity.isStructurallyValid else { throw PackageManifestValidationError.storedPackageMismatch }
        let stamp = PackageReleaseStamp(manifest: manifest)
        switch disposition {
        case .forward:
            if let highWater = state.highestAcceptedSignedRelease, !stamp.isStrictlyNewer(than: highWater) {
                throw PackageManifestValidationError.nonMonotonicUpdate(current: highWater, candidate: stamp)
            }
        case .explicitRollback:
            guard state.signedRollbackIdentities.contains(identity) else {
                throw PackageManifestValidationError.nonMonotonicUpdate(
                    current: state.highestAcceptedSignedRelease ?? stamp,
                    candidate: stamp
                )
            }
        }
        if let current = state.activeModelIdentity, current.kind == .signedPackage {
            state.rememberSignedIdentityForRollback(current)
        }
        state.activeModelIdentity = identity
        if disposition == .forward { state.highestAcceptedSignedRelease = stamp }
        state.rememberSignedIdentityForRollback(identity)
        try stateFile.save(state)
        activeVerifiedPackage = verifiedPackage.seedPackage
    }
}
