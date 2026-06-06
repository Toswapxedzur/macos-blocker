import Foundation
import MacBlockerCore

#if os(macOS)
import AppKit
import Darwin
#endif

/// How a blocked macOS application should be enforced. Modes are layered: each
/// implies whether the app should be *prevented from launching* (Endpoint
/// Security `AUTH_EXEC` deny) and/or how an already-running instance should be
/// dealt with (the kill/suspend sweep). "Maximum security" = `.forceTerminate`,
/// which both denies launch and SIGKILLs anything already running.
public enum MacEnforcementMode: String, Codable, Sendable, CaseIterable {
    /// Status only — never prevents launch, never kills. Used for showStatus.
    case shieldOnly
    /// Endpoint Security denies `exec`; running instances are left alone (they
    /// will be caught on next launch). The lightest *hard* block.
    case preventLaunch
    /// Soft: hide the running app (it keeps running). No launch prevention.
    case hideApplication
    /// Soft: hide the running app and the frontmost app (switch away). No launch
    /// prevention.
    case switchAway
    /// Ask the app to quit (graceful `terminate()` / SIGTERM) and deny relaunch.
    case terminateApplication
    /// Maximum security: deny relaunch (ESF) and SIGKILL every running instance
    /// immediately. Unsaved work is lost.
    case forceTerminate
    /// Deny relaunch and freeze running instances with SIGSTOP (resumable with
    /// SIGCONT). Useful for "time's up" without destroying state.
    case suspend

    /// Whether Endpoint Security should deny `exec` for targets in this mode.
    public var preventsLaunch: Bool {
        switch self {
        case .preventLaunch, .terminateApplication, .forceTerminate, .suspend:
            return true
        case .shieldOnly, .hideApplication, .switchAway:
            return false
        }
    }

    /// What to do with an already-running instance during the kill/suspend sweep.
    public enum RunningAction: Sendable {
        case none
        case hide
        case switchAway
        case gracefulTerminate
        case forceKill
        case suspend
    }

    public var runningAction: RunningAction {
        switch self {
        case .shieldOnly, .preventLaunch:
            return .none
        case .hideApplication:
            return .hide
        case .switchAway:
            return .switchAway
        case .terminateApplication:
            return .gracefulTerminate
        case .forceTerminate:
            return .forceKill
        case .suspend:
            return .suspend
        }
    }
}

public struct MacControlledTarget: Codable, Equatable, Sendable {
    public var targetID: String
    public var bundleIdentifier: String
    public var enforcementMode: MacEnforcementMode

    public init(
        targetID: String,
        bundleIdentifier: String,
        enforcementMode: MacEnforcementMode = .hideApplication
    ) {
        self.targetID = targetID
        self.bundleIdentifier = bundleIdentifier
        self.enforcementMode = enforcementMode
    }
}

public protocol MacControlledTargetProviding: Sendable {
    func controlledTargets() async throws -> [MacControlledTarget]
}

public actor MacControlPolicyAdapter: PolicyApplying {
    public let capabilities: PlatformCapabilities = .macOS
    private let targetProvider: MacControlledTargetProviding
    private var activeBlockedTargetIDs: Set<String> = []
    private var latestStatus: OverlayStatus?

    public init(targetProvider: MacControlledTargetProviding) {
        self.targetProvider = targetProvider
    }

    public func apply(_ decisions: [PolicyDecision]) async throws {
        let targets = try await targetProvider.controlledTargets()
        let byID = Dictionary(uniqueKeysWithValues: targets.map { ($0.targetID, $0) })

        for decision in decisions {
            switch decision.action {
            case .shield:
                try await enforceShieldDecision(decision, controlledTargets: byID)
                latestStatus = decision.overlayStatus
            case .allow, .unshield:
                activeBlockedTargetIDs.subtract(decision.targetIDs)
            case .showStatus:
                latestStatus = decision.overlayStatus
            case .requestSnooze, .log, .quarantine:
                continue
            }
        }
    }

    public func currentBlockedTargetIDs() -> Set<String> {
        activeBlockedTargetIDs
    }

    public func currentStatus() -> OverlayStatus? {
        latestStatus
    }

    private func enforceShieldDecision(
        _ decision: PolicyDecision,
        controlledTargets: [String: MacControlledTarget]
    ) async throws {
        let permissions = MacPermissionState.current(promptForAccessibility: false)
        guard permissions.accessibilityTrusted else {
            throw PolicyApplicationError.missingPermission("Accessibility")
        }

        for targetID in decision.targetIDs {
            guard let target = controlledTargets[targetID] else {
                throw PolicyApplicationError.unauthorizedTarget(targetID)
            }
            activeBlockedTargetIDs.insert(targetID)
            enforce(target)
        }
    }

    private func enforce(_ target: MacControlledTarget) {
        #if os(macOS)
        let apps = NSRunningApplication.runningApplications(
            withBundleIdentifier: target.bundleIdentifier
        )
        for app in apps {
            switch target.enforcementMode.runningAction {
            case .none:
                continue
            case .hide:
                app.hide()
            case .switchAway:
                app.hide()
                NSWorkspace.shared.frontmostApplication?.hide()
            case .gracefulTerminate:
                app.terminate()
            case .forceKill:
                app.forceTerminate()
            case .suspend:
                kill(app.processIdentifier, SIGSTOP)
            }
        }
        #endif
    }
}
