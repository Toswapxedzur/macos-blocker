#if os(macOS)
import Foundation
import MacBlockerCore
import MacBlockerWebUI
import VaultClassifierCore
import VaultClassifierApp

struct RuleAIContext: Equatable {
    var configuration: RuleAIConfiguration
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
        generate: { try await VaultClassifierPage.shared.generateForRule(configuration: $0, input: $1) })
    private let usage: RuleAIUsage
    private let context: (String, String) -> RuleAIContext?
    private let models: () -> [[String: Any]]
    private let validate: (RuleAIConfiguration) -> Bool
    private let generate: (RuleAIConfiguration, RuleAIInput) async throws -> RuleAIReply
    private let timeoutNanoseconds: UInt64
    private var inFlight = 0
    private var stopped = false
    init(usage: RuleAIUsage, context: @escaping (String, String) -> RuleAIContext?, models: @escaping () -> [[String: Any]], validate: @escaping (RuleAIConfiguration) -> Bool, generate: @escaping (RuleAIConfiguration, RuleAIInput) async throws -> RuleAIReply, timeoutNanoseconds: UInt64 = 70_000_000_000) {
        self.usage = usage; self.context = context; self.models = models; self.validate = validate; self.generate = generate; self.timeoutNanoseconds = timeoutNanoseconds
    }
    func modelOptions() -> [String: Any] { ["ok": !stopped, "models": stopped ? [] : models()] }
    func shutdown() { stopped = true }
    func request(program: String, groupID: String, payload: String) async -> [String: Any] {
        do {
            guard !stopped else { throw RuleAIError.unavailable }
            guard inFlight < 2 else { throw RuleAIError.busy }
            let input = try RuleAIInput(payload: payload)
            guard let captured = context(program, groupID), validate(captured.configuration) else { throw RuleAIError.invalidConfiguration }
            try usage.reserve(members: captured.members, limit: captured.configuration.dailyRequestLimit)
            inFlight += 1; defer { inFlight -= 1 }
            let generate = self.generate, timeout = timeoutNanoseconds
            let reply = try await withThrowingTaskGroup(of: RuleAIReply.self) { group in
                group.addTask { @MainActor in try await generate(captured.configuration, input) }
                group.addTask { try await Task.sleep(nanoseconds: timeout); throw RuleAIError.timeout }
                defer { group.cancelAll() }
                guard let result = try await group.next() else { throw RuleAIError.unavailable }
                return result
            }
            guard !stopped, !Task.isCancelled, context(program, groupID) == captured else { throw RuleAIError.unavailable }
            let data = try JSONEncoder().encode(reply)
            var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            object["ok"] = true; object["error"] = ""; return object
        } catch {
            // Stable bounded errors; provider payloads/keys never enter rule logs.
            let code = (error as? RuleAIError)?.rawValue ?? (error is CancellationError ? RuleAIError.unavailable.rawValue : RuleAIError.failed.rawValue)
            return ["ok": false, "text": NSNull(), "citations": [], "error": code]
        }
    }
}
#endif
