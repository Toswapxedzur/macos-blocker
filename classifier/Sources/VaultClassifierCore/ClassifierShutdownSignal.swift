import Foundation

/// A permanent, thread-safe admission/cancellation signal. It can be set while
/// an engine actor is inside a synchronous native call; resources are still
/// released only on that actor, after the call returns.
public final class ClassifierShutdownSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false
    public init() {}
    public var isRequested: Bool { lock.withLock { requested } }
    public func request() { lock.withLock { requested = true } }
    public func checkCancellation() throws {
        if isRequested || Task<Never, Never>.isCancelled { throw CancellationError() }
    }
}
