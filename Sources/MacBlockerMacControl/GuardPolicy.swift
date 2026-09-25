import Foundation

/// The cross-process, JavaScript-free block policy shared between the control
/// plane (the editor app) and the always-on enforcement core (the Endpoint
/// Security system extension / privileged daemon).
///
/// The app *compiles* this from the user's groups (`EnforcementPlan` /
/// `[PolicyDecision]`) and writes it to a root-owned store; the enforcement core
/// only *reads* it. It is deliberately small and `Codable` so it can be parsed
/// inside an extension with a tight memory budget.
public struct GuardPolicy: Codable, Equatable, Sendable {
    public var version: Int
    public var generatedAt: Date
    public var targets: [GuardTarget]
    /// Bundle identifiers that must NEVER be blocked/killed regardless of a
    /// match (the blocker's own app/extension, plus anything the caller wants to
    /// hard-allow). Apple platform binaries are always protected (see
    /// `isProtected`) independent of this set.
    public var protectedBundleIdentifiers: Set<String>
    /// "Block every application except these" groups that block right now: a
    /// candidate not in a list's allowed set matches that list (and is blocked
    /// with its mode). Protected and browser processes are never matched.
    public var allowOnly: [GuardAllowlist]

    public init(
        version: Int = 1,
        generatedAt: Date = Date(),
        targets: [GuardTarget] = [],
        protectedBundleIdentifiers: Set<String> = [],
        allowOnly: [GuardAllowlist] = []
    ) {
        self.version = version
        self.generatedAt = generatedAt
        self.targets = targets
        self.protectedBundleIdentifiers = protectedBundleIdentifiers
        self.allowOnly = allowOnly
    }

    // Policies written before allowlists existed decode with none.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        generatedAt = try c.decode(Date.self, forKey: .generatedAt)
        targets = try c.decode([GuardTarget].self, forKey: .targets)
        protectedBundleIdentifiers = try c.decode(Set<String>.self, forKey: .protectedBundleIdentifiers)
        allowOnly = try c.decodeIfPresent([GuardAllowlist].self, forKey: .allowOnly) ?? []
    }

    /// Bundle-id prefixes that are structurally off-limits. Killing these as
    /// root could take down the login session or the OS, so they are never
    /// matched even if a (mis)configured target would otherwise match.
    public static let alwaysProtectedPrefixes: [String] = [
        "com.apple."
    ]

    public func isProtected(bundleIdentifier: String?) -> Bool {
        guard let bundleID = bundleIdentifier, !bundleID.isEmpty else {
            // A process with no resolvable bundle id is treated as protected:
            // we never SIGKILL something we can't positively identify.
            return true
        }
        if protectedBundleIdentifiers.contains(bundleID) {
            return true
        }
        let lowered = bundleID.lowercased()
        // A protected app's helpers (`<id>.helper`) are protected with it.
        if protectedBundleIdentifiers.contains(where: { lowered.hasPrefix($0.lowercased() + ".") }) {
            return true
        }
        return Self.alwaysProtectedPrefixes.contains { lowered.hasPrefix($0) }
    }

    /// Returns the matching target for a candidate process, or `nil` if it
    /// should be allowed. Protected processes always return `nil`.
    public func match(
        bundleIdentifier: String?,
        teamIdentifier: String? = nil,
        signingIdentifier: String? = nil,
        executablePath: String? = nil
    ) -> GuardTarget? {
        if isProtected(bundleIdentifier: bundleIdentifier) {
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
        // An allowlist group blocks whatever it does not name. Browsers stay
        // the extension's business, as everywhere else in the native policy.
        guard let bundleID = bundleIdentifier, !bundleID.isEmpty,
              !MacProcessTerminator.isBrowserBundleIdentifier(bundleID) else { return nil }
        for list in allowOnly where !list.allows(bundleIdentifier: bundleID) {
            return GuardTarget(
                bundleIdentifier: bundleID,
                bundleIdentifierPrefixes: [],
                enforcementMode: list.enforcementMode,
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

    /// Should Endpoint Security deny `exec` of this candidate?
    public func shouldDenyLaunch(
        bundleIdentifier: String?,
        teamIdentifier: String? = nil,
        signingIdentifier: String? = nil,
        executablePath: String? = nil
    ) -> Bool {
        match(
            bundleIdentifier: bundleIdentifier,
            teamIdentifier: teamIdentifier,
            signingIdentifier: signingIdentifier,
            executablePath: executablePath
        )?.enforcementMode.preventsLaunch ?? false
    }
}

/// One "block every application except these" group that blocks right now.
public struct GuardAllowlist: Codable, Equatable, Sendable {
    public var allowedBundleIdentifiers: Set<String>
    public var enforcementMode: MacEnforcementMode
    public var displayName: String

    public init(allowedBundleIdentifiers: Set<String>, enforcementMode: MacEnforcementMode, displayName: String) {
        self.allowedBundleIdentifiers = Set(allowedBundleIdentifiers.map { $0.lowercased() })
        self.enforcementMode = enforcementMode
        self.displayName = displayName
    }

    /// An allowed app's helpers (`<id>.helper`) are allowed with it, like the
    /// prefix match on a blocked `GuardTarget`.
    public func allows(bundleIdentifier: String) -> Bool {
        let id = bundleIdentifier.lowercased()
        return allowedBundleIdentifiers.contains(id) ||
            allowedBundleIdentifiers.contains { id.hasPrefix($0 + ".") }
    }
}

/// One blocked application, expressed with multiple match keys so it cannot be
/// trivially dodged by renaming/moving the binary. A candidate process matches
/// if it matches *any* configured key.
public struct GuardTarget: Codable, Equatable, Sendable {
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
    public var enforcementMode: MacEnforcementMode
    /// Human-readable, for logs/UI.
    public var displayName: String

    public init(
        bundleIdentifier: String,
        bundleIdentifierPrefixes: [String] = [],
        teamIdentifier: String? = nil,
        signingIdentifier: String? = nil,
        executablePaths: [String] = [],
        enforcementMode: MacEnforcementMode = .forceTerminate,
        displayName: String = ""
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.bundleIdentifierPrefixes = bundleIdentifierPrefixes
        self.teamIdentifier = teamIdentifier
        self.signingIdentifier = signingIdentifier
        self.executablePaths = executablePaths.map { ($0 as NSString).standardizingPath }
        self.enforcementMode = enforcementMode
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
