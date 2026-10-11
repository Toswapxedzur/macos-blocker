import Foundation
import VaultClassifierCore

/// Owns the context/model cleanup independently of Swift references to an
/// engine. Explicit actor-serialized shutdown and deinit share this once-only
/// release. The closure frees the context (which synchronizes backend work)
/// before the model; it never unloads a process-global backend.
final class LLMEngineResources: @unchecked Sendable {
    let shutdown: ClassifierShutdownSignal
    private let lock = NSLock()
    private var release: (() -> Void)?
    init(shutdown: ClassifierShutdownSignal, release: @escaping () -> Void) {
        self.shutdown = shutdown
        self.release = release
    }
    func close() {
        shutdown.request()
        let release = lock.withLock { () -> (() -> Void)? in
            defer { self.release = nil }
            return self.release
        }
        release?()
    }
    deinit { close() }
}
