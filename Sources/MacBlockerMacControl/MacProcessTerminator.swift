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

/// One enforcement action the terminator decided to take, for logging/tests.
public struct TerminationAction: Equatable, Sendable {
    public var processIdentifier: Int32
    public var bundleIdentifier: String?
    public var action: MacEnforcementMode.RunningAction

    public init(
        processIdentifier: Int32,
        bundleIdentifier: String?,
        action: MacEnforcementMode.RunningAction
    ) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.action = action
    }
}

/// Kills / suspends / hides already-running blocked applications. This is the
/// "Layer 2" of the enforcement ladder that complements Endpoint Security's
/// launch-prevention: it catches apps that were already running when a block
/// turned on (schedule start, limit exceeded, rule fired).
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
    /// which to act on and how. No side effects — safe to unit test.
    public static func plan(
        policy: GuardPolicy,
        running: [RunningProcessSnapshot]
    ) -> [TerminationAction] {
        running.compactMap { proc -> TerminationAction? in
            guard !isBrowserBundleIdentifier(proc.bundleIdentifier) else {
                return nil
            }
            guard let target = policy.match(
                bundleIdentifier: proc.bundleIdentifier,
                teamIdentifier: proc.teamIdentifier,
                signingIdentifier: proc.signingIdentifier,
                executablePath: proc.executablePath
            ) else {
                return nil
            }
            let action = target.enforcementMode.runningAction
            guard action != .none else { return nil }
            return TerminationAction(
                processIdentifier: proc.processIdentifier,
                bundleIdentifier: proc.bundleIdentifier,
                action: action
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

            guard let target = policy.match(
                bundleIdentifier: enriched.bundleIdentifier,
                teamIdentifier: enriched.teamIdentifier,
                signingIdentifier: enriched.signingIdentifier,
                executablePath: enriched.executablePath
            ) else {
                continue
            }

            let action = target.enforcementMode.runningAction
            apply(action, to: app)
            if action != .none {
                taken.append(
                    TerminationAction(
                        processIdentifier: app.processIdentifier,
                        bundleIdentifier: app.bundleIdentifier,
                        action: action
                    )
                )
            }
        }
        return taken
    }

    /// Terminates all processes matching the given bundle identifier.
    public static func terminate(bundleIdentifier: String) {
        guard !isBrowserBundleIdentifier(bundleIdentifier) else { return }
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == bundleIdentifier
        }
        for app in apps {
            app.terminate()
        }
    }

    private static func apply(_ action: MacEnforcementMode.RunningAction, to app: NSRunningApplication) {
        switch action {
        case .none:
            return
        case .hide:
            app.hide()
        case .switchAway:
            app.hide()
            NSWorkspace.shared.frontmostApplication?.hide()
        case .gracefulTerminate:
            app.terminate()
        case .forceKill:
            // SIGKILL is unblockable and immediate; forceTerminate() is the
            // AppKit fallback if signalling somehow fails.
            if kill(app.processIdentifier, SIGKILL) != 0 {
                app.forceTerminate()
            }
        case .suspend:
            kill(app.processIdentifier, SIGSTOP)
        }
    }
    #endif
}
