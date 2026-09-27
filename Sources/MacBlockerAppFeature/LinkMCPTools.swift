#if os(macOS)
import Foundation
import MacBlockerCore

/// MCP tools for links (owner 2026-09-27: links are made and removed by the
/// user — the Link / Unlink buttons — never by names; a tool does exactly what
/// the user can). A group links with a group of another program (macapp = Mac
/// Vault, chrome, edge, …); the link shares the whole definition and the name.
/// On unlink both keep the settings and each keeps its own program's lines.
enum LinkMCPTools {
    static func tools(hub: ConnectionHub = .shared) -> [MCPTool] {
        [
            MCPTool(
                name: "list_links",
                description: "The current links (each with its shared name and its member groups: program + group id) and every connected program's groups (program → [{id, name, frozen}]) that a group can be linked with. Mac Vault's own program is \"macapp\".",
                inputSchema: ["type": "object", "properties": [:]]
            ) { _ in
                .ok(hub.clustersJSON())
            },
            MCPTool(
                name: "link_groups",
                description: "Link a group with a group of another program, as the editor's Link button does: the first group's settings and name win the first merge, the lines of both are joined. Refused while either group or the link is locked, for a group already in another link, and for a second group of one program.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "program": ["type": "string", "description": "The first group's program (macapp, chrome, …)."],
                        "groupId": ["type": "string", "description": "The first group's id."],
                        "targetProgram": ["type": "string", "description": "The other group's program."],
                        "targetGroupId": ["type": "string", "description": "The other group's id."],
                    ],
                    "required": ["program", "groupId", "targetProgram", "targetGroupId"],
                ]
            ) { args in
                let refusal = hub.linkGroups(program: string(args, "program"), groupId: string(args, "groupId"),
                                             targetProgram: string(args, "targetProgram"), targetGroupId: string(args, "targetGroupId"))
                return refusal.map { .failure("Refused: \($0).") } ?? .ok("Linked.")
            },
            MCPTool(
                name: "unlink_group",
                description: "Take a group out of its link, as the editor's Unlink button does: both keep the shared settings; each keeps only its own program's lines (a browser keeps websites and platforms, Mac Vault keeps apps). Refused while the link is locked.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "program": ["type": "string", "description": "The group's program (macapp, chrome, …)."],
                        "groupId": ["type": "string", "description": "The group's id."],
                    ],
                    "required": ["program", "groupId"],
                ]
            ) { args in
                let refusal = hub.unlinkGroup(program: string(args, "program"), groupId: string(args, "groupId"))
                return refusal.map { .failure("Refused: \($0).") } ?? .ok("Unlinked.")
            },
        ]
    }

    private static func string(_ args: [String: Any], _ key: String) -> String {
        (args[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
#endif
