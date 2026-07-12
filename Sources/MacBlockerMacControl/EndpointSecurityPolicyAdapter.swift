import Foundation
import MacBlockerCore

/// The macOS "maximum security" policy applier. It combines every blocking
/// layer for each shielded target:
///
/// 1. **Prevent launch** — compiles a `GuardPolicy`, persists it to a
///    root-owned store, and pushes it to the Endpoint Security client so the
///    app can't `exec`.
/// 2. **Kill if running** — sweeps running processes and SIGKILLs / suspends /
///    terminates anything already open (covers apps started before the block).
///
/// The editor uses this as its primary `PolicyApplying` implementation on
/// macOS; `MacControlPolicyAdapter` remains as the soft, foreground-only
/// fallback.
public actor EndpointSecurityPolicyAdapter: PolicyApplying {
    public let capabilities: PlatformCapabilities = .macOS

    private let store: GuardPolicyStore
    private let client: EndpointSecurityClient?
    private let defaultMode: MacEnforcementMode
    private let protectedBundleIdentifiers: Set<String>
    private let runTerminationSweep: Bool

    /// Active blocks keyed by bundle id → chosen enforcement mode.
    private var activeModes: [String: MacEnforcementMode] = [:]
    private var lastPolicy = GuardPolicy()

    /// Metadata key a `PolicyDecision` can set to override the enforcement mode
    /// for its targets (raw value of `MacEnforcementMode`).
    public static let enforcementMetadataKey = "macEnforcement"

    public init(
        store: GuardPolicyStore = GuardPolicyStore(),
        client: EndpointSecurityClient? = nil,
        defaultMode: MacEnforcementMode = .forceTerminate,
        protectedBundleIdentifiers: Set<String> = [],
        runTerminationSweep: Bool = true
    ) {
        self.store = store
        self.client = client
        self.defaultMode = defaultMode
        self.protectedBundleIdentifiers = protectedBundleIdentifiers.union(MacProcessTerminator.browserBundleIdentifiers)
        self.runTerminationSweep = runTerminationSweep
    }

    public func apply(_ decisions: [PolicyDecision]) async throws {
        for decision in decisions {
            switch decision.action {
            case .shield:
                let mode = Self.mode(from: decision, default: defaultMode)
                for id in decision.targetIDs {
                    guard !MacProcessTerminator.isBrowserBundleIdentifier(id) else { continue }
                    activeModes[id] = mode
                }
            case .allow, .unshield:
                for id in decision.targetIDs {
                    activeModes.removeValue(forKey: id)
                }
            case .showStatus, .requestSnooze, .log, .quarantine:
                continue
            }
        }

        let policy = buildPolicy()
        lastPolicy = policy
        try store.save(policy)
        client?.update(policy: policy)

        #if os(macOS)
        if runTerminationSweep {
            MacProcessTerminator.enforce(policy: policy)
        }
        #endif
    }

    /// Evaluates the user's groups against the current schedule + usage and
    /// compiles only the *currently-blocked* application targets into the guard
    /// policy. This is the correct enforcement entry point: it honors each
    /// group's mode (instant vs timed), active days / time windows, snooze, and
    /// enabled flag — so a timer group does NOT block until its limit is
    /// exhausted, and a scheduled group only blocks inside its window.
    ///
    /// Safe to call frequently: when the resulting block set is unchanged it
    /// skips the (costly) policy rebuild and just re-runs the kill sweep, so a
    /// timer can drive schedule/limit transitions cheaply.
    public func applyGroups(
        _ groups: [BlockGroup],
        usage: UsageSnapshot,
        now: Date = Date(),
        calendar: Calendar = .current,
        mode: MacEnforcementMode? = nil,
        customBlockedBundleIDs: Set<String> = []
    ) async throws {
        let resolved = mode ?? defaultMode
        var modes = Self.blockedApplicationModes(
            groups: groups,
            usage: usage,
            now: now,
            calendar: calendar,
            mode: resolved
        )

        // Merge in bundle IDs shielded by custom-rule decisions.
        for bundleID in customBlockedBundleIDs {
            guard !MacProcessTerminator.isBrowserBundleIdentifier(bundleID) else { continue }
            modes[bundleID] = resolved
        }

        // Unchanged set → no rebuild/inventory scan; just keep enforcing.
        if modes == activeModes {
            #if os(macOS)
            if runTerminationSweep {
                MacProcessTerminator.enforce(policy: lastPolicy)
            }
            #endif
            return
        }

        activeModes = modes
        let policy = buildPolicy()
        lastPolicy = policy
        try store.save(policy)
        client?.update(policy: policy)

        #if os(macOS)
        if runTerminationSweep {
            MacProcessTerminator.enforce(policy: policy)
        }
        #endif
    }

    /// Pure decision: which application bundle ids should be blocked *right now*,
    /// and with what mode. Mirrors `PolicyEvaluator`'s shield logic but collects
    /// application targets across all groups (the kill sweep then acts on the
    /// running ones). Exposed for testing.
    static func blockedApplicationModes(
        groups: [BlockGroup],
        usage: UsageSnapshot,
        now: Date,
        calendar: Calendar = .current,
        mode: MacEnforcementMode
    ) -> [String: MacEnforcementMode] {
        var modes: [String: MacEnforcementMode] = [:]
        for group in groups where group.enabled {
            guard group.isActive(at: now, calendar: calendar) else { continue }
            if usage.snoozesByGroup[group.id]?.phase(at: now) == .active { continue }

            let shouldBlock: Bool
            switch group.mode {
            case .instant:
                shouldBlock = true
            case .afterMinutes, .timer:
                // Timed groups only block once the daily allowance is spent.
                let used = usage.usageByGroupSeconds[group.id] ?? 0
                let allowed = TimeInterval(max(0, group.allowedMinutes) * 60)
                shouldBlock = (allowed - used) <= 0
            }
            guard shouldBlock else { continue }

            for target in group.targets where target.kind == .application {
                guard !MacProcessTerminator.isBrowserBundleIdentifier(target.id) else { continue }
                modes[target.id] = mode
            }
        }
        return modes
    }

    public func currentPolicy() -> GuardPolicy {
        lastPolicy
    }

    /// Re-runs the kill/suspend sweep against the *current* policy without
    /// recompiling it (cheap — no inventory/code-signing scan). Used on a timer
    /// to catch blocked apps that were (re)launched, standing in for the
    /// Endpoint Security launch-prevention when that entitlement isn't present.
    @discardableResult
    public func sweep() -> [TerminationAction] {
        #if os(macOS)
        return MacProcessTerminator.enforce(policy: lastPolicy)
        #else
        return []
        #endif
    }

    public func currentBlockedBundleIdentifiers() -> Set<String> {
        Set(activeModes.keys)
    }

    private static func mode(from decision: PolicyDecision, default fallback: MacEnforcementMode) -> MacEnforcementMode {
        if let raw = decision.metadata[enforcementMetadataKey],
           let mode = MacEnforcementMode(rawValue: raw) {
            return mode
        }
        return fallback
    }

    private func buildPolicy() -> GuardPolicy {
        GuardPolicy(
            version: 1,
            generatedAt: Date(),
            targets: Self.buildTargets(from: activeModes),
            protectedBundleIdentifiers: protectedBundleIdentifiers
        )
    }

    /// Resolves each blocked bundle id into a richly-keyed `GuardTarget`
    /// (path + code-signing identity + helper-prefix) so it can't be dodged by
    /// renaming/moving the app. On non-macOS only the bundle id is used.
    static func buildTargets(from modes: [String: MacEnforcementMode]) -> [GuardTarget] {
        #if os(macOS)
        let inventory = MacApplicationInventory.installedApplications()
        let byBundleID = Dictionary(
            inventory.map { ($0.bundleIdentifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        #endif

        return modes
            .filter { !MacProcessTerminator.isBrowserBundleIdentifier($0.key) }
            .map { bundleID, mode in
            #if os(macOS)
            if let app = byBundleID[bundleID] {
                let signing = MacCodeSigning.info(forItemAt: app.path)
                return GuardTarget(
                    bundleIdentifier: bundleID,
                    bundleIdentifierPrefixes: ["\(bundleID)."],
                    teamIdentifier: signing?.teamIdentifier,
                    signingIdentifier: signing?.signingIdentifier,
                    executablePaths: app.path.isEmpty ? [] : [app.path],
                    enforcementMode: mode,
                    displayName: app.name
                )
            }
            #endif
            return GuardTarget(
                bundleIdentifier: bundleID,
                bundleIdentifierPrefixes: ["\(bundleID)."],
                enforcementMode: mode,
                displayName: bundleID
            )
            }
            .sorted { $0.bundleIdentifier < $1.bundleIdentifier }
    }
}
