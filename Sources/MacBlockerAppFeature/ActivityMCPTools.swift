#if os(macOS)
import Foundation
import MacBlockerCore
import MacBlockerWebUI

/// MCP tools for Activity's app groups (owner 2026-09-29): the same as the
/// Activity page's Groups editor. A group holds apps and websites and can be
/// viewed in Details; a merge group also stands in for its members everywhere,
/// so an item can be in many groups but in at most one merge group.
enum ActivityMCPTools {
    static func tools(store: ActivityStore) -> [MCPTool] {
        [
            MCPTool(
                name: "list_activity_groups",
                description: "Activity's app groups ({id, name, merge, members}) and the apps and websites seen in the last 180 days that a group can hold ({id, label, seconds}, most used first). Member ids are \"app|<bundle id>\" or \"web|<domain>\".",
                inputSchema: ["type": "object", "properties": [:]]
            ) { _ in
                let groups = store.groups().map { ["id": $0.id, "name": $0.name, "merge": $0.merge, "members": $0.members] as [String: Any] }
                let items = store.knownItems(days: 180).prefix(300).map { ["id": $0.id, "label": $0.label, "seconds": Int($0.seconds)] as [String: Any] }
                return .ok(json(["groups": groups, "items": Array(items)]))
            },
            MCPTool(
                name: "save_activity_group",
                description: "Create or change an Activity app group, as the page's Groups editor does. Omit id to create one. members: \"app|<bundle id>\" / \"web|<domain>\". merge: true makes it stand in for its members everywhere (one row, one colour); a merge group cannot take a member another merge group has unless move is true (it is then taken out of that group).",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "id": ["type": "string", "description": "The group to change; omit to create a group."],
                        "name": ["type": "string"],
                        "merge": ["type": "boolean"],
                        "members": ["type": "array", "items": ["type": "string"]],
                        "move": ["type": "boolean", "description": "Take members out of their other merge group."],
                    ],
                    "required": ["name", "members"],
                ]
            ) { args in
                let group = ActivityGroup(
                    id: (args["id"] as? String) ?? "",
                    name: (args["name"] as? String) ?? "",
                    merge: (args["merge"] as? Bool) ?? false,
                    members: (args["members"] as? [String]) ?? []
                )
                switch store.saveGroup(group, move: (args["move"] as? Bool) ?? false) {
                case .success(let id):
                    refreshPage()
                    return .ok(json(["id": id]))
                case .failure(let refusal):
                    return .failure("Refused: \(refusal.message).")
                }
            },
            MCPTool(
                name: "delete_activity_group",
                description: "Delete an Activity app group (its apps and websites and their history are not touched).",
                inputSchema: [
                    "type": "object",
                    "properties": ["id": ["type": "string"]],
                    "required": ["id"],
                ]
            ) { args in
                guard store.deleteGroup(id: (args["id"] as? String) ?? "") else { return .failure("Refused: no such group.") }
                refreshPage()
                return .ok("Deleted.")
            },
        ]
    }

    private static func refreshPage() {
        DispatchQueue.main.async { MainActor.assumeIsolated { ActivityPage.shared.refresh() } }
    }

    private static func json(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}
#endif
