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

/// One blocked process, for logging/tests.
public struct TerminationAction: Equatable, Sendable {
    public var processIdentifier: Int32
    public var bundleIdentifier: String?

    public init(processIdentifier: Int32, bundleIdentifier: String?) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
    }
}

/// Finds the running applications a policy blocks. Quitting them is
/// `QuitRequests`: normally, never by force.
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
    /// which are blocked. No side effects — safe to unit test.
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

    /// The running processes this policy blocks (protected ones never match).
    public static func blockedProcesses(policy: GuardPolicy) -> [NSRunningApplication] {
        let needsSigning = policy.usesCodeSigningMatch
        return snapshotRunningApplications().compactMap { app, snapshot in
            guard !isBrowserBundleIdentifier(snapshot.bundleIdentifier) else { return nil }
            // Signing info only when a cheap bundle-id/path match isn't decisive.
            var enriched = snapshot
            if needsSigning,
               policy.match(bundleIdentifier: snapshot.bundleIdentifier, executablePath: snapshot.executablePath) == nil,
               let path = snapshot.executablePath,
               let signing = MacCodeSigning.info(forItemAt: path) {
                enriched.teamIdentifier = signing.teamIdentifier
                enriched.signingIdentifier = signing.signingIdentifier
            }
            return policy.match(bundleIdentifier: enriched.bundleIdentifier, teamIdentifier: enriched.teamIdentifier,
                                signingIdentifier: enriched.signingIdentifier, executablePath: enriched.executablePath) != nil
                ? app : nil
        }
    }
    #endif
}
