#if os(macOS)
import Foundation
import MacBlockerCore
import VaultClassifierApp

/// The classifier's MCP tools: the page's snapshot and the page's action
/// dispatcher, exposed 1:1 (owner 2026-09-23). The handlers hop to the main
/// actor because the classifier's model lives there; the closures are
/// injectable so the tools are testable without a live page.
public enum ClassifierMCPTools {
    public struct Bridge {
        public var snapshot: (_ section: String?) -> [String: Any]?
        public var perform: (_ action: String, _ data: [String: Any]) -> ClassifierMCPActionOutcome
        public var catalog: () -> [ClassifierWebActionDescriptor]

        public init(
            snapshot: @escaping (String?) -> [String: Any]?,
            perform: @escaping (String, [String: Any]) -> ClassifierMCPActionOutcome,
            catalog: @escaping () -> [ClassifierWebActionDescriptor]
        ) {
            self.snapshot = snapshot
            self.perform = perform
            self.catalog = catalog
        }

        /// The live page. Every call runs on the main actor synchronously; the
        /// MCP server's queue is never the main queue.
        public static let livePage = Bridge(
            snapshot: { section in onMain { VaultClassifierPage.shared.mcpSnapshot(section: section) } },
            perform: { action, data in onMain { VaultClassifierPage.shared.mcpPerform(action: action, data: data) } },
            catalog: { VaultClassifierPage.mcpActionCatalog }
        )

        private static func onMain<T>(_ body: @MainActor () -> T) -> T {
            if Thread.isMainThread { return MainActor.assumeIsolated(body) }
            return DispatchQueue.main.sync { MainActor.assumeIsolated(body) }
        }
    }

    public static func tools(bridge: Bridge = .livePage) -> [MCPTool] {
        [
            MCPTool(
                name: "classifier_state",
                description: "The Vault Classifier page's state as JSON — the same data the page renders. No section = a compact overview (settings, groups, platforms, counts). section = 'all' for everything, or one of settings, assets, backup, notices, trash, workspace, issue, or 'assets.<key>' (trees, datasets, knowledge, classifierTypes, providerProfiles, providerProtocols, collectionPlatforms, bindings).",
                inputSchema: [
                    "type": "object",
                    "properties": ["section": ["type": "string", "description": "Which part to return; omit for the overview."]],
                ]
            ) { args in
                let section = (args["section"] as? String)
                guard let snapshot = bridge.snapshot(section) else {
                    return .failure("Unknown section '\(section ?? "")'. Use 'all', a top-level section, or 'assets.<key>'.")
                }
                return .ok(jsonText(snapshot))
            },
            MCPTool(
                name: "classifier_action",
                description: "Run one Vault Classifier page action with the page's own validation — exactly what the page's buttons do. 'action' is a name from classifier_actions; 'data' is its key/value payload. The result reports the page's issue text on failure.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "action": ["type": "string", "description": "Action name (see classifier_actions)."],
                        "data": ["type": "object", "description": "The action's data keys (see classifier_actions)."],
                    ],
                    "required": ["action"],
                ]
            ) { args in
                guard let action = args["action"] as? String, !action.isEmpty, action.count <= 64 else {
                    return .failure("Missing 'action'.")
                }
                let data = args["data"] as? [String: Any] ?? [:]
                let outcome = bridge.perform(action, data)
                if let issue = outcome.issue { return .failure("\(action): \(issue)") }
                return .ok(jsonText(["action": action, "ok": true, "rerender": outcome.rerender]))
            },
            MCPTool(
                name: "classifier_actions",
                description: "List every Vault Classifier page action with the data keys it reads and what it does.",
                inputSchema: ["type": "object", "properties": [String: Any]()]
            ) { _ in
                .ok(jsonText(["actions": bridge.catalog().map { ["name": $0.name, "keys": $0.keys, "summary": $0.summary] }]))
            },
        ]
    }

    private static func jsonText(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}
#endif
