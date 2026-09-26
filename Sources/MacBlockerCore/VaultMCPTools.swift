#if os(macOS)
import Foundation

/// The Vault MCP tool surface. These are bounded, named operations over the block
/// groups — never arbitrary control — each wrapping the already-tested
/// `GroupStore`, so the MCP server, the WebView bridge, and any future caller
/// share one implementation of every mutation.
public enum VaultMCPTools {
    public static func groupTools(store: GroupStore = GroupStore(), clock: @escaping () -> Date = Date.init) -> [MCPTool] {
        let unlockRequests = UnlockRequests()
        return [
            MCPTool(
                name: "list_groups",
                description: "List all block groups with their id, name, enabled state, blocking mode, and blocked site/app counts.",
                inputSchema: objectSchema([])
            ) { _ in
                let groups = store.loadGroups().map { group -> [String: Any] in
                    [
                        "id": group.id,
                        "name": group.name,
                        "enabled": group.enabled,
                        "mode": group.mode.rawValue,
                        "lock": group.freezeMode.rawValue,
                        "sites": group.targets.filter { $0.kind == .webDomain || $0.kind == .urlPattern }.count,
                        "apps": group.targets.filter { $0.kind == .application }.count,
                    ]
                }
                return .ok(jsonText(["groups": groups]))
            },

            MCPTool(
                name: "get_group",
                description: "Get one block group's full detail (mode, allowed minutes, blocked sites and apps) by id.",
                inputSchema: objectSchema([("id", "string", "The group id.")], required: ["id"])
            ) { args in
                guard let id = string(args, "id") else { return .failure("Missing 'id'.") }
                guard let group = store.loadGroups().first(where: { $0.id == id }) else {
                    return .failure("Group not found: \(id)")
                }
                return .ok(jsonText([
                    "id": group.id,
                    "name": group.name,
                    "enabled": group.enabled,
                    "mode": group.mode.rawValue,
                    "allowedMinutes": group.allowedMinutes,
                    "lock": group.freezeMode.rawValue,
                    "sites": group.targets.filter { $0.kind == .webDomain || $0.kind == .urlPattern }.map(\.normalizedValue),
                    "apps": group.targets.filter { $0.kind == .application }.map { ["id": $0.normalizedValue, "name": $0.displayName] },
                ]))
            },

            MCPTool(
                name: "set_group_enabled",
                description: "Enable or disable a block group by id.",
                inputSchema: objectSchema([
                    ("id", "string", "The group id."),
                    ("enabled", "boolean", "Whether the group should be enabled."),
                ], required: ["id", "enabled"])
            ) { args in
                guard let id = string(args, "id") else { return .failure("Missing 'id'.") }
                guard let enabled = args["enabled"] as? Bool else { return .failure("Missing 'enabled'.") }
                return run(store) { try $0.setGroupEnabled(id: id, enabled) }
                    ?? .ok("Group \(id) set enabled=\(enabled).")
            },

            MCPTool(
                name: "set_blocking_mode",
                description: "Set a group's blocking mode: 'instant' or 'after-minutes'.",
                inputSchema: objectSchema([
                    ("id", "string", "The group id."),
                    ("mode", "string", "One of: instant, after-minutes."),
                ], required: ["id", "mode"])
            ) { args in
                guard let id = string(args, "id") else { return .failure("Missing 'id'.") }
                guard let raw = string(args, "mode"), let mode = BlockingMode(rawValue: raw) else {
                    return .failure("Invalid 'mode'. Use instant or after-minutes.")
                }
                return run(store) { try $0.setGroupMode(id: id, mode) }
                    ?? .ok("Group \(id) mode set to \(mode.rawValue).")
            },

            MCPTool(
                name: "rename_group",
                description: "Rename a block group by id.",
                inputSchema: objectSchema([
                    ("id", "string", "The group id."),
                    ("name", "string", "The new group name."),
                ], required: ["id", "name"])
            ) { args in
                guard let id = string(args, "id") else { return .failure("Missing 'id'.") }
                guard let name = string(args, "name") else { return .failure("Missing 'name'.") }
                return run(store) { try $0.renameGroup(id: id, name: name) }
                    ?? .ok("Group \(id) renamed.")
            },

            MCPTool(
                name: "add_website",
                description: "Add a website (host or URL) to a group's blocked sites.",
                inputSchema: objectSchema([
                    ("id", "string", "The group id."),
                    ("host", "string", "The site host or URL to block."),
                ], required: ["id", "host"])
            ) { args in
                guard let id = string(args, "id") else { return .failure("Missing 'id'.") }
                guard let host = string(args, "host") else { return .failure("Missing 'host'.") }
                return run(store) { try $0.addWebsite(id: id, host: host) }
                    ?? .ok("Added \(host) to group \(id).")
            },

            MCPTool(
                name: "remove_website",
                description: "Remove a website from a group's blocked sites.",
                inputSchema: objectSchema([
                    ("id", "string", "The group id."),
                    ("host", "string", "The site host or URL to remove."),
                ], required: ["id", "host"])
            ) { args in
                guard let id = string(args, "id") else { return .failure("Missing 'id'.") }
                guard let host = string(args, "host") else { return .failure("Missing 'host'.") }
                return run(store) { try $0.removeWebsite(id: id, host: host) }
                    ?? .ok("Removed \(host) from group \(id).")
            },

            MCPTool(
                name: "add_application",
                description: "Add a macOS application (by bundle identifier) to a group's blocked apps.",
                inputSchema: objectSchema([
                    ("id", "string", "The group id."),
                    ("bundleId", "string", "The application's bundle identifier."),
                    ("name", "string", "Optional display name."),
                ], required: ["id", "bundleId"])
            ) { args in
                guard let id = string(args, "id") else { return .failure("Missing 'id'.") }
                guard let bundleId = string(args, "bundleId") else { return .failure("Missing 'bundleId'.") }
                return run(store) { try $0.addApplication(id: id, bundleID: bundleId, name: string(args, "name")) }
                    ?? .ok("Added \(bundleId) to group \(id).")
            },

            MCPTool(
                name: "remove_application",
                description: "Remove an application (by bundle identifier) from a group's blocked apps.",
                inputSchema: objectSchema([
                    ("id", "string", "The group id."),
                    ("bundleId", "string", "The application's bundle identifier."),
                ], required: ["id", "bundleId"])
            ) { args in
                guard let id = string(args, "id") else { return .failure("Missing 'id'.") }
                guard let bundleId = string(args, "bundleId") else { return .failure("Missing 'bundleId'.") }
                return run(store) { try $0.removeApplication(id: id, bundleID: bundleId) }
                    ?? .ok("Removed \(bundleId) from group \(id).")
            },

            MCPTool(
                name: "create_group",
                description: "Create an unlocked block group with the editor's defaults (instant, every day, no sites or apps yet). Names are unique, ignoring letter case. Returns the new id.",
                inputSchema: objectSchema([("name", "string", "The group name.")], required: ["name"])
            ) { args in
                guard let name = string(args, "name") else { return .failure("Missing 'name'.") }
                var id = ""
                return run(store) { id = try $0.createGroup(name: name, now: clock()) } ?? .ok(jsonText(["id": id]))
            },

            MCPTool(
                name: "lock_group",
                description: "Lock a group, as the editor's Freeze does. mode 'frozen' (unlocking needs a confirmation), 'strict' (cannot be unlocked for strictHours, 0 < hours ≤ 72; default the group's own) or 'parental' (unlocking needs the 6-digit PIN; pass the group's PIN — or, when the group has none yet, the new PIN to set). A wrong PIN makes the next try wait 1 s, 2 s, 4 s … up to 64 s, shared with the editor.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "id": ["type": "string", "description": "The group id."],
                        "mode": ["type": "string", "enum": ["frozen", "strict", "parental"]],
                        "strictHours": ["type": "number", "description": "For strict: how long it stays locked."],
                        "pin": ["type": "string", "description": "For parental: the 6-digit PIN."],
                    ],
                    "required": ["id", "mode"],
                ]
            ) { args in
                guard let id = string(args, "id") else { return .failure("Missing 'id'.") }
                guard let raw = string(args, "mode"), let mode = WebStoreDocument.LockMode(rawValue: raw) else {
                    return .failure("Invalid 'mode'. Use frozen, strict or parental.")
                }
                let hours = (args["strictHours"] as? NSNumber)?.doubleValue
                var outcome = WebStoreDocument.LockOutcome.done
                if let failure = run(store, { outcome = try $0.lockGroup(id: id, mode: mode, strictHours: hours, pin: string(args, "pin"), now: clock()) }) {
                    return failure
                }
                return outcome == .done ? .ok("Group \(id) locked (\(mode.rawValue)).") : .failure(explain(outcome))
            },

            MCPTool(
                name: "unlock_group",
                description: "Unlock a group through the editor's gates. Parental: pass the PIN (a wrong PIN makes the next try wait 1 s … 64 s). Strict: refused until its hours are over. Otherwise the editor's confirmation: the first call asks, a second call with confirm: true at least 5 seconds later (within 5 minutes) unlocks.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "id": ["type": "string", "description": "The group id."],
                        "pin": ["type": "string", "description": "For a parental lock: the 6-digit PIN."],
                        "confirm": ["type": "boolean", "description": "Confirm an unlock asked for at least 5 seconds ago."],
                    ],
                    "required": ["id"],
                ]
            ) { args in
                guard let id = string(args, "id") else { return .failure("Missing 'id'.") }
                let now = clock()
                var confirmed = false
                if args["confirm"] as? Bool == true {
                    switch unlockRequests.readiness(id: id, now: now) {
                    case .ready: confirmed = true
                    case .wait(let seconds): return .failure("Confirm again in \(seconds) s (the editor's confirmation waits 5 s).")
                    case .none: break
                    }
                }
                var outcome = WebStoreDocument.LockOutcome.done
                if let failure = run(store, { outcome = try $0.unlockGroup(id: id, pin: string(args, "pin"), confirmed: confirmed, now: now) }) {
                    return failure
                }
                switch outcome {
                case .done:
                    unlockRequests.clear(id: id)
                    return .ok("Group \(id) unlocked.")
                case .needsConfirmation:
                    unlockRequests.ask(id: id, now: now)
                    return .ok("Unlock asked. Call unlock_group again with confirm: true after 5 seconds (within 5 minutes).")
                default:
                    return .failure(explain(outcome))
                }
            },

            MCPTool(
                name: "move_group",
                description: "Move a group to a position in the group list (0 = top), as dragging it in the editor does. The first blocking group from the top decides how a page it blocks looks. A locked group cannot be moved. The order is this device's own.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "id": ["type": "string", "description": "The group id."],
                        "index": ["type": "integer", "description": "The new position, 0-based."],
                    ],
                    "required": ["id", "index"],
                ]
            ) { args in
                guard let id = string(args, "id") else { return .failure("Missing 'id'.") }
                guard let index = (args["index"] as? NSNumber)?.intValue else { return .failure("Missing 'index'.") }
                return run(store) { try $0.moveGroup(id: id, to: index) } ?? .ok("Group \(id) moved to position \(index).")
            },

            MCPTool(
                name: "delete_group",
                description: "Delete a block group by id.",
                inputSchema: objectSchema([("id", "string", "The group id.")], required: ["id"])
            ) { args in
                guard let id = string(args, "id") else { return .failure("Missing 'id'.") }
                return run(store) { try $0.deleteGroup(id: id) }
                    ?? .ok("Deleted group \(id).")
            },
        ]
    }

    // MARK: Helpers

    private static func explain(_ outcome: WebStoreDocument.LockOutcome) -> String {
        switch outcome {
        case .done: return "Done."
        case .strictUntil(let date): return "Strict lock: it opens at \(ISO8601DateFormatter().string(from: date))."
        case .needsConfirmation: return "Needs the confirmation step."
        case .pinWait(let seconds): return "Wait \(seconds) s before the next PIN try (a wrong PIN was entered)."
        case .pinWrong(let seconds): return "Wrong PIN. The next try waits \(seconds) s."
        }
    }

    /// Unlocks asked for (the editor's confirmation: ask, wait 5 s, confirm).
    final class UnlockRequests: @unchecked Sendable {
        enum Readiness { case ready, wait(Int), none }
        static let intervalSeconds: TimeInterval = 5 // popup UNFREEZE_CONFIRMATION_INTERVAL_MS
        static let lifetimeSeconds: TimeInterval = 300
        private let lock = NSLock()
        private var askedAt: [String: Date] = [:]

        func ask(id: String, now: Date) { lock.lock(); askedAt[id] = now; lock.unlock() }
        func clear(id: String) { lock.lock(); askedAt.removeValue(forKey: id); lock.unlock() }
        func readiness(id: String, now: Date) -> Readiness {
            lock.lock(); defer { lock.unlock() }
            guard let asked = askedAt[id], now.timeIntervalSince(asked) < Self.lifetimeSeconds else { return .none }
            let left = Self.intervalSeconds - now.timeIntervalSince(asked)
            return left > 0 ? .wait(Int(left.rounded(.up))) : .ready
        }
    }

    /// Applies a mutation and returns a failure result on error, or nil on
    /// success (the caller supplies the success text).
    private static func run(_ store: GroupStore, _ body: (inout WebStoreDocument) throws -> Void) -> MCPToolResult? {
        do {
            try store.mutate(body)
            return nil
        } catch {
            return .failure(describe(error))
        }
    }

    private static func string(_ args: [String: Any], _ key: String) -> String? {
        guard let value = args[key] as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func describe(_ error: Error) -> String {
        if let error = error as? GroupStoreError {
            switch error {
            case .groupNotFound(let id): return "Group not found: \(id)"
            case .invalidInput(let field): return "Invalid input: \(field)"
            case .groupLocked(let id): return "Group \(id) is frozen, strict or parental-locked (the editor refuses this too)."
            case .duplicateName(let name): return "Another group is already named \(name) (the editor refuses this too)."
            case .notLocked(let id): return "Group \(id) is not locked."
            case .pinRequired: return "A parental lock needs a PIN: pass 'pin' (6 digits); it becomes the group's parental PIN."
            }
        }
        return (error as NSError).localizedDescription
    }

    private static func jsonText(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    /// Builds a JSON-Schema object for a tool's input.
    private static func objectSchema(
        _ properties: [(name: String, type: String, description: String)],
        required: [String] = []
    ) -> [String: Any] {
        var props: [String: Any] = [:]
        for property in properties {
            props[property.name] = ["type": property.type, "description": property.description]
        }
        var schema: [String: Any] = ["type": "object", "properties": props]
        if !required.isEmpty { schema["required"] = required }
        return schema
    }
}
#endif
