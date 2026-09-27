import Foundation

#if os(macOS)
import AppKit
import Darwin
#endif

/// A snapshot of one running process, reduced to the fields the policy matches
/// on. Kept separate from `NSRunningApplication` so the *selection* logic is
/// pure and unit-testable without quitting anything.
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

/// One running process a policy blocks.
public struct BlockedProcess: Equatable, Sendable {
    public var processIdentifier: Int32
    public var bundleIdentifier: String?

    public init(processIdentifier: Int32, bundleIdentifier: String?) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
    }
}

/// Finds the running applications a policy blocks. Quitting them is
/// `QuitRequests`: normally, never by force.
public enum BlockedProcesses {
    /// Browsers are owned by their extensions. The native app never blocks,
    /// closes or hides them or their helper processes.
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

    /// The selection — the sweep's and the tests' one path: which running
    /// processes the policy blocks. Code-signing identity is read (through
    /// `signing`, comparatively expensive) only when a target matches on it
    /// and the cheap bundle-id/path match isn't decisive.
    public static func plan(
        policy: GuardPolicy,
        running: [RunningProcessSnapshot],
        signing: (String) -> (team: String?, identifier: String?)? = { _ in nil }
    ) -> [BlockedProcess] {
        running.compactMap { proc -> BlockedProcess? in
            var candidate = proc
            if policy.usesCodeSigningMatch,
               policy.match(bundleIdentifier: proc.bundleIdentifier, executablePath: proc.executablePath) == nil,
               let path = proc.executablePath, let info = signing(path) {
                candidate.teamIdentifier = info.team
                candidate.signingIdentifier = info.identifier
            }
            guard policy.match(
                bundleIdentifier: candidate.bundleIdentifier,
                teamIdentifier: candidate.teamIdentifier,
                signingIdentifier: candidate.signingIdentifier,
                executablePath: candidate.executablePath
            ) != nil else {
                return nil
            }
            return BlockedProcess(processIdentifier: proc.processIdentifier, bundleIdentifier: proc.bundleIdentifier)
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

    /// The running processes this policy blocks.
    public static func running(policy: GuardPolicy) -> [NSRunningApplication] {
        let apps = snapshotRunningApplications()
        let chosen = Set(plan(policy: policy, running: apps.map(\.snapshot), signing: signingInfo).map(\.processIdentifier))
        return apps.filter { chosen.contains($0.snapshot.processIdentifier) }.map(\.app)
    }

    /// Code-signing identity per executable path, read once (the sweep runs
    /// every second; an app's signature doesn't change while it is installed).
    nonisolated(unsafe) private static var signingCache: [String: (team: String?, identifier: String?)?] = [:]
    private static let signingLock = NSLock()
    private static func signingInfo(_ path: String) -> (team: String?, identifier: String?)? {
        signingLock.lock()
        if let cached = signingCache[path] { signingLock.unlock(); return cached }
        signingLock.unlock()
        let info = MacCodeSigning.info(forItemAt: path).map { (team: $0.teamIdentifier, identifier: $0.signingIdentifier) }
        signingLock.lock(); signingCache[path] = .some(info); signingLock.unlock()
        return info
    }
    #endif
}
