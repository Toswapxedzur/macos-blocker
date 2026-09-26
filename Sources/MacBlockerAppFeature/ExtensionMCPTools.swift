#if os(macOS)
import Foundation
import MacBlockerCore

/// MCP tools over the browser extension's own settings (owner 2026-09-23: 1:1
/// parity — what the popup can do, a process can do). Each tool relays one
/// `browser-request` through the hub to the connected browser's service
/// worker, which answers with the extension's own sanitizers applied. The
/// relay is injectable so the tools are testable without a browser.
public enum ExtensionMCPTools {
    public enum RelayOutcome {
        case success([String: Any])
        case failure(String)
    }

    public struct Bridge {
        /// (operation, body, targetProgram) → outcome. Must call back exactly once.
        public var request: (_ operation: String, _ body: [String: Any], _ targetProgram: String?, _ completion: @escaping (RelayOutcome) -> Void) -> Void

        public init(request: @escaping (String, [String: Any], String?, @escaping (RelayOutcome) -> Void) -> Void) {
            self.request = request
        }

        public static let liveHub = Bridge { operation, body, targetProgram, completion in
            ConnectionHub.shared.sendBrowserRequest(operation: operation, body: body, targetProgram: targetProgram) { result in
                switch result {
                case .success(let body): completion(.success(body))
                case .failure(let reason): completion(.failure(reason))
                }
            }
        }
    }

    /// Longer than the hub's own relay timeout, so the hub's verdict wins.
    static let waitSeconds = 35.0

    public static func tools(bridge: Bridge = .liveHub) -> [MCPTool] {
        let browserProperty: [String: Any] = ["type": "string", "description": "Which connected browser: a program name (chrome, edge, brave, …) or a peer id from vault_status when two instances of one program are connected; required only when more than one browser is connected."]
        return [
            MCPTool(
                name: "extension_state",
                description: "The Vault browser extension's settings as JSON: every block group (platform rules with author / subreddit / tag filters, cover-until-tagged, page blocking, schedules, snooze rules, freeze (wait + PIN); site and custom groups), usage timers, active snoozes, the classifier settings (collection on/off, tagging mode) and global settings. Read live from the connected browser.",
                inputSchema: ["type": "object", "properties": ["browser": browserProperty]]
            ) { args in
                relay(bridge, "settings-get", [:], args)
            },
            MCPTool(
                name: "extension_create_group",
                description: "Create an extension block group of a type (youtube, tiktok, facebook, instagram, twitch, reddit, discord, twitter, bilibili, …, site, custom) with the popup's defaults, then apply an optional patch of group fields (e.g. name, platformTagMode 'include'|'exclude', platformTags [{name, confidence?, also?, except?}], platformTagBlockPage, platformTagCoverUntilTagged, platformTagEffect 'dim'|'block', sourceMode 'all'|'include'|'exclude'|'nobody' with sources [creators, accounts or subreddits], discordMode with discordTargets, surfaceHides, blockHomePage, sites/allowlist — or, instead of those flat fields, scopes: [{surface 'site'|'apps'|'items'|'pages'|'home'|'shelf', platform, sites/sitesExcept, apps/appsExcept ('block every application except these', desktop-enforced), form, sourceMode/sources, tagFilter, shelf, action 'block'|'pause'|'hide'|'dim' — 'pause' (site and untagged pages lines) covers the page with a countdown before letting it through; pauseSeconds is a group field}]; stored groups are returned as policy fields + scopes; mode, allowedMinutes, activeDays, timeWindowsText, sites, blockingRulesText). A group may carry lines for several platforms and a site list at once (it applies to their union, one policy): flat fields describe ONE platform — the group's groupType — and replace only that platform's lines, so patching groupType plus flat fields adds or edits that platform; a scopes patch replaces every line. Fields pass the extension's own sanitizer.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "groupType": ["type": "string", "description": "The group type."],
                        "patch": ["type": "object", "description": "Group fields to set on the new group."],
                        "browser": browserProperty,
                    ],
                    "required": ["groupType"],
                ]
            ) { args in
                guard let groupType = args["groupType"] as? String, !groupType.isEmpty else { return .failure("Missing 'groupType'.") }
                var body: [String: Any] = ["groupType": groupType]
                if let patch = args["patch"] as? [String: Any] { body["patch"] = patch }
                return relay(bridge, "settings-create-group", body, args)
            },
            MCPTool(
                name: "extension_set_group",
                description: "Patch fields of an existing extension block group by id (see extension_create_group for the fields). The id and the freeze (its wait and PIN) are never patchable; a frozen group is refused, exactly as in the popup.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "id": ["type": "string", "description": "The group id (from extension_state)."],
                        "patch": ["type": "object", "description": "Group fields to change."],
                        "browser": browserProperty,
                    ],
                    "required": ["id", "patch"],
                ]
            ) { args in
                guard let id = args["id"] as? String, !id.isEmpty else { return .failure("Missing 'id'.") }
                guard let patch = args["patch"] as? [String: Any] else { return .failure("Missing 'patch' object.") }
                return relay(bridge, "settings-set-group", ["id": id, "patch": patch], args)
            },
            MCPTool(
                name: "extension_delete_group",
                description: "Delete an extension block group by id. A frozen group is refused, exactly as in the popup.",
                inputSchema: [
                    "type": "object",
                    "properties": ["id": ["type": "string", "description": "The group id."], "browser": browserProperty],
                    "required": ["id"],
                ]
            ) { args in
                guard let id = args["id"] as? String, !id.isEmpty else { return .failure("Missing 'id'.") }
                return relay(bridge, "settings-delete-group", ["id": id], args)
            },
            MCPTool(
                name: "extension_lock_group",
                description: "Freeze an extension group, as the popup's Freeze does, with optional gates that combine: waitHours (it cannot be unfrozen for that long, 0 < hours ≤ 72) and pin (6 digits: unfreezing then needs this PIN). On a frozen group the same call can only make the freeze stricter: a longer wait, or a PIN where there was none. Every unfreeze also ends with the confirmation (10 steps, 5 s apart).",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "id": ["type": "string", "description": "The group id."],
                        "waitHours": ["type": "number"],
                        "pin": ["type": "string"],
                        "browser": browserProperty,
                    ],
                    "required": ["id"],
                ]
            ) { args in
                guard let id = args["id"] as? String, !id.isEmpty else { return .failure("Missing 'id'.") }
                var body: [String: Any] = ["id": id]
                if let hours = args["waitHours"] { body["waitHours"] = hours }
                if let pin = args["pin"] as? String { body["pin"] = pin }
                return relay(bridge, "settings-lock-group", body, args)
            },
            MCPTool(
                name: "extension_unlock_group",
                description: "Unfreeze an extension group through the popup's gates: the wait gate must be over; a set PIN must be passed (pin; a wrong PIN makes the next try wait 1 s … 64 s, shared with the popup); then the confirmation: call again with confirm: true every 5 seconds until confirmationsLeft is 0 (10 in all, within 5 minutes).",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "id": ["type": "string", "description": "The group id."],
                        "pin": ["type": "string"],
                        "confirm": ["type": "boolean"],
                        "browser": browserProperty,
                    ],
                    "required": ["id"],
                ]
            ) { args in
                guard let id = args["id"] as? String, !id.isEmpty else { return .failure("Missing 'id'.") }
                var body: [String: Any] = ["id": id]
                if let pin = args["pin"] as? String { body["pin"] = pin }
                if let confirm = args["confirm"] as? Bool { body["confirm"] = confirm }
                return relay(bridge, "settings-unlock-group", body, args)
            },
            MCPTool(
                name: "extension_snooze_group",
                description: "Snooze an extension group, as the popup's Snooze does: its saved snooze length, delay and cooldown; the group's own confirmations (call again with confirm: true every 5 s until confirmationsLeft is 0). Refused when the group doesn't allow snoozing or a snooze (or its cooldown) is running. A frozen group can be snoozed; its snooze settings are frozen with it.",
                inputSchema: [
                    "type": "object",
                    "properties": ["id": ["type": "string"], "confirm": ["type": "boolean"], "browser": browserProperty],
                    "required": ["id"],
                ]
            ) { args in
                guard let id = args["id"] as? String, !id.isEmpty else { return .failure("Missing 'id'.") }
                var body: [String: Any] = ["id": id]
                if let confirm = args["confirm"] as? Bool { body["confirm"] = confirm }
                return relay(bridge, "settings-snooze-group", body, args)
            },
            MCPTool(
                name: "extension_end_snooze",
                description: "End an extension group's running (or scheduled) snooze early, as the popup's End Snooze does. Linked devices end it too.",
                inputSchema: [
                    "type": "object",
                    "properties": ["id": ["type": "string"], "browser": browserProperty],
                    "required": ["id"],
                ]
            ) { args in
                guard let id = args["id"] as? String, !id.isEmpty else { return .failure("Missing 'id'.") }
                return relay(bridge, "settings-end-snooze", ["id": id], args)
            },
            MCPTool(
                name: "extension_move_group",
                description: "Move an extension group to a position in the group list (0 = top), as dragging it in the popup does. The first blocking group from the top decides how a page it blocks looks. A locked group cannot be moved. The order is this browser's own.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "id": ["type": "string", "description": "The group id."],
                        "index": ["type": "integer"],
                        "browser": browserProperty,
                    ],
                    "required": ["id", "index"],
                ]
            ) { args in
                guard let id = args["id"] as? String, !id.isEmpty else { return .failure("Missing 'id'.") }
                guard let index = (args["index"] as? NSNumber)?.intValue else { return .failure("Missing 'index'.") }
                return relay(bridge, "settings-move-group", ["id": id, "index": index], args)
            },
            MCPTool(
                name: "extension_set_global",
                description: "Patch the extension's global settings (popup ▸ Settings): debugMode (bool; also enables the content-script trace), showOnPageLogToasts (bool), tickRateMs (100–10000), autosaveDebounceMs (0–10000), defaultSnoozeMinutes (> 0), quickAddEnabled (bool), quitRetryMinutes (desktop: how often a blocked or rule-closed app that stayed open is asked to quit again; 0 = never). Sanitized the way the popup's save is.",
                inputSchema: [
                    "type": "object",
                    "properties": ["patch": ["type": "object", "description": "Global settings fields to change."], "browser": browserProperty],
                    "required": ["patch"],
                ]
            ) { args in
                guard let patch = args["patch"] as? [String: Any], !patch.isEmpty else { return .failure("Missing 'patch' object.") }
                return relay(bridge, "settings-set-global", ["patch": patch], args)
            },
            MCPTool(
                name: "extension_set_classifier",
                description: "Set the extension's classifier settings: collectionEnabled (whether pages are collected at all) and taggingMode ('whenFiltering' = tag only while a tag filter is active, 'always', 'paused').",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "collectionEnabled": ["type": "boolean"],
                        "taggingMode": ["type": "string", "enum": ["whenFiltering", "always", "paused"]],
                        "browser": browserProperty,
                    ],
                ]
            ) { args in
                var body: [String: Any] = [:]
                if let enabled = args["collectionEnabled"] as? Bool { body["collectionEnabled"] = enabled }
                if let mode = args["taggingMode"] as? String { body["taggingMode"] = mode }
                guard !body.isEmpty else { return .failure("Nothing to set: pass collectionEnabled and/or taggingMode.") }
                return relay(bridge, "settings-set-classifier", body, args)
            },
        ]
    }

    /// Blocks the MCP server's queue until the browser answers or the hub gives
    /// up; the hub calls back exactly once, so a plain semaphore is enough.
    static func relay(_ bridge: Bridge, _ operation: String, _ body: [String: Any], _ args: [String: Any]) -> MCPToolResult {
        relayWithWait(bridge, operation, body, args, seconds: waitSeconds)
    }

    static func relayWithWait(_ bridge: Bridge, _ operation: String, _ body: [String: Any], _ args: [String: Any], seconds: Double) -> MCPToolResult {
        let target = (args["browser"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let semaphore = DispatchSemaphore(value: 0)
        let box = OutcomeBox()
        bridge.request(operation, body, target) { result in
            box.set(result)
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + seconds) == .timedOut {
            return .failure("\(operation): the browser did not answer in time.")
        }
        switch box.get() {
        case .success(let responseBody): return .ok(jsonText(responseBody))
        case .failure(let reason): return .failure("\(operation): \(Self.explain(reason))")
        }
    }

    /// One-shot, lock-protected holder for the relay's callback value.
    final class OutcomeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: RelayOutcome = .failure("browser-no-reply")
        func set(_ outcome: RelayOutcome) { lock.lock(); value = outcome; lock.unlock() }
        func get() -> RelayOutcome { lock.lock(); defer { lock.unlock() }; return value }
    }

    static func explain(_ reason: String) -> String {
        if reason.hasPrefix("browser-ambiguous: ") {
            let choices = reason.dropFirst("browser-ambiguous: ".count)
            return "more than one browser is connected; pass 'browser' as one of: \(choices)."
        }
        switch reason {
        case "browser-unavailable": return "no browser with the Vault extension is connected to Mac Vault."
        case "browser-ambiguous": return "more than one browser is connected; pass 'browser'."
        case "browser-timeout": return "the browser did not answer."
        case "browser-relay-requires-host": return "Mac Vault is not hosting the local hub."
        case "group-locked": return "the group is frozen (the popup refuses this too)."
        case "group-not-found": return "no group has that id."
        case "not-locked": return "the group is not frozen."
        case "not-stricter": return "while frozen the freeze can only be made stricter (a longer wait)."
        case "pin-already-set": return "the group already has a PIN."
        case "snooze-disabled": return "the group doesn't allow snoozing."
        case "snooze-in-progress": return "a snooze (or its cooldown) is already running."
        case "no-snooze": return "no snooze is running."
        case "duplicate-name": return "another group already has that name (ignoring letter case)."
        default:
            let parts = reason.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return reason }
            switch parts[0] {
            case "pin-wait": return "wait \(parts[1]) s before the next PIN try (a wrong PIN was entered)."
            case "pin-wrong": return "wrong PIN; the next try waits \(parts[1]) s."
            case "strict-wait": return "the freeze's wait holds until \(parts[1])."
            case "confirm-wait": return "confirm again in \(parts[1]) s (the popup's confirmation waits 5 s)."
            default: return reason
            }
        }
    }

    private static func jsonText(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}
#endif
