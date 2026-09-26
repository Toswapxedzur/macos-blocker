import Foundation

#if os(macOS)
import AppKit

/// Quits blocked apps — normally, never by force (owner 2026-09-26). An app is
/// asked to quit like the user pressing ⌘Q, so it can keep unsaved work; one
/// that stays open is left open and asked again only after the retry interval
/// (Settings, in minutes; 0 = never). Each launch of an app (its process) is
/// asked once, not every sweep. A custom rule's "close" goes the same way.
public final class QuitRequests: @unchecked Sendable {
    private let lock = NSLock()
    /// Process → when it was last asked to quit.
    private var askedAt: [pid_t: Date] = [:]
    /// Processes a rule closed: asked (and retried) until they quit, blocked or not.
    private var closing: Set<pid_t> = []

    public init() {}

    /// Asks every blocked process that wasn't asked yet (or whose retry is due).
    @discardableResult
    public func sweep(blocked: [NSRunningApplication], retry: TimeInterval, now: Date) -> [TerminationAction] {
        let running = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
        let blockedIDs = Set(blocked.map(\.processIdentifier))
        lock.lock()
        // Forget processes that quit, and ones no longer blocked or closing.
        askedAt = askedAt.filter { pid, _ in running.contains(pid) && (blockedIDs.contains(pid) || closing.contains(pid)) }
        closing = closing.intersection(running)
        let closingApps = NSWorkspace.shared.runningApplications.filter { closing.contains($0.processIdentifier) }
        var due: [NSRunningApplication] = []
        for app in blocked + closingApps where !due.contains(where: { $0.processIdentifier == app.processIdentifier }) {
            guard let asked = askedAt[app.processIdentifier] else { due.append(app); continue }
            if retry > 0, now.timeIntervalSince(asked) >= retry { due.append(app) }
        }
        for app in due { askedAt[app.processIdentifier] = now }
        lock.unlock()
        for app in due { app.terminate() }
        return due.map { TerminationAction(processIdentifier: $0.processIdentifier, bundleIdentifier: $0.bundleIdentifier) }
    }

    /// A rule's close: every running instance of the app is asked now and,
    /// while it stays open, again after each retry interval.
    public func close(bundleIdentifier: String, now: Date) {
        guard !MacProcessTerminator.isBrowserBundleIdentifier(bundleIdentifier) else { return }
        let apps = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == bundleIdentifier }
        lock.lock()
        for app in apps {
            closing.insert(app.processIdentifier)
            askedAt[app.processIdentifier] = now
        }
        lock.unlock()
        for app in apps { app.terminate() }
    }
}
#endif
