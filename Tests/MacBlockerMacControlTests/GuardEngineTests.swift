import XCTest
@testable import MacBlockerMacControl
@testable import MacBlockerCore

/// Exercises the enforcement engine's pure logic: target matching, guardrails,
/// the kill/suspend selection sweep, policy persistence, and decision→policy
/// compilation. (The Endpoint Security `AUTH_EXEC` deny and the actual killing
/// require the entitlement / live processes and are integration concerns.)
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
        XCTAssertFalse(policy.shouldDenyLaunch(bundleIdentifier: "com.apple.Safari"))
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

    // MARK: - preventsLaunch / runningAction layering

    func testEnforcementModeLayers() {
        XCTAssertTrue(MacEnforcementMode.forceTerminate.preventsLaunch)
        XCTAssertEqual(MacEnforcementMode.forceTerminate.runningAction, .forceKill)

        XCTAssertTrue(MacEnforcementMode.preventLaunch.preventsLaunch)
        XCTAssertEqual(MacEnforcementMode.preventLaunch.runningAction, .none)

        XCTAssertTrue(MacEnforcementMode.suspend.preventsLaunch)
        XCTAssertEqual(MacEnforcementMode.suspend.runningAction, .suspend)

        XCTAssertFalse(MacEnforcementMode.hideApplication.preventsLaunch)
        XCTAssertEqual(MacEnforcementMode.hideApplication.runningAction, .hide)

        XCTAssertFalse(MacEnforcementMode.shieldOnly.preventsLaunch)
        XCTAssertEqual(MacEnforcementMode.shieldOnly.runningAction, .none)
    }

    // MARK: - Termination sweep selection (pure)

    func testTerminatorPlanSelectsBlockedRunningProcesses() {
        let policy = GuardPolicy(targets: [
            GuardTarget(bundleIdentifier: "com.zoom.us", enforcementMode: .forceTerminate),
            GuardTarget(bundleIdentifier: "com.slack.app", enforcementMode: .suspend),
            GuardTarget(bundleIdentifier: "com.note.app", enforcementMode: .preventLaunch)
        ])
        let running = [
            RunningProcessSnapshot(processIdentifier: 100, bundleIdentifier: "com.zoom.us"),
            RunningProcessSnapshot(processIdentifier: 200, bundleIdentifier: "com.slack.app"),
            RunningProcessSnapshot(processIdentifier: 300, bundleIdentifier: "com.note.app"),
            RunningProcessSnapshot(processIdentifier: 400, bundleIdentifier: "com.apple.Finder"),
            RunningProcessSnapshot(processIdentifier: 500, bundleIdentifier: "com.other.app")
        ]

        let plan = MacProcessTerminator.plan(policy: policy, running: running)
        let byPID = Dictionary(uniqueKeysWithValues: plan.map { ($0.processIdentifier, $0.action) })

        XCTAssertEqual(byPID[100], .forceKill)
        XCTAssertEqual(byPID[200], .suspend)
        // preventLaunch has no running action → not in the sweep plan.
        XCTAssertNil(byPID[300])
        // Apple binary → guardrail.
        XCTAssertNil(byPID[400])
        // Not blocked.
        XCTAssertNil(byPID[500])
        XCTAssertEqual(plan.count, 2)
    }

    // MARK: - Policy store round-trip

    func testPolicyStoreRoundTrips() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("guard-\(UUID().uuidString)")
            .appendingPathComponent("policy.json")
        let store = GuardPolicyStore(url: tmp)
        defer { try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent()) }

        let policy = GuardPolicy(
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            targets: [
                GuardTarget(
                    bundleIdentifier: "com.example.App",
                    teamIdentifier: "ABCDE12345",
                    enforcementMode: .forceTerminate,
                    displayName: "Example"
                )
            ]
        )
        try store.save(policy)

        let loaded = try XCTUnwrap(store.load())
        XCTAssertEqual(loaded, policy)
    }

    // MARK: - Decision → policy compilation

    func testAdapterCompilesShieldDecisionsIntoPolicy() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("guard-\(UUID().uuidString)")
            .appendingPathComponent("policy.json")
        defer { try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent()) }

        let adapter = EndpointSecurityPolicyAdapter(
            store: GuardPolicyStore(url: tmp),
            client: nil,
            defaultMode: .forceTerminate,
            runTerminationSweep: false
        )

        try await adapter.apply([
            PolicyDecision(
                action: .shield,
                groupID: "g1",
                targetIDs: ["com.zoom.us", "com.slack.app"],
                reason: "blocked"
            )
        ])

        var blocked = await adapter.currentBlockedBundleIdentifiers()
        XCTAssertEqual(blocked, ["com.zoom.us", "com.slack.app"])

        let policy = await adapter.currentPolicy()
        XCTAssertTrue(policy.shouldDenyLaunch(bundleIdentifier: "com.zoom.us"))

        // Unshielding one removes it from the policy.
        try await adapter.apply([
            PolicyDecision(action: .unshield, groupID: "g1", targetIDs: ["com.zoom.us"])
        ])
        blocked = await adapter.currentBlockedBundleIdentifiers()
        XCTAssertEqual(blocked, ["com.slack.app"])
    }

    // MARK: - Mode / schedule / usage aware block selection

    private func appGroup(
        id: String,
        bundleID: String,
        mode: BlockingMode,
        allowedMinutes: Int = 30,
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
        let modes = EndpointSecurityPolicyAdapter.blockedApplicationModes(
            groups: [group], usage: UsageSnapshot(), now: Date(), mode: .forceTerminate
        )
        XCTAssertEqual(modes["com.hnc.Discord"], .forceTerminate)
    }

    func testTimerGroupDoesNotBlockBeforeLimit() {
        // The reported bug: a timer group must NOT insta-block.
        let group = appGroup(id: "g", bundleID: "com.hnc.Discord", mode: .timer, allowedMinutes: 30)
        let modes = EndpointSecurityPolicyAdapter.blockedApplicationModes(
            groups: [group], usage: UsageSnapshot(), now: Date(), mode: .forceTerminate
        )
        XCTAssertTrue(modes.isEmpty)
    }

    func testTimerGroupBlocksOnceLimitExhausted() {
        let group = appGroup(id: "g", bundleID: "com.hnc.Discord", mode: .timer, allowedMinutes: 30)
        let usage = UsageSnapshot(usageByGroupSeconds: ["g": TimeInterval(30 * 60)])
        let modes = EndpointSecurityPolicyAdapter.blockedApplicationModes(
            groups: [group], usage: usage, now: Date(), mode: .forceTerminate
        )
        XCTAssertEqual(modes["com.hnc.Discord"], .forceTerminate)
    }

    func testAfterMinutesGroupRespectsRemainingTime() {
        let group = appGroup(id: "g", bundleID: "com.app", mode: .afterMinutes, allowedMinutes: 60)
        let usage = UsageSnapshot(usageByGroupSeconds: ["g": TimeInterval(10 * 60)])
        let modes = EndpointSecurityPolicyAdapter.blockedApplicationModes(
            groups: [group], usage: usage, now: Date(), mode: .forceTerminate
        )
        XCTAssertTrue(modes.isEmpty)
    }

    func testDisabledGroupNeverBlocks() {
        let group = appGroup(id: "g", bundleID: "com.app", mode: .instant, enabled: false)
        let modes = EndpointSecurityPolicyAdapter.blockedApplicationModes(
            groups: [group], usage: UsageSnapshot(), now: Date(), mode: .forceTerminate
        )
        XCTAssertTrue(modes.isEmpty)
    }

    func testActiveSnoozeSuppressesBlocking() {
        let group = appGroup(id: "g", bundleID: "com.app", mode: .instant)
        let now = Date()
        let usage = UsageSnapshot(
            snoozesByGroup: ["g": SnoozeState(startsAt: now.addingTimeInterval(-60), until: now.addingTimeInterval(600))]
        )
        let modes = EndpointSecurityPolicyAdapter.blockedApplicationModes(
            groups: [group], usage: usage, now: now, mode: .forceTerminate
        )
        XCTAssertTrue(modes.isEmpty)
    }

    func testAdapterRespectsPerDecisionModeOverride() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("guard-\(UUID().uuidString)")
            .appendingPathComponent("policy.json")
        defer { try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent()) }

        let adapter = EndpointSecurityPolicyAdapter(
            store: GuardPolicyStore(url: tmp),
            client: nil,
            defaultMode: .forceTerminate,
            runTerminationSweep: false
        )

        try await adapter.apply([
            PolicyDecision(
                action: .shield,
                groupID: "g1",
                targetIDs: ["com.example.App"],
                metadata: [EndpointSecurityPolicyAdapter.enforcementMetadataKey: MacEnforcementMode.suspend.rawValue]
            )
        ])

        let policy = await adapter.currentPolicy()
        let target = try XCTUnwrap(policy.targets.first { $0.bundleIdentifier == "com.example.App" })
        XCTAssertEqual(target.enforcementMode, .suspend)
    }
}
