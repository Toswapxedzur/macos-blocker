import XCTest
@testable import MacBlockerMacControl
@testable import MacBlockerCore

/// Exercises the enforcement engine's pure logic: target matching, guardrails,
/// the kill selection sweep and decision→policy compilation. (The actual
/// killing needs live processes and is an integration concern.)
final class GuardEngineTests: XCTestCase {

    // MARK: - Matching

    func testMatchesBundleIdentifierCaseInsensitively() {
        let target = GuardTarget(bundleIdentifier: "com.google.Chrome")
        XCTAssertTrue(target.matches(bundleIdentifier: "com.google.chrome"))
        XCTAssertFalse(target.matches(bundleIdentifier: "com.apple.Safari"))
    }

    func testMatchesHelperViaPrefix() {
        let target = GuardTarget(
            bundleIdentifier: "com.google.Chrome",
            bundleIdentifierPrefixes: ["com.google.Chrome."]
        )
        XCTAssertTrue(target.matches(bundleIdentifier: "com.google.Chrome.helper"))
        XCTAssertTrue(target.matches(bundleIdentifier: "com.google.Chrome.helper.Renderer"))
        XCTAssertFalse(target.matches(bundleIdentifier: "com.google.Keystone"))
    }

    func testMatchesByTeamAndSigningAndPath() {
        let target = GuardTarget(
            bundleIdentifier: "com.example.App",
            teamIdentifier: "ABCDE12345",
            signingIdentifier: "com.example.App",
            executablePaths: ["/Applications/Example.app"]
        )
        XCTAssertTrue(target.matches(bundleIdentifier: nil, teamIdentifier: "ABCDE12345"))
        XCTAssertTrue(target.matches(bundleIdentifier: nil, signingIdentifier: "com.example.App"))
        XCTAssertTrue(target.matches(bundleIdentifier: nil, executablePath: "/Applications/Example.app"))
        XCTAssertFalse(target.matches(bundleIdentifier: nil, teamIdentifier: "ZZZZZ99999"))
    }

    // MARK: - Guardrails

    func testApplePlatformBinariesAreNeverMatched() {
        let policy = GuardPolicy(targets: [GuardTarget(bundleIdentifier: "com.apple.Safari")])
        // Even though a (misconfigured) target names an Apple bundle, the
        // guardrail refuses to match it.
        XCTAssertNil(policy.match(bundleIdentifier: "com.apple.Safari"))
        XCTAssertFalse(policy.match(bundleIdentifier: "com.apple.Safari") != nil)
    }

    func testUnidentifiedProcessIsTreatedAsProtected() {
        let policy = GuardPolicy(targets: [GuardTarget(bundleIdentifier: "com.example.App")])
        XCTAssertNil(policy.match(bundleIdentifier: nil))
    }

    func testExplicitlyProtectedBundleIsNeverMatched() {
        let policy = GuardPolicy(
            targets: [GuardTarget(bundleIdentifier: "com.example.App")],
            protectedBundleIdentifiers: ["com.example.App"]
        )
        XCTAssertNil(policy.match(bundleIdentifier: "com.example.App"))
    }

    func testNativeTerminatorNeverSelectsBrowserProcesses() {
        XCTAssertTrue(MacProcessTerminator.isBrowserBundleIdentifier("com.google.Chrome"))
        XCTAssertTrue(MacProcessTerminator.isBrowserBundleIdentifier("com.google.Chrome.helper"))
        XCTAssertTrue(MacProcessTerminator.isBrowserBundleIdentifier("org.mozilla.firefox"))
        XCTAssertFalse(MacProcessTerminator.isBrowserBundleIdentifier("com.example.FocusApp"))

        let policy = GuardPolicy(targets: [
            GuardTarget(bundleIdentifier: "com.google.Chrome"),
            GuardTarget(bundleIdentifier: "com.example.FocusApp")
        ])
        let plan = MacProcessTerminator.plan(policy: policy, running: [
            RunningProcessSnapshot(processIdentifier: 100, bundleIdentifier: "com.google.Chrome"),
            RunningProcessSnapshot(processIdentifier: 200, bundleIdentifier: "com.example.FocusApp")
        ])

        XCTAssertEqual(plan.map(\.bundleIdentifier), ["com.example.FocusApp"])
    }

    // MARK: - "Block every application except these"

    func testAllowlistBlocksEverythingItDoesNotName() {
        let policy = GuardPolicy(
            protectedBundleIdentifiers: ["com.adamancia.vault"],
            allowOnly: [GuardAllowlist(
                allowedBundleIdentifiers: ["com.example.Editor"],
                displayName: "Deep work"
            )]
        )
        XCTAssertNil(policy.match(bundleIdentifier: "com.example.editor"), "listed apps pass, case-insensitively")
        XCTAssertNil(policy.match(bundleIdentifier: "com.example.Editor.Helper"), "an allowed app's helpers pass with it")
        XCTAssertNotNil(policy.match(bundleIdentifier: "com.hnc.Discord"))
        XCTAssertEqual(policy.match(bundleIdentifier: "com.hnc.Discord")?.displayName, "Deep work")
        XCTAssertTrue(policy.match(bundleIdentifier: "com.hnc.Discord") != nil)
        // Guardrails still win: Apple, Vault itself, browsers and unidentified processes.
        XCTAssertNil(policy.match(bundleIdentifier: "com.apple.Finder"))
        XCTAssertNil(policy.match(bundleIdentifier: "com.adamancia.vault"))
        XCTAssertNil(policy.match(bundleIdentifier: "com.adamancia.vault.Helper"), "a protected app's helpers are protected with it")
        XCTAssertNil(policy.match(bundleIdentifier: "com.google.Chrome"))
        XCTAssertNil(policy.match(bundleIdentifier: nil))
    }

    func testAllowlistDecisionFollowsGroupActivity() {
        var group = appGroup(id: "g", bundleID: "com.example.Editor", mode: .afterMinutes, allowedMinutes: 30)
        group.applicationAllowlist = true
        let fresh = AppBlockPolicy.applicationAllowlists(
            groups: [group], usage: UsageSnapshot(), now: Date()
        )
        XCTAssertTrue(fresh.isEmpty, "a timed allowlist group blocks nothing before its allowance is spent")

        let spent = AppBlockPolicy.applicationAllowlists(
            groups: [group], usage: UsageSnapshot(usageByGroupSeconds: ["g": TimeInterval(30 * 60)]), now: Date()
        )
        XCTAssertEqual(spent, [GuardAllowlist(allowedBundleIdentifiers: ["com.example.editor"], displayName: "g")])

        group.applicationAllowlist = false
        let plain = AppBlockPolicy.applicationAllowlists(
            groups: [group], usage: UsageSnapshot(usageByGroupSeconds: ["g": TimeInterval(30 * 60)]), now: Date()
        )
        XCTAssertTrue(plain.isEmpty, "a plain blocklist group contributes no allowlist")
    }

    func testAllowlistGroupNeverBlocksItsOwnListedApps() {
        var group = appGroup(id: "g", bundleID: "com.example.Editor", mode: .instant)
        group.applicationAllowlist = true
        let modes = AppBlockPolicy.blockedApplications(
            groups: [group], usage: UsageSnapshot(), now: Date()
        )
        XCTAssertTrue(modes.isEmpty, "the listed apps are the ALLOWED ones")
        let lists = AppBlockPolicy.applicationAllowlists(
            groups: [group], usage: UsageSnapshot(), now: Date()
        )
        let policy = GuardPolicy(targets: AppBlockPolicy.buildTargets(from: modes), allowOnly: lists)
        XCTAssertNil(policy.match(bundleIdentifier: "com.example.Editor"))
        XCTAssertNotNil(policy.match(bundleIdentifier: "com.hnc.Discord"))
    }

    func testAllowlistBudgetCountsTheAppsItWouldBlock() {
        var group = appGroup(id: "g", bundleID: "com.example.Editor", mode: .afterMinutes)
        XCTAssertTrue(group.countsApplication("com.example.Editor", exempt: false), "a blocklist counts its listed app")
        XCTAssertFalse(group.countsApplication("com.hnc.Discord", exempt: false))
        group.applicationAllowlist = true
        XCTAssertFalse(group.countsApplication("com.example.Editor", exempt: false), "an allowed app spends nothing")
        XCTAssertFalse(group.countsApplication("com.example.editor.Helper", exempt: false))
        XCTAssertTrue(group.countsApplication("com.hnc.Discord", exempt: false), "a blocked app spends the budget")
        XCTAssertFalse(group.countsApplication("com.google.Chrome", exempt: true), "exempt apps (browsers, Apple, Vault) never count")
    }

    func testOneEnforcingTestForRulesTimeAndBlocking() {
        let now = Date()
        let timed = appGroup(id: "t", bundleID: "com.hnc.Discord", mode: .afterMinutes, allowedMinutes: 30)
        XCTAssertEqual(timed.remainingSeconds(usedSeconds: 600), 1_200)
        XCTAssertFalse(timed.blocksNow(usage: UsageSnapshot(usageByGroupSeconds: ["t": 600]), at: now))
        XCTAssertTrue(timed.blocksNow(usage: UsageSnapshot(usageByGroupSeconds: ["t": 1_800]), at: now), "allowance spent")
        let snoozed = UsageSnapshot(usageByGroupSeconds: ["t": 1_800], snoozesByGroup: ["t": SnoozeState(
            startsAt: now.addingTimeInterval(-60), until: now.addingTimeInterval(60))])
        XCTAssertFalse(timed.isEnforcing(snoozes: snoozed.snoozesByGroup, at: now))
        XCTAssertFalse(timed.blocksNow(usage: snoozed, at: now), "a snoozed group blocks nothing")
        var off = appGroup(id: "i", bundleID: "com.hnc.Discord", mode: .instant)
        XCTAssertNil(off.remainingSeconds(usedSeconds: 0))
        XCTAssertTrue(off.blocksNow(usage: UsageSnapshot(), at: now))
        off.enabled = false
        XCTAssertFalse(off.blocksNow(usage: UsageSnapshot(), at: now))
    }

    func testBlocksApplicationMatchesTheGuardDecision() {
        let instant = appGroup(id: "i", bundleID: "com.hnc.Discord", mode: .instant)
        XCTAssertTrue(AppBlockPolicy.blocksApplication("com.hnc.Discord", groups: [instant], usage: UsageSnapshot(), now: Date()))
        XCTAssertFalse(AppBlockPolicy.blocksApplication("com.example.Other", groups: [instant], usage: UsageSnapshot(), now: Date()))
        let timed = appGroup(id: "t", bundleID: "com.hnc.Discord", mode: .afterMinutes, allowedMinutes: 30)
        XCTAssertFalse(AppBlockPolicy.blocksApplication("com.hnc.Discord", groups: [timed], usage: UsageSnapshot(), now: Date()),
                       "an unspent budget blocks nothing, so its time still counts")
        var allow = appGroup(id: "a", bundleID: "com.example.Editor", mode: .instant)
        allow.applicationAllowlist = true
        XCTAssertTrue(AppBlockPolicy.blocksApplication("com.hnc.Discord", groups: [allow], usage: UsageSnapshot(), now: Date()))
        XCTAssertFalse(AppBlockPolicy.blocksApplication("com.example.Editor", groups: [allow], usage: UsageSnapshot(), now: Date()))
        XCTAssertFalse(AppBlockPolicy.blocksApplication("com.google.Chrome", groups: [allow], usage: UsageSnapshot(), now: Date()))
    }

    func testPolicyWithoutAllowlistsStillDecodes() throws {
        let json = """
        {"version":1,"generatedAt":0,"targets":[],"protectedBundleIdentifiers":[]}
        """.data(using: .utf8)!
        let policy = try JSONDecoder().decode(GuardPolicy.self, from: json)
        XCTAssertTrue(policy.allowOnly.isEmpty)
    }

    // MARK: - Termination sweep selection (pure)

    func testTerminatorPlanSelectsBlockedRunningProcesses() {
        let policy = GuardPolicy(targets: [
            GuardTarget(bundleIdentifier: "com.zoom.us"),
            GuardTarget(bundleIdentifier: "com.slack.app")
        ])
        let running = [
            RunningProcessSnapshot(processIdentifier: 100, bundleIdentifier: "com.zoom.us"),
            RunningProcessSnapshot(processIdentifier: 200, bundleIdentifier: "com.slack.app"),
            RunningProcessSnapshot(processIdentifier: 300, bundleIdentifier: "com.note.app"),
            RunningProcessSnapshot(processIdentifier: 400, bundleIdentifier: "com.apple.Finder"),
            RunningProcessSnapshot(processIdentifier: 500, bundleIdentifier: "com.other.app")
        ]

        let plan = MacProcessTerminator.plan(policy: policy, running: running)
        // Blocked apps are killed; Apple binaries (guardrail) and unblocked
        // apps are left alone.
        XCTAssertEqual(plan.map(\.processIdentifier), [100, 200])
    }

    // MARK: - Mode / schedule / usage aware block selection

    private func appGroup(
        id: String,
        bundleID: String,
        mode: BlockingMode,
        allowedMinutes: Double = 30,
        enabled: Bool = true
    ) -> BlockGroup {
        BlockGroup(
            id: id,
            groupType: .app,
            name: id,
            enabled: enabled,
            mode: mode,
            allowedMinutes: allowedMinutes,
            targets: [
                BlockTarget(id: bundleID, kind: .application, displayName: bundleID, normalizedValue: bundleID)
            ]
        )
    }

    func testInstantGroupBlocksImmediately() {
        let group = appGroup(id: "g", bundleID: "com.hnc.Discord", mode: .instant)
        let modes = AppBlockPolicy.blockedApplications(
            groups: [group], usage: UsageSnapshot(), now: Date()
        )
        XCTAssertEqual(modes, ["com.hnc.Discord"])
    }

    func testBrowserGroupsAreExcludedFromNativePolicy() {
        let group = appGroup(id: "g", bundleID: "com.google.Chrome", mode: .instant)
        let modes = AppBlockPolicy.blockedApplications(
            groups: [group], usage: UsageSnapshot(), now: Date()
        )
        XCTAssertTrue(modes.isEmpty)
    }

    func testTimedGroupDoesNotBlockBeforeLimit() {
        // The reported bug: a timer group must NOT insta-block.
        let group = appGroup(id: "g", bundleID: "com.hnc.Discord", mode: .afterMinutes, allowedMinutes: 30)
        let modes = AppBlockPolicy.blockedApplications(
            groups: [group], usage: UsageSnapshot(), now: Date()
        )
        XCTAssertTrue(modes.isEmpty)
    }

    func testTimedGroupBlocksOnceLimitExhausted() {
        let group = appGroup(id: "g", bundleID: "com.hnc.Discord", mode: .afterMinutes, allowedMinutes: 30)
        let usage = UsageSnapshot(usageByGroupSeconds: ["g": TimeInterval(30 * 60)])
        let modes = AppBlockPolicy.blockedApplications(
            groups: [group], usage: usage, now: Date()
        )
        XCTAssertEqual(modes, ["com.hnc.Discord"])
    }

    func testAfterMinutesGroupRespectsRemainingTime() {
        let group = appGroup(id: "g", bundleID: "com.app", mode: .afterMinutes, allowedMinutes: 60)
        let usage = UsageSnapshot(usageByGroupSeconds: ["g": TimeInterval(10 * 60)])
        let modes = AppBlockPolicy.blockedApplications(
            groups: [group], usage: usage, now: Date()
        )
        XCTAssertTrue(modes.isEmpty)
    }

    func testDisabledGroupNeverBlocks() {
        let group = appGroup(id: "g", bundleID: "com.app", mode: .instant, enabled: false)
        let modes = AppBlockPolicy.blockedApplications(
            groups: [group], usage: UsageSnapshot(), now: Date()
        )
        XCTAssertTrue(modes.isEmpty)
    }

    func testActiveSnoozeSuppressesBlocking() {
        let group = appGroup(id: "g", bundleID: "com.app", mode: .instant)
        let now = Date()
        let usage = UsageSnapshot(
            snoozesByGroup: ["g": SnoozeState(startsAt: now.addingTimeInterval(-60), until: now.addingTimeInterval(600))]
        )
        let modes = AppBlockPolicy.blockedApplications(
            groups: [group], usage: usage, now: now
        )
        XCTAssertTrue(modes.isEmpty)
    }

    // Owner 2026-09-26: the picker and the "+" offer only apps a block can act on.
    func testOnlyBlockableAppsAreOffered() {
        XCTAssertTrue(AppBlockPolicy.canBlock("com.hnc.Discord"))
        XCTAssertFalse(AppBlockPolicy.canBlock("com.apple.Music"), "Apple's apps are never blocked")
        XCTAssertFalse(AppBlockPolicy.canBlock("com.google.Chrome"), "browsers block inside themselves")
        XCTAssertFalse(AppBlockPolicy.canBlock("com.google.Chrome.helper"))
    }
}
