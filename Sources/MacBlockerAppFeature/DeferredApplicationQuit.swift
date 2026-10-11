#if os(macOS)
import AppKit

/// Owns AppKit's one deferred reply. Confirmation runs before starting any
/// shutdown; repeated Quit requests cannot confirm or start cleanup again.
@MainActor
final class DeferredApplicationQuit {
    private(set) var task: Task<Void, Never>?
    func request(confirm: () -> Bool, shutdown: @escaping () async -> Void,
                 reply: @escaping () -> Void) -> NSApplication.TerminateReply {
        if task != nil { return .terminateLater }
        guard confirm() else { return .terminateCancel }
        task = Task { @MainActor in
            await shutdown()
            reply()
        }
        return .terminateLater
    }
}
#endif
