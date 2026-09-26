import Foundation
import MacBlockerCore

/// The compiled app-block policy: which running processes the quit sweep
/// asks to quit (`AppBlockPolicy` builds it from the groups).
public struct GuardPolicy: Equatable, Sendable {
    public var targets: [GuardTarget]
    /// "Block every application except these" groups that block right now: a
    /// candidate not in a list's allowed set matches that list (and is blocked).
    public var allowOnly: [GuardAllowlist]

    public init(targets: [GuardTarget] = [], allowOnly: [GuardAllowlist] = []) {
        self.targets = targets
        self.allowOnly = allowOnly
    }

    /// Vault itself: a block never touches it (matters once an allowlist
    /// group blocks "everything except").
    public static let ownBundleIdentifier = Bundle.main.bundleIdentifier

    /// The one test of whether a block can act on an app — the quit sweep, a
    /// rule's close, time counting, the app picker and the quick-add "+" all
    /// use it (owner 2026-09-26: don't offer apps the Mac never blocks). Never
    /// Apple's own (`com.apple.*`: quitting those can take down the session), a
    /// browser (its extension blocks inside it), Vault itself — each with its
    /// helpers — nor a process with no bundle id we can't identify.
    public static func canBlock(_ bundleIdentifier: String?) -> Bool {
        guard let bundleID = bundleIdentifier, !bundleID.isEmpty else { return false }
        let lowered = bundleID.lowercased()
        if lowered.hasPrefix("com.apple.") || MacProcessTerminator.isBrowserBundleIdentifier(bundleID) { return false }
        if let own = ownBundleIdentifier?.lowercased(), lowered == own || lowered.hasPrefix(own + ".") { return false }
        return true
    }

    /// Returns the matching target for a candidate process, or `nil` if it
    /// should be allowed. An app no block can act on always returns `nil`.
    public func match(
        bundleIdentifier: String?,
        teamIdentifier: String? = nil,
        signingIdentifier: String? = nil,
        executablePath: String? = nil
    ) -> GuardTarget? {
        guard Self.canBlock(bundleIdentifier), let bundleID = bundleIdentifier else {
            return nil
        }
        if let target = targets.first(where: {
            $0.matches(
                bundleIdentifier: bundleIdentifier,
                teamIdentifier: teamIdentifier,
                signingIdentifier: signingIdentifier,
                executablePath: executablePath
            )
        }) {
            return target
        }
        // An allowlist group blocks whatever it does not name.
        for list in allowOnly where !list.allows(bundleIdentifier: bundleID) {
            return GuardTarget(
                bundleIdentifier: bundleID,
                bundleIdentifierPrefixes: [],
                displayName: list.displayName
            )
        }
        return nil
    }

    /// Whether any target matches on code-signing identity. When false, the
    /// terminator can skip the (comparatively expensive) `SecStaticCode` read
    /// during its periodic sweep.
    public var usesCodeSigningMatch: Bool {
        targets.contains { $0.teamIdentifier != nil || $0.signingIdentifier != nil }
    }
}

/// One "block every application except these" group that blocks right now.
public struct GuardAllowlist: Equatable, Sendable {
    public var allowedBundleIdentifiers: Set<String>
    public var displayName: String

    public init(allowedBundleIdentifiers: Set<String>, displayName: String) {
        self.allowedBundleIdentifiers = Set(allowedBundleIdentifiers.map { $0.lowercased() })
        self.displayName = displayName
    }

    /// An allowed app's helpers (`<id>.helper`) are allowed with it, like the
    /// prefix match on a blocked `GuardTarget`.
    public func allows(bundleIdentifier: String) -> Bool {
        BlockGroup.allowlist(allowedBundleIdentifiers, allows: bundleIdentifier)
    }
}

/// One blocked application, expressed with multiple match keys so it cannot be
/// trivially dodged by renaming/moving the binary. A candidate process matches
/// if it matches *any* configured key.
public struct GuardTarget: Equatable, Sendable {
    /// Primary identity (e.g. `com.google.Chrome`). Matched case-insensitively.
    public var bundleIdentifier: String
    /// Bundle-id prefixes that also match — catches helper/renderer processes
    /// (e.g. `com.google.Chrome.helper`). Matched case-insensitively.
    public var bundleIdentifierPrefixes: [String]
    /// Optional code-signing Team ID. When set, any process from this team
    /// matches (covers all helpers/variants from one vendor). Opt-in because it
    /// is broad.
    public var teamIdentifier: String?
    /// Optional code-signing identifier (e.g. `com.google.Chrome`).
    public var signingIdentifier: String?
    /// Absolute executable/bundle paths that match (standardized).
    public var executablePaths: [String]
    /// Human-readable, for logs/UI.
    public var displayName: String

    public init(
        bundleIdentifier: String,
        bundleIdentifierPrefixes: [String] = [],
        teamIdentifier: String? = nil,
        signingIdentifier: String? = nil,
        executablePaths: [String] = [],
        displayName: String = ""
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.bundleIdentifierPrefixes = bundleIdentifierPrefixes
        self.teamIdentifier = teamIdentifier
        self.signingIdentifier = signingIdentifier
        self.executablePaths = executablePaths.map { ($0 as NSString).standardizingPath }
        self.displayName = displayName.isEmpty ? bundleIdentifier : displayName
    }

    public func matches(
        bundleIdentifier candBundle: String?,
        teamIdentifier candTeam: String? = nil,
        signingIdentifier candSigning: String? = nil,
        executablePath candPath: String? = nil
    ) -> Bool {
        if let candBundle, !candBundle.isEmpty {
            if candBundle.caseInsensitiveCompare(bundleIdentifier) == .orderedSame {
                return true
            }
            let loweredCand = candBundle.lowercased()
            if bundleIdentifierPrefixes.contains(where: { loweredCand.hasPrefix($0.lowercased()) }) {
                return true
            }
        }
        if let teamIdentifier, let candTeam, !candTeam.isEmpty,
           teamIdentifier == candTeam {
            return true
        }
        if let signingIdentifier, let candSigning, !candSigning.isEmpty,
           signingIdentifier == candSigning {
            return true
        }
        if let candPath, !candPath.isEmpty {
            let standardized = (candPath as NSString).standardizingPath
            if executablePaths.contains(standardized) {
                return true
            }
        }
        return false
    }
}
