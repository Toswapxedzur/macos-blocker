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
