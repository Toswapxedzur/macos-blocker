import Foundation

#if os(macOS)
import AppKit
import Darwin
#endif

/// A snapshot of one running process, reduced to the fields the policy matches
/// on. Kept separate from `NSRunningApplication` so the *selection* logic is
/// pure and unit-testable without actually killing anything.
public struct RunningProcessSnapshot: Equatable, Sendable {
    public var processIdentifier: Int32
    public var bundleIdentifier: String?
    public var teamIdentifier: String?
    public var signingIdentifier: String?
    public var executablePath: String?

    public init(
        processIdentifier: Int32,
        bundleIdentifier: String?,
        teamIdentifier: String? = nil,
        signingIdentifier: String? = nil,
        executablePath: String? = nil
    ) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.teamIdentifier = teamIdentifier
        self.signingIdentifier = signingIdentifier
        self.executablePath = executablePath
    }
}

/// One blocked process the terminator killed (or would kill), for logging/tests.
public struct TerminationAction: Equatable, Sendable {
    public var processIdentifier: Int32
    public var bundleIdentifier: String?

    public init(processIdentifier: Int32, bundleIdentifier: String?) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
    }
}

/// Kills blocked applications that are running. A block has one form: the
/// app is force-quit (SIGKILL) every time it runs — at the block's start, on
/// relaunch (the sweep repeats each second), whatever turned the block on.
public enum MacProcessTerminator {
    /// Browsers are owned by their extensions. The native app never blocks,
    /// closes, hides, suspends, or kills them or their helper processes.
    public static let browserBundleIdentifiers: Set<String> = [
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
        "com.google.Chrome",
        "com.google.Chrome.beta",
        "com.google.Chrome.canary",
        "com.google.Chrome.dev",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi",
        "company.thebrowser.Browser",
        "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition"
    ]

    public static func isBrowserBundleIdentifier(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return false }
        return browserBundleIdentifiers.contains(bundleIdentifier) ||
            browserBundleIdentifiers.contains { bundleIdentifier.hasPrefix($0 + ".") }
    }

    /// Pure selection: given a policy and a set of running processes, decide
    /// which to kill. No side effects — safe to unit test.
    public static func plan(
        policy: GuardPolicy,
        running: [RunningProcessSnapshot]
    ) -> [TerminationAction] {
        running.compactMap { proc -> TerminationAction? in
            guard !isBrowserBundleIdentifier(proc.bundleIdentifier) else {
                return nil
            }
            guard policy.match(
                bundleIdentifier: proc.bundleIdentifier,
                teamIdentifier: proc.teamIdentifier,
                signingIdentifier: proc.signingIdentifier,
                executablePath: proc.executablePath
            ) != nil else {
                return nil
            }
            return TerminationAction(
                processIdentifier: proc.processIdentifier,
                bundleIdentifier: proc.bundleIdentifier
            )
        }
    }

    #if os(macOS)
    /// Snapshots currently running applications (regular + accessory) with
    /// their bundle id and executable path. Signing info is filled lazily by
    /// the caller only when needed (it is comparatively expensive).
    public static func snapshotRunningApplications() -> [(app: NSRunningApplication, snapshot: RunningProcessSnapshot)] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.processIdentifier > 0 else { return nil }
            let path = app.bundleURL?.standardizedFileURL.path ?? app.executableURL?.standardizedFileURL.path
            let snapshot = RunningProcessSnapshot(
                processIdentifier: app.processIdentifier,
                bundleIdentifier: app.bundleIdentifier,
                teamIdentifier: nil,
                signingIdentifier: nil,
                executablePath: path
            )
            return (app, snapshot)
        }
    }

    /// Sweeps running applications and enforces the policy. Returns the actions
    /// taken (also useful for logging). Protected processes are skipped by the
    /// policy's own guardrails.
    @discardableResult
    public static func enforce(policy: GuardPolicy) -> [TerminationAction] {
        var taken: [TerminationAction] = []
        let needsSigning = policy.usesCodeSigningMatch
        for (app, snapshot) in snapshotRunningApplications() {
            guard !isBrowserBundleIdentifier(snapshot.bundleIdentifier) else {
                continue
            }
            // Resolve signing info only if some target matches on team/signing
            // AND a cheap bundle-id/path match isn't already decisive — keeps
            // the periodic sweep cheap for the common bundle-id-only case.
            var enriched = snapshot
            if needsSigning,
               policy.match(
                bundleIdentifier: snapshot.bundleIdentifier,
                executablePath: snapshot.executablePath
            ) == nil,
               let path = snapshot.executablePath,
               let signing = MacCodeSigning.info(forItemAt: path) {
                enriched.teamIdentifier = signing.teamIdentifier
                enriched.signingIdentifier = signing.signingIdentifier
            }

            guard policy.match(
                bundleIdentifier: enriched.bundleIdentifier,
                teamIdentifier: enriched.teamIdentifier,
                signingIdentifier: enriched.signingIdentifier,
                executablePath: enriched.executablePath
            ) != nil else {
                continue
            }

            forceKill(app)
            taken.append(
                TerminationAction(processIdentifier: app.processIdentifier, bundleIdentifier: app.bundleIdentifier)
            )
        }
        return taken
    }

    /// Force-quits every running instance of a blocked app (a rule's blockApp).
    public static func forceKill(bundleIdentifier: String) {
        guard !isBrowserBundleIdentifier(bundleIdentifier) else { return }
        for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier == bundleIdentifier {
            forceKill(app)
        }
    }

    /// Asks every running instance to quit (a rule's "close": not a block).
    public static func terminate(bundleIdentifier: String) {
        guard !isBrowserBundleIdentifier(bundleIdentifier) else { return }
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == bundleIdentifier
        }
        for app in apps {
            app.terminate()
        }
    }

    private static func forceKill(_ app: NSRunningApplication) {
        // SIGKILL is unblockable and immediate; forceTerminate() is the AppKit
        // fallback if signalling somehow fails.
        if kill(app.processIdentifier, SIGKILL) != 0 {
            app.forceTerminate()
        }
    }
    #endif
}
