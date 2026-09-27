import Foundation

/// One wording for the refusal codes every AI tool returns — Mac Vault's own
/// tools and the extension tools relayed to a browser use the same codes
/// (group-actions.js / group-scopes.js / the browser's worker).
public enum ToolRefusals {
    public static func explain(_ code: String) -> String {
        switch code {
        case "group-locked": return "the group is frozen (the editor refuses this too)."
        case "group-not-found": return "no group has that id."
        case "not-locked": return "the group is not frozen."
        case "not-stricter": return "while frozen the freeze can only be made stricter (a longer wait, or a PIN where there was none)."
        case "pin-already-set": return "the group already has a PIN."
        case "lock-changed": return "the freeze changed meanwhile; start again."
        case "snooze-disabled": return "the group doesn't allow snoozing."
        case "snooze-in-progress": return "a snooze (or its cooldown) is already running."
        case "no-snooze": return "no snooze is running."
        case "duplicate-name": return "another group already has that name (ignoring letter case)."
        case "unknown-group-type": return "unknown group type (site, custom, or a platform)."
        case "desktop-lines": return "the Apps lines are Mac Vault's (a browser controls only the browser); nothing was changed."
        case "browser-lines": return "websites and platforms are a browser's (Mac Vault controls only apps); nothing was changed."
        case "invalid-groupType": return "a group can't turn into a custom group or back; nothing was changed."
        case "rules-not-running": return "Mac Vault's rule engine isn't running."
        default: break
        }
        if code.hasPrefix("invalid-") { return "'\(code.dropFirst("invalid-".count))' has a value the editor refuses; nothing was changed." }
        let parts = code.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return code }
        switch parts[0] {
        case "pins-required": return "pass pins: one PIN for each of: \(parts[1])."
        case "pin-wait": return "wait \(parts[1]) s before the next PIN try (a wrong PIN was entered)."
        case "pin-wrong": return "wrong PIN; the next try waits \(parts[1]) s."
        case "wait-until": return "the freeze's wait holds until \(parts[1])."
        case "confirm-wait": return "confirm again in \(parts[1]) s (the editor's confirmation waits 5 s)."
        case "not-an-editor-setting": return "'\(parts[1])' is not one of the editor's settings (defaultSnoozeMinutes, quitRetryMinutes, quickAddEnabled, quickAddGroupId)."
        default: return code
        }
    }
}
