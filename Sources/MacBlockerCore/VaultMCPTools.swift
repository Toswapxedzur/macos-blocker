#if os(macOS)
import Foundation

/// The Vault MCP tool surface. These are bounded, named operations over the block
/// groups — never arbitrary control — each wrapping the already-tested
/// `GroupStore`, so the MCP server, the WebView bridge, and any future caller
/// share one implementation of every mutation.
public enum VaultMCPTools {
    public static func groupTools(store: GroupStore = GroupStore()) -> [MCPTool] {
        [
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
                description: "Set a group's blocking mode: 'instant', 'after-minutes', or 'timer'.",
                inputSchema: objectSchema([
                    ("id", "string", "The group id."),
                    ("mode", "string", "One of: instant, after-minutes, timer."),
                ], required: ["id", "mode"])
            ) { args in
                guard let id = string(args, "id") else { return .failure("Missing 'id'.") }
                guard let raw = string(args, "mode"), let mode = BlockingMode(rawValue: raw) else {
                    return .failure("Invalid 'mode'. Use instant, after-minutes, or timer.")
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
