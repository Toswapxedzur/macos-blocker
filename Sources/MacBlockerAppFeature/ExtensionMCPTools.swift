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
                description: "The Vault browser extension's settings as JSON: every block group (platform rules with author / subreddit / tag filters, cover-until-tagged, page blocking, schedules, snooze rules, freeze state; site and custom groups), usage timers, active snoozes, the classifier settings (collection on/off, tagging mode) and global settings. Read live from the connected browser.",
                inputSchema: ["type": "object", "properties": ["browser": browserProperty]]
            ) { args in
                relay(bridge, "settings-get", [:], args)
            },
            MCPTool(
                name: "extension_create_group",
                description: "Create an extension block group of a type (youtube, tiktok, facebook, instagram, twitch, reddit, discord, twitter, bilibili, …, site, custom) with the popup's defaults, then apply an optional patch of group fields (e.g. name, platformTagMode 'include'|'exclude', platformTags [{name, confidence?, also?, except?}], platformTagBlockPage, platformTagCoverUntilTagged, platformTagEffect 'dim'|'block', sourceMode 'all'|'include'|'exclude'|'nobody' with sources [creators, accounts or subreddits], discordMode with discordTargets, surfaceHides, blockHomePage, sites/allowlist — or, instead of those flat fields, scopes: [{surface 'site'|'items'|'pages'|'home'|'shelf', platform, sites/sitesExcept, form, sourceMode/sources, tagFilter, shelf, action 'block'|'hide'|'dim'}]; stored groups are returned as policy fields + scopes; mode, allowedMinutes, activeDays, timeWindowsText, sites, blockingRulesText). Fields pass the extension's own sanitizer.",
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
                description: "Patch fields of an existing extension block group by id (see extension_create_group for the fields). The id and the freeze / parental lock are never patchable; a frozen, strict or parental-locked group is refused, exactly as in the popup.",
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
                description: "Delete an extension block group by id. A frozen, strict or parental-locked group is refused, exactly as in the popup.",
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
                name: "extension_set_global",
                description: "Patch the extension's global settings (popup ▸ Settings): debugMode (bool; also enables the content-script trace), showOnPageLogToasts (bool), tickRateMs (100–10000), autosaveDebounceMs (0–10000), defaultSnoozeMinutes (> 0). Sanitized the way the popup's save is.",
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
        case "group-locked": return "the group is frozen, strict or parental-locked (the popup refuses this too)."
        case "group-not-found": return "no group has that id."
        default: return reason
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
