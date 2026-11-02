#if os(macOS)
import Foundation
import MacBlockerCore
import MacBlockerWebUI
import VaultClassifierCore
import VaultClassifierApp

struct RuleAIContext: Equatable {
    var dailyRequestLimit: Int?
    var members: [String]
    var revision: String
}

/// Shared by native rules and authenticated browser peers. Each call retains
/// its exact group/configuration context; a late response cannot select a host.
@MainActor
final class RuleAIService {
    static let shared = RuleAIService(
        usage: RuleAIUsage(url: BlockerWebStore().fileURL.deletingLastPathComponent().appendingPathComponent("rule-ai-usage.json")),
        context: { ConnectionHub.shared.ruleAIContext(program: $0, groupID: $1) },
        models: { VaultClassifierPage.shared.ruleAIModels() },
        validate: { VaultClassifierPage.shared.validateRuleAI($0) },
        generate: { try await VaultClassifierPage.shared.generateForRule(configuration: $0, input: $1) },
        conversations: RuleAIConversations(root: RuleAIConversations.defaultRoot))
    private let usage: RuleAIUsage
    private let context: (String, String) -> RuleAIContext?
    private let models: () -> [[String: Any]]
    private let validate: (RuleAIConfiguration) -> Bool
    private let generate: (RuleAIConfiguration, RuleAIInput) async throws -> RuleAIReply
    private let conversations: RuleAIConversations
    private struct ActiveCall {
        let program: String
        let groupID: String
        let context: RuleAIContext
        let task: Task<(RuleAIReply, [String]), Error>
    }
    private var activeCalls: [UUID: ActiveCall] = [:]
    private var conversationTails: [String: (UUID, Task<(RuleAIReply, [String]), Error>)] = [:]
    private var stopped = false
    init(usage: RuleAIUsage, context: @escaping (String, String) -> RuleAIContext?, models: @escaping () -> [[String: Any]], validate: @escaping (RuleAIConfiguration) -> Bool, generate: @escaping (RuleAIConfiguration, RuleAIInput) async throws -> RuleAIReply, conversations: RuleAIConversations = RuleAIConversations(root: FileManager.default.temporaryDirectory.appendingPathComponent("vault-rule-ai-test-conversations", isDirectory: true))) {
        self.usage = usage; self.context = context; self.models = models; self.validate = validate; self.generate = generate; self.conversations = conversations
    }
    func modelOptions() -> [String: Any] { ["ok": !stopped, "models": stopped ? [] : models()] }
    func shutdown() { stopped = true; activeCalls.values.forEach { $0.task.cancel() } }
    /// A disconnected peer or edited group has no destination for its old
    /// answer. Cancel its provider work rather than occupying a slot forever.
    func cancelInvalidRequests() {
        for call in activeCalls.values where context(call.program, call.groupID) != call.context {
            call.task.cancel()
        }
    }
    func request(program: String, groupID: String, payload: String) async -> [String: Any] {
        do {
            guard !stopped else { throw RuleAIError.unavailable }
            if let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
               object["op"] as? String == "delete" {
                guard Set(object.keys) == Set(["op", "conversation"]),
                      let name = object["conversation"] as? String,
                      !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      name.utf8.count <= 128,
                      !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                      context(program, groupID) != nil else { throw RuleAIError.invalidInput }
                guard conversationTails[name] == nil else { return ["ok": false, "error": "ai-conversation-busy", "text": NSNull(), "citations": []] }
                try await conversations.delete(name: name)
                return ["ok": true, "error": "", "text": NSNull(), "citations": []]
            }
            let input = try RuleAIInput(payload: payload)
            guard let captured = context(program, groupID),
                  let choice = models().first(where: { $0["value"] as? String == input.model &&
                      ($0["efforts"] as? [String])?.contains(input.reasoningEffort.rawValue) == true }) else { throw RuleAIError.invalidConfiguration }
            let configuration = RuleAIConfiguration(providerModel: input.model,
                accountID: choice["accountID"] as? String ?? "", reasoningEffort: input.reasoningEffort,
                dailyRequestLimit: captured.dailyRequestLimit)
            guard validate(configuration) else { throw RuleAIError.invalidConfiguration }
            let id = UUID(), generate = self.generate
            let key = input.conversation
            let previous = key.flatMap { conversationTails[$0]?.1 }
            let work = Task { @MainActor [self] in
                if let previous { _ = try? await previous.value }
                try Task.checkCancellation()
                guard context(program, groupID) == captured else { throw RuleAIError.unavailable }
                var requestInput = input
                var preservedNames: [String] = []
                if let name = input.conversation {
                    let prepared = try await conversations.prepare(members: captured.members, name: name)
                    requestInput.historyText = prepared.history
                    preservedNames = prepared.preservedNames
                }
                try usage.reserve(members: captured.members, limit: captured.dailyRequestLimit)
                let reply = try await generate(configuration, requestInput)
                guard context(program, groupID) == captured else { throw RuleAIError.unavailable }
                if let name = input.conversation {
                    try await conversations.append(members: captured.members, name: name, model: input.model,
                        user: input.currentPrompt, assistant: reply.text)
                }
                return (reply, preservedNames)
            }
            if let key { conversationTails[key] = (id, work) }
            activeCalls[id] = ActiveCall(program: program, groupID: groupID, context: captured, task: work)
            defer {
                activeCalls[id] = nil
                if let key, conversationTails[key]?.0 == id { conversationTails[key] = nil }
            }
            let (reply, preservedNames) = try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
            guard !stopped, !Task.isCancelled, context(program, groupID) == captured else { throw RuleAIError.unavailable }
            let data = try JSONEncoder().encode(reply)
            var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            object["ok"] = true; object["error"] = ""
            if !preservedNames.isEmpty { object["preservedConversations"] = preservedNames }
            return object
        } catch {
            // Stable bounded errors; provider payloads/keys never enter rule logs.
            let code = (error as? RuleAIError)?.rawValue ?? (error is CancellationError ? RuleAIError.unavailable.rawValue : RuleAIError.failed.rawValue)
            return ["ok": false, "text": NSNull(), "citations": [], "error": code]
        }
    }
}
#endif
