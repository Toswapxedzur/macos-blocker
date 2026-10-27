import Foundation
import VaultClassifierCore
import VaultClassifierResearch

@MainActor
extension VaultClassifierViewModel {
    /// A separate, deliberately credential-free projection for rule editors.
    func ruleAIModels() -> [[String: Any]] {
        var choices: [[String: Any]] = []
        func append(_ value: String, _ account: String, _ label: String, _ provider: APIKeyProviderType?, _ model: String) {
            guard ClassificationModelPolicy.searchCompatible(provider: provider, model: model) else { return }
            choices.append(["value": value, "accountID": account, "label": label, "efforts": ClassificationModelPolicy.efforts(provider: provider, model: model).map(\.rawValue)])
        }
        if chatGPTStatus.connected && chatGPTStatus.planUsageEnabled {
            for model in chatGPTStatus.models { append("chatgpt:" + model.identifier, chatGPTStatus.accountID, "ChatGPT subscription · " + model.displayName, nil, model.identifier) }
        }
        for profile in localState?.workspaceCatalog.providerProfiles ?? [] where APIKeyClassificationClient.supports(profile.type) && profile.credential?.isEmpty == false {
            for model in providerModelCatalogs[profile.id] ?? [] where model.supportsTools != false && model.supportsNativeWebSearch != false { append("api:" + profile.id + ":" + model.identifier, "", profile.name + " · " + model.identifier, profile.type, model.identifier) }
        }
        return Array(choices.prefix(512))
    }
    func validateRuleAI(_ configuration: RuleAIConfiguration) -> Bool {
        guard (try? configuration.validate()) != nil else { return false }
        return ruleAIModels().contains { choice in
            choice["value"] as? String == configuration.providerModel && choice["accountID"] as? String == configuration.accountID && (choice["efforts"] as? [String] ?? []).contains(configuration.reasoningEffort.rawValue)
        }
    }
    func generateForRule(configuration: RuleAIConfiguration, input: RuleAIInput) async throws -> RuleAIReply {
        guard !isShuttingDown, validateRuleAI(configuration) else { throw RuleAIError.invalidConfiguration }
        if configuration.providerModel.hasPrefix("chatgpt:") {
            guard let client = chatGPTClient else { throw RuleAIError.unavailable }
            return try await client.generateForRule(configuration: .init(accountID: configuration.accountID, model: String(configuration.providerModel.dropFirst(8)), reasoningEffort: configuration.reasoningEffort), input: input)
        }
        let parts = configuration.providerModel.dropFirst(4).split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let client = apiKeyClassificationClient else { throw RuleAIError.invalidConfiguration }
        return try await client.generateForRule(profileID: parts[0], model: parts[1], effort: configuration.reasoningEffort, input: input)
    }
}
