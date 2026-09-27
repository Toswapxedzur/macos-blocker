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
                description: "List all block groups: id, name, on/off, mode, frozen, and how many websites and apps each lists.",
                inputSchema: objectSchema([])
            ) { _ in
                let document = store.load()
                let groups = document.groupIDs.compactMap { document.group(id: $0) }.map { group -> [String: Any] in
                    [
                        "id": group["id"] ?? "", "name": group["name"] ?? "", "enabled": group["enabled"] ?? true,
                        "mode": group["mode"] ?? "instant", "locked": WebStoreDocument.isLocked(group),
                        "sites": WebStoreDocument.sites(of: group).count, "apps": WebStoreDocument.apps(of: group).count,
                    ]
                }
                return .ok(jsonText(["groups": groups]))
            },

            MCPTool(
                name: "get_group",
                description: "One block group as stored (the editor's fields): its settings, its lines (scopes) — including sitesExcept / appsExcept (\"block everything except these\") — and its freeze (without the PIN itself).",
                inputSchema: objectSchema([("id", "string", "The group id.")], required: ["id"])
            ) { args in
                guard let id = string(args, "id") else { return .failure("Missing 'id'.") }
                guard var group = store.load().group(id: id) else { return .failure("Group not found: \(id)") }
                group["locked"] = WebStoreDocument.isLocked(group)
                group["hasParentalPin"] = group["parentalPasswordHash"] is String
                for secret in ["parentalPasswordHash", "parentalPasswordSalt"] { group.removeValue(forKey: secret) }
                return .ok(jsonText(group))
            },

            MCPTool(
                name: "set_group",
                description: "Change a group's fields, as the editor does: name, enabled, mode (instant | after-minutes; a custom group stays instant), allowedMinutes, resetIntervalHours, resetAtMidnight, rollingLimit, activeDays, timeWindowsText (HHMM-HHMM lines), allowSnooze, snoozeMinutes, snoozeActivationDelayMinutes, snoozeCooldownMinutes (≤ 5), snoozeConfirmations, fallbackUrl, pauseSeconds, and scopes (the group's lines, as get_group shows them). A value the editor refuses is refused, never replaced by a default. A frozen group can't be changed; the freeze has its own tools.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "id": ["type": "string", "description": "The group id."],
                        "patch": ["type": "object", "description": "The fields to change."],
                    ],
                    "required": ["id", "patch"],
                ]
            ) { args in
                guard let id = string(args, "id") else { return .failure("Missing 'id'.") }
                guard let patch = args["patch"] as? [String: Any], !patch.isEmpty else { return .failure("Missing 'patch' object.") }
                return run(store) { try $0.setGroup(id: id, patch: patch) } ?? .ok("Group \(id) changed.")
            },

            MCPTool(
                name: "set_settings",
                description: "Change Mac Vault's settings — exactly the editor's Settings: defaultSnoozeMinutes (> 0), quitRetryMinutes (0–1440: how often a blocked or rule-closed app that stayed open is asked to quit again; 0 = never), quickAddEnabled (the floating \"+\"), quickAddGroupId (its target group, or \"\").",
                inputSchema: ["type": "object", "properties": ["patch": ["type": "object", "description": "The settings to change."]], "required": ["patch"]]
            ) { args in
                guard let patch = args["patch"] as? [String: Any], !patch.isEmpty else { return .failure("Missing 'patch' object.") }
                return run(store) { try $0.setSettings(patch) } ?? .ok("Settings changed.")
            },

            MCPTool(
                name: "add_website",
                description: "Add a website (a host, or a host with a path like youtube.com/shorts) to the group's Websites entry — its block list, or with sitesExcept the sites it lets through.",
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
                description: "Remove that website entry from the group's Websites entry (a path entry never takes its host with it).",
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
                description: "Add a macOS application (by bundle identifier) to the group's Apps entry — its block list, or with appsExcept the apps it lets through.",
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
                description: "Remove an application (by bundle identifier) from the group's Apps entry.",
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
                description: "Freeze a group, as the editor's Freeze does, with optional gates that combine: waitHours (it cannot be unfrozen for that long, 0 < hours ≤ 72) and pin (6 digits: unfreezing then needs this PIN). On a group that is already frozen the same call can only make the freeze stricter: a longer wait, or a PIN where there was none. Every unfreeze also ends with the confirmation (10 steps, 5 s apart).",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "id": ["type": "string", "description": "The group id."],
                        "waitHours": ["type": "number", "description": "The wait gate in hours."],
                        "pin": ["type": "string", "description": "A new 6-digit PIN gate (only when the group has none)."],
                    ],
                    "required": ["id"],
                ]
            ) { args in
                guard let id = string(args, "id") else { return .failure("Missing 'id'.") }
                let hours = (args["waitHours"] as? NSNumber)?.doubleValue
                var outcome = WebStoreDocument.LockOutcome.done
                if let failure = run(store, { outcome = try $0.lockGroup(id: id, waitHours: hours, pin: string(args, "pin"), now: clock()) }) {
                    return failure
                }
                return outcome == .done ? .ok("Group \(id) is frozen.") : .failure(explain(outcome))
            },

            MCPTool(
                name: "unlock_group",
                description: "Unfreeze a group through the editor's gates. The wait gate must be over; a set PIN must be passed (pin; a wrong PIN makes the next try wait 1 s … 64 s, shared with the editor); then the confirmation: call again with confirm: true every 5 seconds until no confirmation is left (10 in all, within 5 minutes).",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "id": ["type": "string", "description": "The group id."],
                        "pin": ["type": "string", "description": "The group's 6-digit PIN, when it has one."],
                        "confirm": ["type": "boolean", "description": "One confirmation step."],
                    ],
                    "required": ["id"],
                ]
            ) { args in
                guard let id = string(args, "id") else { return .failure("Missing 'id'.") }
                let now = clock()
                if args["confirm"] as? Bool == true, let request = unlockRequests.request(id: id, now: now) {
                    let step = GroupActionsRuntime.shared.call("confirmStep", [request.state, (now.timeIntervalSince1970 * 1000).rounded()]) as? [String: Any] ?? [:]
                    let waitMs = (step["waitMs"] as? NSNumber)?.doubleValue ?? 0
                    if waitMs > 0 { return .failure("Confirm again in \(Int((waitMs / 1000).rounded(.up))) s (the editor's confirmation waits 5 s).") }
                    let state = step["state"] as? [String: Any] ?? [:]
                    guard step["done"] as? Bool == true else {
                        unlockRequests.save(id: id, lockVersion: request.lockVersion, state: state, now: now)
                        return .ok("Confirmation counted: \((state["left"] as? NSNumber)?.intValue ?? 0) left. Call again with confirm: true in 5 seconds.")
                    }
                    unlockRequests.clear(id: id)
                    var outcome = WebStoreDocument.LockOutcome.done
                    if let failure = run(store, { outcome = try $0.unlockGroup(id: id, lockVersion: request.lockVersion, now: now) }) { return failure }
                    return outcome == .done ? .ok("Group \(id) is unfrozen.") : .failure(explain(outcome))
                }
                var outcome = WebStoreDocument.LockOutcome.done
                var lockVersion = 0
                if let failure = run(store, { document in
                    outcome = try document.unlockCheck(id: id, pin: string(args, "pin"), now: now)
                    lockVersion = document.checkedLockVersion ?? 0
                }) { return failure }
                guard outcome == .done else { return .failure(explain(outcome)) }
                let state = GroupActionsRuntime.shared.call("confirmStart", [(now.timeIntervalSince1970 * 1000).rounded()]) as? [String: Any] ?? [:]
                unlockRequests.save(id: id, lockVersion: lockVersion, state: state, now: now)
                return .ok("Unfreeze started: \((state["left"] as? NSNumber)?.intValue ?? 0) confirmations left. Call unlock_group with confirm: true every 5 seconds (within 5 minutes).")
            },

            MCPTool(
                name: "snooze_group",
                description: "Snooze a group, as the editor's Snooze does: its saved snooze length, delay and cooldown; the group's own confirmations (call again with confirm: true every 5 s until none is left). Refused when the group doesn't allow snoozing or a snooze (or its cooldown) is running. A frozen group can be snoozed; its snooze settings are frozen with it. A custom group's snooze is its rule's: this fires the rule's snoozePress, as the editor's button does.",
                inputSchema: [
                    "type": "object",
                    "properties": ["id": ["type": "string", "description": "The group id."], "confirm": ["type": "boolean"]],
                    "required": ["id"],
                ]
            ) { args in
                guard let id = string(args, "id") else { return .failure("Missing 'id'.") }
                // A custom group's snooze is its rule's (owner 2026-09-27), as in the editor.
                if store.load().group(id: id)?["groupType"] as? String == "custom" {
                    guard let press = snoozePress else { return .failure("Mac Vault's rule engine isn't running.") }
                    press(id)
                    return .ok("The group's rule got its snooze press.")
                }
                let now = clock()
                let nowMs = (now.timeIntervalSince1970 * 1000).rounded()
                let key = "snooze:\(id)"
                if args["confirm"] as? Bool == true, let request = unlockRequests.request(id: key, now: now) {
                    let step = GroupActionsRuntime.shared.call("confirmStep", [request.state, nowMs]) as? [String: Any] ?? [:]
                    let waitMs = (step["waitMs"] as? NSNumber)?.doubleValue ?? 0
                    if waitMs > 0 { return .failure("Confirm again in \(Int((waitMs / 1000).rounded(.up))) s (the editor's confirmation waits 5 s).") }
                    let state = step["state"] as? [String: Any] ?? [:]
                    guard step["done"] as? Bool == true else {
                        unlockRequests.save(id: key, lockVersion: 0, state: state, now: now)
                        return .ok("Confirmation counted: \((state["left"] as? NSNumber)?.intValue ?? 0) left. Call again with confirm: true in 5 seconds.")
                    }
                    unlockRequests.clear(id: key)
                } else {
                    let plan: (confirmations: Int, refusal: String?)
                    do { plan = try store.load().snoozePlan(id: id, now: now) } catch { return .failure(describe(error)) }
                    if let refusal = plan.refusal { return .failure(explain(.refused(refusal))) }
                    if plan.confirmations > 0 {
                        let state = GroupActionsRuntime.shared.call("confirmStart", [nowMs, plan.confirmations]) as? [String: Any] ?? [:]
                        unlockRequests.save(id: key, lockVersion: 0, state: state, now: now)
                        return .ok("Snooze asked: \(plan.confirmations) confirmations. Call snooze_group with confirm: true every 5 seconds (within 5 minutes).")
                    }
                }
                var outcome = WebStoreDocument.LockOutcome.done
                if let failure = run(store, { outcome = try $0.startSnooze(id: id, now: clock()) }) { return failure }
                return outcome == .done ? .ok("Group \(id) is snoozed.") : .failure(explain(outcome))
            },

            MCPTool(
                name: "end_snooze",
                description: "End a group's running (or scheduled) snooze early, as the editor's End Snooze does. Linked devices end it too.",
                inputSchema: objectSchema([("id", "string", "The group id.")], required: ["id"])
            ) { args in
                guard let id = string(args, "id") else { return .failure("Missing 'id'.") }
                var outcome = WebStoreDocument.LockOutcome.done
                if let failure = run(store, { outcome = try $0.endSnooze(id: id, now: clock()) }) { return failure }
                return outcome == .done ? .ok("Group \(id)'s snooze ended.") : .failure(explain(outcome))
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
                name: "set_lock_gates",
                description: "Set the freeze gates of an unfrozen group, as the editor's guardian settings do: waitHours (0 < hours ≤ 72) and/or pin (6 digits, where none is set); clearPin: true removes the PIN (pass the current pin). Refused on a frozen group (make it stricter with lock_group).",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "id": ["type": "string", "description": "The group id."],
                        "waitHours": ["type": "number"], "pin": ["type": "string"], "clearPin": ["type": "boolean"],
                    ],
                    "required": ["id"],
                ]
            ) { args in
                guard let id = string(args, "id") else { return .failure("Missing 'id'.") }
                var outcome = WebStoreDocument.LockOutcome.done
                if let failure = run(store, { outcome = try $0.setLockGates(id: id, waitHours: (args["waitHours"] as? NSNumber)?.doubleValue,
                                                                             pin: string(args, "pin"), clearPin: args["clearPin"] as? Bool == true, now: clock()) }) { return failure }
                return outcome == .done ? .ok("Group \(id)'s freeze gates are set.") : .failure(explain(outcome))
            },

            MCPTool(
                name: "delete_all_groups",
                description: "Delete every group, as the editor's Delete all does: refused while any frozen group's wait still holds; pins lists the PIN of each distinct PIN-protected frozen group; with any frozen group it ends with the confirmation (call again with confirm: true every 5 s until none is left).",
                inputSchema: [
                    "type": "object",
                    "properties": ["pins": ["type": "array", "items": ["type": "string"]], "confirm": ["type": "boolean"]],
                ]
            ) { args in
                let now = clock()
                let nowMs = (now.timeIntervalSince1970 * 1000).rounded()
                if args["confirm"] as? Bool == true, let request = unlockRequests.request(id: "delete-all", now: now) {
                    let step = GroupActionsRuntime.shared.call("confirmStep", [request.state, nowMs]) as? [String: Any] ?? [:]
                    let waitMs = (step["waitMs"] as? NSNumber)?.doubleValue ?? 0
                    if waitMs > 0 { return .failure("Confirm again in \(Int((waitMs / 1000).rounded(.up))) s (the editor's confirmation waits 5 s).") }
                    let state = step["state"] as? [String: Any] ?? [:]
                    guard step["done"] as? Bool == true else {
                        unlockRequests.save(id: "delete-all", lockVersion: 0, state: state, now: now)
                        return .ok("Confirmation counted: \((state["left"] as? NSNumber)?.intValue ?? 0) left. Call again with confirm: true in 5 seconds.")
                    }
                    unlockRequests.clear(id: "delete-all")
                    return run(store) { $0.deleteAll() } ?? .ok("Every group is deleted.")
                }
                var outcome = WebStoreDocument.LockOutcome.done
                var needsConfirmation = false
                let pins = (args["pins"] as? [Any] ?? []).map { "\($0)" }
                if let failure = run(store, { document in
                    outcome = document.deleteAllCheck(pins: pins, now: now)
                    needsConfirmation = document.deleteAllNeedsConfirmation
                    if outcome == .done, !needsConfirmation { document.deleteAll() }
                }) { return failure }
                guard outcome == .done else { return .failure(explain(outcome)) }
                guard needsConfirmation else { return .ok("Every group is deleted.") }
                let state = GroupActionsRuntime.shared.call("confirmStart", [nowMs]) as? [String: Any] ?? [:]
                unlockRequests.save(id: "delete-all", lockVersion: 0, state: state, now: now)
                return .ok("Delete all started: \((state["left"] as? NSNumber)?.intValue ?? 0) confirmations left. Call delete_all_groups with confirm: true every 5 seconds (within 5 minutes).")
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

    /// A custom group's snooze press, supplied by Mac Vault's rule engine.
    nonisolated(unsafe) public static var snoozePress: ((String) -> Void)?

    // MARK: Helpers

    private static func explain(_ outcome: WebStoreDocument.LockOutcome) -> String {
        switch outcome {
        case .done: return "Done."
        case .waitUntil(let date): return "The freeze's wait holds until \(ISO8601DateFormatter().string(from: date))."
        case .pinWait(let seconds): return "Wait \(seconds) s before the next PIN try (a wrong PIN was entered)."
        case .pinWrong(let seconds): return "Wrong PIN. The next try waits \(seconds) s."
        case .refused("not-stricter"): return "While frozen the freeze can only be made stricter (a longer wait)."
        case .refused("pin-already-set"): return "The group already has a PIN."
        case .refused("lock-changed"): return "The freeze changed meanwhile; start the unfreeze again."
        case .refused("snooze-disabled"): return "The group doesn't allow snoozing."
        case .refused("snooze-in-progress"): return "A snooze (or its cooldown) is already running."
        case .refused("no-snooze"): return "No snooze is running."
        case .refused(let reason): return reason
        }
    }

    /// Unfreezes asked for: the confirmation state (group-actions.js
    /// confirmStart / confirmStep) per group, for the lock version it began on.
    final class UnlockRequests: @unchecked Sendable {
        struct Request { let lockVersion: Int; let state: [String: Any]; let askedAt: Date }
        static let lifetimeSeconds: TimeInterval = 300
        private let lock = NSLock()
        private var requests: [String: Request] = [:]

        func save(id: String, lockVersion: Int, state: [String: Any], now: Date) {
            lock.lock(); defer { lock.unlock() }
            let askedAt = requests[id].map { $0.lockVersion == lockVersion ? $0.askedAt : now } ?? now
            requests[id] = Request(lockVersion: lockVersion, state: state, askedAt: askedAt)
        }
        func clear(id: String) { lock.lock(); requests.removeValue(forKey: id); lock.unlock() }
        func request(id: String, now: Date) -> Request? {
            lock.lock(); defer { lock.unlock() }
            guard let request = requests[id], now.timeIntervalSince(request.askedAt) < Self.lifetimeSeconds else { return nil }
            return request
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
            case .groupLocked(let id): return "Group \(id) is frozen (the editor refuses this too)."
            case .duplicateName(let name): return "Another group is already named \(name) (the editor refuses this too)."
            case .notLocked(let id): return "Group \(id) is not frozen."
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
