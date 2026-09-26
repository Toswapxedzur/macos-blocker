import Foundation
import MacBlockerCore

/// The macOS app-blocking policy applier: compiles the user's groups into a
/// `GuardPolicy` and asks every running app it blocks to quit — normally,
/// never by force (`QuitRequests`): once per launch, again after the retry
/// interval if it stays open (the engine repeats the sweep each second).
///
public actor AppBlockPolicy {

    private let runTerminationSweep: Bool

    /// The bundle ids blocked right now.
    private var activeBlocked: Set<String> = []
    private var activeAllowlists: [GuardAllowlist] = []
    private var lastPolicy = GuardPolicy()
    #if os(macOS)
    private let quits = QuitRequests()
    #endif

    public init(runTerminationSweep: Bool = true) {
        self.runTerminationSweep = runTerminationSweep
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
        customBlockedBundleIDs: Set<String> = [],
        quitRetry: TimeInterval = 0
    ) async throws {
        // Plus the bundle ids custom-rule decisions block.
        let blocked = Self.blockedApplications(groups: groups, usage: usage, now: now, calendar: calendar)
            .union(customBlockedBundleIDs.filter(GuardPolicy.canBlock))
        let allowlists = Self.applicationAllowlists(groups: groups, usage: usage, now: now, calendar: calendar)

        // A changed set rebuilds the policy (the inventory/signing scan);
        // otherwise the last one keeps being enforced.
        if blocked != activeBlocked || allowlists != activeAllowlists {
            activeBlocked = blocked
            activeAllowlists = allowlists
            lastPolicy = buildPolicy()
        }
        #if os(macOS)
        if runTerminationSweep {
            quits.sweep(blocked: MacProcessTerminator.blockedProcesses(policy: lastPolicy), retry: quitRetry, now: now)
        }
        #endif
    }

    #if os(macOS)
    /// A custom rule's close: the app is asked to quit, like a block.
    public func close(bundleIdentifier: String, now: Date = Date()) {
        quits.close(bundleIdentifier: bundleIdentifier, now: now)
    }
    #endif

    /// Whether `bundleID` is blocked right now by these groups: the same
    /// decision the guard policy is built from. The bridge uses it to stop
    /// counting time in an app that is blocked yet still in front, as a
    /// covered browser page counts no time.
    public static func blocksApplication(
        _ bundleID: String,
        groups: [BlockGroup],
        usage: UsageSnapshot,
        now: Date,
        calendar: Calendar = .current
    ) -> Bool {
        let blocked = blockedApplications(groups: groups, usage: usage, now: now, calendar: calendar)
        let lists = applicationAllowlists(groups: groups, usage: usage, now: now, calendar: calendar)
        // Runs every second: a bundle-id match needs no installed-app scan or
        // code-signing read (those only harden the kill sweep's policy).
        let targets = blocked.map { GuardTarget(bundleIdentifier: $0, bundleIdentifierPrefixes: ["\($0)."]) }
        let policy = GuardPolicy(targets: targets, allowOnly: lists)
        return policy.match(bundleIdentifier: bundleID) != nil
    }

    /// Pure decision: the "block every application except these" groups that
    /// block right now, each with its allowed set. Same activity rules as
    /// `blockedApplications`. Exposed for testing.
    static func applicationAllowlists(
        groups: [BlockGroup],
        usage: UsageSnapshot,
        now: Date,
        calendar: Calendar = .current
    ) -> [GuardAllowlist] {
        var lists: [GuardAllowlist] = []
        for group in groups where group.applicationAllowlist && group.blocksNow(usage: usage, at: now, calendar: calendar) {
            let allowed = Set(group.targets.filter { $0.kind == .application }.map(\.id))
            lists.append(GuardAllowlist(allowedBundleIdentifiers: allowed, displayName: group.name))
        }
        return lists.sorted { $0.displayName < $1.displayName }
    }

    /// Pure decision: which application bundle ids are blocked *right now*.
    /// Collects the application targets of every group that blocks now (the
    /// quit sweep then acts on the running ones). Exposed for testing.
    static func blockedApplications(
        groups: [BlockGroup],
        usage: UsageSnapshot,
        now: Date,
        calendar: Calendar = .current
    ) -> Set<String> {
        var blocked: Set<String> = []
        // An "everything except" group's apps are the ALLOWED ones; that group
        // blocks through `applicationAllowlists`, never through its list.
        for group in groups where !group.applicationAllowlist && group.blocksNow(usage: usage, at: now, calendar: calendar) {
            for target in group.targets where target.kind == .application && GuardPolicy.canBlock(target.id) {
                blocked.insert(target.id)
            }
        }
        return blocked
    }

    public func currentPolicy() -> GuardPolicy {
        lastPolicy
    }

    public func currentBlockedBundleIdentifiers() -> Set<String> {
        activeBlocked
    }

    private func buildPolicy() -> GuardPolicy {
        GuardPolicy(targets: Self.buildTargets(from: activeBlocked), allowOnly: activeAllowlists)
    }

    /// Resolves each blocked bundle id into a richly-keyed `GuardTarget`
    /// (path + code-signing identity + helper-prefix) so it can't be dodged by
    /// renaming/moving the app. On non-macOS only the bundle id is used.
    static func buildTargets(from blocked: Set<String>) -> [GuardTarget] {
        #if os(macOS)
        let inventory = MacApplicationInventory.installedApplications()
        let byBundleID = Dictionary(
            inventory.map { ($0.bundleIdentifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        #endif

        return blocked
            .filter(GuardPolicy.canBlock)
            .map { bundleID in
            #if os(macOS)
            if let app = byBundleID[bundleID] {
                let signing = MacCodeSigning.info(forItemAt: app.path)
                return GuardTarget(
                    bundleIdentifier: bundleID,
                    bundleIdentifierPrefixes: ["\(bundleID)."],
                    teamIdentifier: signing?.teamIdentifier,
                    signingIdentifier: signing?.signingIdentifier,
                    executablePaths: app.path.isEmpty ? [] : [app.path],
                    displayName: app.name
                )
            }
            #endif
            return GuardTarget(
                bundleIdentifier: bundleID,
                bundleIdentifierPrefixes: ["\(bundleID)."],
                displayName: bundleID
            )
            }
            .sorted { $0.bundleIdentifier < $1.bundleIdentifier }
    }
}
