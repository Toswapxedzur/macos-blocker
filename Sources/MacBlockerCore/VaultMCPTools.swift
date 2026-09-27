#if os(macOS)
import Foundation

/// The Vault MCP tool surface: the editor's own actions on Mac Vault's groups,
/// with its gates (owner: tools do exactly what the user can) — never arbitrary
/// control. Each wraps `GroupStore`, which runs the editor's rules. Mac Vault
/// controls apps only (the scope line): these tools never edit a website or
/// platform line. Results are JSON, like the extension tools'.
public enum VaultMCPTools {
    public static func groupTools(store: GroupStore = GroupStore(), clock: @escaping () -> Date = Date.init) -> [MCPTool] {
        let confirmations = Confirmations()
        let group: ([String: Any], String?) -> MCPToolResult = { args, key in
            guard let id = string(args, "id"), let shown = store.load().publicGroup(id: id) else { return refuse("group-not-found") }
            return .ok(jsonText(key.map { [$0: shown] } ?? shown))
        }
        return [
            MCPTool(
                name: "list_groups",
                description: "List all block groups: id, name, enabled, mode, locked (frozen), and how many apps each lists. Linked groups show the shared state.",
                inputSchema: objectSchema([])
            ) { _ in
                let document = store.load()
                let groups = document.groupIDs.compactMap { document.publicGroup(id: $0) }.map { shown -> [String: Any] in
                    ["id": shown["id"] ?? "", "name": shown["name"] ?? "", "enabled": shown["enabled"] ?? true,
                     "mode": shown["mode"] ?? "instant", "locked": shown["locked"] ?? false, "apps": WebStoreDocument.apps(of: shown).count]
                }
                return .ok(jsonText(["groups": groups]))
            },

            MCPTool(
                name: "get_group",
                description: "One block group as stored (the editor's fields): its settings, its lines (scopes; appsExcept = \"block every app except these\"), locked and hasParentalPin (never the PIN). Linked groups show the shared state; their website and platform lines are a browser's.",
                inputSchema: objectSchema([("id", "string", "The group id.")], required: ["id"])
            ) { args in group(args, nil) },

            MCPTool(
                name: "set_group",
                description: "Change a group's fields, as the editor does: name, enabled, mode (instant | after-minutes; a custom group stays instant), allowedMinutes, resetIntervalHours, resetAtMidnight, rollingLimit, activeDays (at least one), timeWindowsText (HHMM-HHMM lines), allowSnooze, snoozeMinutes, snoozeActivationDelayMinutes, snoozeCooldownMinutes (≤ 5), snoozeConfirmations, fallbackUrl, pauseSeconds, and scopes — Mac Vault's own lines only (the Apps lines; website and platform lines are a browser's and are refused). A value the editor refuses is refused, never replaced by a default. A frozen group can't be changed; the freeze has its own tools. Returns the group.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "id": ["type": "string", "description": "The group id."],
                        "patch": ["type": "object", "description": "The fields to change."],
                    ],
                    "required": ["id", "patch"],
                ]
            ) { args in
                guard let id = string(args, "id") else { return refuse("group-not-found") }
                guard let patch = args["patch"] as? [String: Any], !patch.isEmpty else { return .failure("Missing 'patch' object.") }
                return apply(store) { try $0.setGroup(id: id, patch: patch) } ?? group(args, "group")
            },

            MCPTool(
                name: "set_settings",
                description: "Change Mac Vault's settings — exactly the editor's Settings: defaultSnoozeMinutes (> 0), quitRetryMinutes (whole minutes 0–1440: how often a blocked or rule-closed app that stayed open is asked to quit again; 0 = never), quickAddEnabled (the floating \"+\"), quickAddGroupId (its target group, or \"\"). A value the editor refuses is refused. Returns the settings.",
                inputSchema: ["type": "object", "properties": ["patch": ["type": "object", "description": "The settings to change."]], "required": ["patch"]]
            ) { args in
                guard let patch = args["patch"] as? [String: Any], !patch.isEmpty else { return .failure("Missing 'patch' object.") }
                if let failure = apply(store, { try $0.setSettings(patch) }) { return failure }
                return .ok(jsonText(store.load().editorSettings))
            },

            MCPTool(
                name: "add_application",
                description: "Add a macOS application (by bundle identifier) to the group's Apps entry — its block list, or with appsExcept the apps it lets through. Returns the group.",
                inputSchema: objectSchema([
                    ("id", "string", "The group id."),
                    ("bundleId", "string", "The application's bundle identifier."),
                    ("name", "string", "Optional display name."),
                ], required: ["id", "bundleId"])
            ) { args in
                guard let id = string(args, "id") else { return refuse("group-not-found") }
                guard let bundleId = string(args, "bundleId") else { return refuse("invalid-bundleId") }
                return apply(store) { try $0.addApplication(id: id, bundleID: bundleId, name: string(args, "name")) } ?? group(args, "group")
            },

            MCPTool(
                name: "remove_application",
                description: "Remove an application (by bundle identifier) from the group's Apps entry. Returns the group.",
                inputSchema: objectSchema([
                    ("id", "string", "The group id."),
                    ("bundleId", "string", "The application's bundle identifier."),
                ], required: ["id", "bundleId"])
            ) { args in
                guard let id = string(args, "id") else { return refuse("group-not-found") }
                guard let bundleId = string(args, "bundleId") else { return refuse("invalid-bundleId") }
                return apply(store) { try $0.removeApplication(id: id, bundleID: bundleId) } ?? group(args, "group")
            },

            MCPTool(
                name: "create_group",
                description: "Create an unlocked group as the editor's New group does in Mac Vault: groupType site (an Apps group, the default) or custom (a rule group); the user's default snooze length; a free numbered name unless patch.name is given (names are unique, ignoring letter case); optional patch fields as set_group takes them. Returns the group.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "groupType": ["type": "string", "description": "site (default) or custom."],
                        "patch": ["type": "object", "description": "Optional fields, as set_group."],
                    ],
                ]
            ) { args in
                let type = string(args, "groupType") ?? "site"
                let patch = args["patch"] as? [String: Any] ?? [:]
                var id = ""
                if let failure = apply(store, { id = try $0.createGroup(groupType: type, patch: patch) }) { return failure }
                return group(["id": id], "group")
            },

            MCPTool(
                name: "lock_group",
                description: "Freeze a group, as the editor's Freeze does, with optional gates that combine: waitHours (it cannot be unfrozen for that long; 0 or blank = no wait, at most 72) and pin (6 digits: unfreezing then needs this PIN). On a frozen group the same call can only make the freeze stricter: a longer wait, or a PIN where there was none. Every unfreeze ends with the confirmation (10 steps, 5 s apart). Returns the group.",
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
                guard let id = string(args, "id") else { return refuse("group-not-found") }
                var outcome = WebStoreDocument.LockOutcome.done
                if let failure = apply(store, { outcome = try $0.lockGroup(id: id, waitHours: args["waitHours"], pin: string(args, "pin"), now: clock()) }) {
                    return failure
                }
                return outcome == .done ? group(args, "group") : refuse(outcome.code)
            },

            MCPTool(
                name: "unlock_group",
                description: "Unfreeze a group through the editor's gates. The wait gate must be over; a set PIN must be passed (pin; a wrong PIN makes the next try wait 1 s … 64 s, shared with the editor); then the confirmation: call again with confirm: true every 5 seconds until confirmationsLeft is 0 (10 in all, within 5 minutes). A freeze that changes meanwhile starts it over.",
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
                guard let id = string(args, "id"), let shown = store.load().publicGroup(id: id) else { return refuse("group-not-found") }
                guard shown["locked"] as? Bool == true else { return refuse("not-locked") }
                let now = clock()
                let count = (GroupActionsRuntime.shared.constant("CONFIRMATIONS") as? NSNumber)?.intValue ?? 10
                let step = confirmations.step("unlock:\(id)", tag: "\((shown["lockVersion"] as? NSNumber)?.intValue ?? 0)", count: count,
                                              confirm: args["confirm"] as? Bool == true, now: now) {
                    var outcome = WebStoreDocument.LockOutcome.done
                    var version = 0
                    if let code = applyCode(store, { document in
                        outcome = try document.unlockCheck(id: id, pin: string(args, "pin"), now: now)
                        version = document.checkedLockVersion ?? 0
                    }) { return ("", code) }
                    return outcome == .done ? ("\(version)", nil) : ("", outcome.code)
                }
                switch step {
                case .refused(let code): return refuse(code)
                case .pending(let left): return pending(left, ["unlocked": false])
                case .done(let tag):
                    var outcome = WebStoreDocument.LockOutcome.done
                    if let failure = apply(store, { outcome = try $0.unlockGroup(id: id, lockVersion: Int(tag) ?? -1, now: now) }) { return failure }
                    guard outcome == .done else { return refuse(outcome.code) }
                    return .ok(jsonText(["unlocked": true, "group": store.load().publicGroup(id: id) ?? [:]]))
                }
            },

            MCPTool(
                name: "run_custom_rule",
                description: "Run a custom group's rule, as the editor's Run does: the source becomes the group's rule and keeps its memory (v.state); the group is enabled. A rule that doesn't load changes nothing — the one running keeps running — and the answer says why (ran: false, error). Omit source to run the group's current rule text. Refused when the group is frozen. Mac Vault's rules control apps only. Write the source to this reference:\n" + ruleReference("mac"),
                inputSchema: [
                    "type": "object",
                    "properties": ["id": ["type": "string", "description": "The custom group's id."], "source": ["type": "string", "description": "The rule: (on, v) => { … }"]],
                    "required": ["id"],
                ]
            ) { args in
                guard let id = string(args, "id"), let shown = store.load().publicGroup(id: id),
                      shown["groupType"] as? String == "custom" else { return refuse("group-not-found") }
                guard let run = runRule else { return refuse("rules-not-running") }
                let source = args["source"] as? String ?? (store.load().group(id: id)?["blockingRulesText"] as? String ?? "")
                let result = run(id, source)
                if let code = result["error"] as? String, ["group-not-found", "group-locked", "rules-not-running"].contains(code) { return refuse(code) }
                return .ok(jsonText(["ran": result["ok"] as? Bool == true, "handlers": result["handlers"] ?? 0, "error": result["error"] ?? NSNull()]))
            },

            MCPTool(
                name: "snooze_group",
                description: "Snooze a group, as the editor's Snooze does: its saved snooze length, delay and cooldown; the group's own confirmations (call again with confirm: true every 5 s until confirmationsLeft is 0). Refused when the group doesn't allow snoozing or a snooze (or its cooldown) is running. A frozen group can be snoozed. A custom group's snooze is its rule's: this sends the rule its \"snooze\" event, as the editor's button does (when it allows snoozing).",
                inputSchema: [
                    "type": "object",
                    "properties": ["id": ["type": "string", "description": "The group id."], "confirm": ["type": "boolean"]],
                    "required": ["id"],
                ]
            ) { args in
                guard let id = string(args, "id"), let shown = store.load().publicGroup(id: id) else { return refuse("group-not-found") }
                if shown["groupType"] as? String == "custom" {
                    guard shown["allowSnooze"] as? Bool != false else { return refuse("snooze-disabled") }
                    guard let press = snoozePress else { return refuse("rules-not-running") }
                    press(id)
                    return .ok(jsonText(["snoozePressed": true]))
                }
                let now = clock()
                let plan: (confirmations: Int, refusal: String?)
                do { plan = try store.load().snoozePlan(id: id, now: now) } catch { return refuse(code(error)) }
                if let refusal = plan.refusal { return refuse(refusal) }
                let step = confirmations.step("snooze:\(id)", tag: "snooze", count: plan.confirmations,
                                              confirm: args["confirm"] as? Bool == true, now: now) { ("snooze", nil) }
                switch step {
                case .refused(let code): return refuse(code)
                case .pending(let left): return pending(left, ["snoozed": false])
                case .done:
                    var outcome = WebStoreDocument.LockOutcome.done
                    if let failure = apply(store, { outcome = try $0.startSnooze(id: id, now: clock()) }) { return failure }
                    guard outcome == .done else { return refuse(outcome.code) }
                    return .ok(jsonText(["snoozed": true, "snooze": store.load().snooze(id: id) ?? [:]]))
                }
            },

            MCPTool(
                name: "end_snooze",
                description: "End a group's running (or scheduled) snooze early, as the editor's End Snooze does. Linked devices end it too. Returns the ended snooze.",
                inputSchema: objectSchema([("id", "string", "The group id.")], required: ["id"])
            ) { args in
                guard let id = string(args, "id") else { return refuse("group-not-found") }
                var outcome = WebStoreDocument.LockOutcome.done
                if let failure = apply(store, { outcome = try $0.endSnooze(id: id, now: clock()) }) { return failure }
                guard outcome == .done else { return refuse(outcome.code) }
                return .ok(jsonText(["ended": true, "snooze": store.load().snooze(id: id) ?? [:]]))
            },

            MCPTool(
                name: "move_group",
                description: "Move a group to a position in the group list (0 = top), as dragging it in the editor does. The first blocking group from the top decides. A frozen group cannot be moved. The order is this device's own. Returns the new order (ids).",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "id": ["type": "string", "description": "The group id."],
                        "index": ["type": "integer", "description": "The new position, 0-based."],
                    ],
                    "required": ["id", "index"],
                ]
            ) { args in
                guard let id = string(args, "id") else { return refuse("group-not-found") }
                guard let index = (args["index"] as? NSNumber)?.intValue else { return refuse("invalid-index") }
                if let failure = apply(store, { try $0.moveGroup(id: id, to: index) }) { return failure }
                return .ok(jsonText(["order": store.load().groupIDs]))
            },

            MCPTool(
                name: "set_lock_gates",
                description: "Set the freeze gates of an unfrozen group, as the editor's guardian settings do: waitHours (0 or blank = no wait, at most 72) and/or pin (6 digits, where none is set); clearPin: true removes the PIN (pass the current pin). Refused on a frozen group (make it stricter with lock_group). Returns the group.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "id": ["type": "string", "description": "The group id."],
                        "waitHours": ["type": "number"], "pin": ["type": "string"], "clearPin": ["type": "boolean"],
                    ],
                    "required": ["id"],
                ]
            ) { args in
                guard let id = string(args, "id") else { return refuse("group-not-found") }
                var outcome = WebStoreDocument.LockOutcome.done
                if let failure = apply(store, { outcome = try $0.setLockGates(id: id, waitHours: args["waitHours"],
                                                                               pin: string(args, "pin"), clearPin: args["clearPin"] as? Bool == true, now: clock()) }) { return failure }
                return outcome == .done ? group(args, "group") : refuse(outcome.code)
            },

            MCPTool(
                name: "delete_all_groups",
                description: "Delete every group, as the editor's Delete all does: refused while any frozen group's wait still holds; pins lists the PIN of each distinct PIN-protected frozen group (asked once, when the confirmation starts); with any frozen group it ends with the confirmation (call again with confirm: true every 5 s until confirmationsLeft is 0). The plan is taken again on every call: a freeze or PIN that arrives meanwhile stops or restarts it.",
                inputSchema: [
                    "type": "object",
                    "properties": ["pins": ["type": "array", "items": ["type": "string"]], "confirm": ["type": "boolean"]],
                ]
            ) { args in
                let now = clock()
                let plan: WebStoreDocument.DeleteAllPlan
                switch store.load().deleteAllPlan(now: now) {
                case .failure(let outcome): return refuse(outcome.code)
                case .success(let taken): plan = taken
                }
                let pins = (args["pins"] as? [Any] ?? []).map { "\($0)" }
                let step = confirmations.step("delete-all", tag: plan.tag, count: plan.confirmations,
                                              confirm: args["confirm"] as? Bool == true, now: now) {
                    var outcome = WebStoreDocument.LockOutcome.done
                    if let code = applyCode(store, { outcome = $0.checkDeleteAllPins(plan, pins: pins, now: now) }) { return (plan.tag, code) }
                    return (plan.tag, outcome == .done ? nil : outcome.code)
                }
                switch step {
                case .refused(let code): return refuse(code)
                case .pending(let left): return pending(left, ["deleted": false])
                case .done:
                    var count = 0
                    if let failure = apply(store, { count = $0.groupCount; $0.deleteAll() }) { return failure }
                    return .ok(jsonText(["deleted": count]))
                }
            },

            MCPTool(
                name: "delete_group",
                description: "Delete a block group by id. A frozen group is refused.",
                inputSchema: objectSchema([("id", "string", "The group id.")], required: ["id"])
            ) { args in
                guard let id = string(args, "id") else { return refuse("group-not-found") }
                return apply(store) { try $0.deleteGroup(id: id) } ?? .ok(jsonText(["deleted": id]))
            },
        ]
    }

    /// A custom group's snooze press, supplied by Mac Vault's rule engine.
    nonisolated(unsafe) public static var snoozePress: ((String) -> Void)?
    /// A custom group's Run (id, source) → the load result, supplied by Mac Vault's rule engine.
    nonisolated(unsafe) public static var runRule: ((String, String) -> [String: Any])?

    /// The rule reference the editor's "Let AI Code" gives an AI, for an engine.
    public static func ruleReference(_ engine: String) -> String {
        GroupActionsRuntime.shared.call("reference", [engine], module: "RuleCore") as? String ?? ""
    }

    // MARK: Helpers

    /// A tool's confirmation, as the editor's modal (the browser worker's
    /// cbToolConfirmation): a call with no pending confirmation for the same
    /// tag asks — `ask` runs the gates (a PIN…) and names the tag the
    /// confirmation is for — then each call with confirm: true at least 5 s
    /// after the previous counts a step. It expires after 5 minutes; a changed
    /// tag (the freeze changed, a new PIN) starts it over.
    final class Confirmations: @unchecked Sendable {
        enum Step { case done(tag: String), pending(left: Int), refused(String) }
        private struct Pending { let tag: String; let state: [String: Any]; let askedAt: Date }
        private static let lifetime: TimeInterval = 300
        private let lock = NSLock()
        private var requests: [String: Pending] = [:]

        func step(_ key: String, tag: String, count: Int, confirm: Bool, now: Date,
                  ask: () -> (tag: String, refusal: String?)) -> Step {
            let nowMs = (now.timeIntervalSince1970 * 1000).rounded()
            let runtime = GroupActionsRuntime.shared
            lock.lock()
            let current = requests[key].flatMap { $0.tag == tag && now.timeIntervalSince($0.askedAt) < Self.lifetime ? $0 : nil }
            lock.unlock()
            guard confirm, let current else {
                let asked = ask()
                if let refusal = asked.refusal { return .refused(refusal) }
                guard count > 0 else { save(key, nil); return .done(tag: asked.tag) }
                let state = runtime.call("confirmStart", [nowMs, count]) as? [String: Any] ?? [:]
                save(key, Pending(tag: asked.tag, state: state, askedAt: now))
                return .pending(left: count)
            }
            let result = runtime.call("confirmStep", [current.state, nowMs]) as? [String: Any] ?? [:]
            let waitMs = (result["waitMs"] as? NSNumber)?.doubleValue ?? 0
            if waitMs > 0 { return .refused("confirm-wait:\(Int((waitMs / 1000).rounded(.up)))") }
            if result["done"] as? Bool == true { save(key, nil); return .done(tag: current.tag) }
            let state = result["state"] as? [String: Any] ?? [:]
            save(key, Pending(tag: current.tag, state: state, askedAt: current.askedAt))
            return .pending(left: (state["left"] as? NSNumber)?.intValue ?? 0)
        }

        private func save(_ key: String, _ request: Pending?) {
            lock.lock(); requests[key] = request; lock.unlock()
        }
    }

    private static let confirmNext = "call again with confirm: true every 5 s until confirmationsLeft is 0 (within 5 minutes)"

    private static func pending(_ left: Int, _ extra: [String: Any]) -> MCPToolResult {
        .ok(jsonText(extra.merging(["confirmationsLeft": left, "confirmAfterSeconds": 5, "next": confirmNext]) { $1 }))
    }

    private static func refuse(_ code: String) -> MCPToolResult {
        .failure(ToolRefusals.explain(code))
    }

    /// Applies a mutation: nil on success, else the refusal code.
    private static func applyCode(_ store: GroupStore, _ body: (inout WebStoreDocument) throws -> Void) -> String? {
        do {
            try store.mutate(body)
            return nil
        } catch {
            return code(error)
        }
    }

    /// Applies a mutation: nil on success, else the refusal result.
    private static func apply(_ store: GroupStore, _ body: (inout WebStoreDocument) throws -> Void) -> MCPToolResult? {
        applyCode(store, body).map(refuse)
    }

    private static func string(_ args: [String: Any], _ key: String) -> String? {
        guard let value = args[key] as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func code(_ error: Error) -> String {
        guard let error = error as? GroupStoreError else { return (error as NSError).localizedDescription }
        switch error {
        case .groupNotFound: return "group-not-found"
        case .invalidInput(let code): return code
        case .groupLocked: return "group-locked"
        case .duplicateName: return "duplicate-name"
        case .notLocked: return "not-locked"
        }
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
