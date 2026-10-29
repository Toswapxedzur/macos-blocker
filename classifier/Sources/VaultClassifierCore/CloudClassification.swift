import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public enum ClassificationProvider: String, Codable, CaseIterable, Sendable {
    case chatGPT, apiKey
}

public enum ClassificationReasoningEffort: String, Codable, CaseIterable, Sendable {
    case providerDefault = "default", low, medium, high
}

/// Only public group selection is persisted. Search is always offered; the model
/// decides whether to call it. Old search switches are ignored when decoding.
public struct ChatGPTClassificationSettings: Codable, Equatable, Sendable {
    public var accountID: String
    public var model: String
    public var reasoningEffort: ClassificationReasoningEffort
    public init(accountID: String = "", model: String = "", reasoningEffort: ClassificationReasoningEffort = .medium) {
        self.accountID = accountID; self.model = model; self.reasoningEffort = reasoningEffort
    }
    private enum CodingKeys: String, CodingKey { case accountID, model, reasoningEffort }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(accountID: try c.decode(String.self, forKey: .accountID), model: try c.decode(String.self, forKey: .model),
            reasoningEffort: try c.decodeIfPresent(ClassificationReasoningEffort.self, forKey: .reasoningEffort) ?? .low)
    }
    public func validate() throws {
        guard !accountID.isEmpty, accountID.count <= 256, !model.isEmpty, model.count <= 512 else { throw CloudClassificationError.notConfigured }
    }
}

public struct APIKeyClassificationSettings: Codable, Equatable, Sendable {
    public var profileID: String
    public var model: String
    public var reasoningEffort: ClassificationReasoningEffort
    public init(profileID: String = "", model: String = "", reasoningEffort: ClassificationReasoningEffort = .medium) {
        self.profileID = profileID; self.model = model; self.reasoningEffort = reasoningEffort
    }
    private enum CodingKeys: String, CodingKey { case profileID, model, reasoningEffort }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(profileID: try c.decode(String.self, forKey: .profileID), model: try c.decode(String.self, forKey: .model),
            reasoningEffort: try c.decodeIfPresent(ClassificationReasoningEffort.self, forKey: .reasoningEffort) ?? .providerDefault)
    }
    public func validate() throws {
        guard !profileID.isEmpty, !model.isEmpty, model.count <= 256 else { throw CloudClassificationError.notConfigured }
    }
}

/// Conservative reasoning choices for the currently documented model families.
/// Unknown models retain provider defaults; unsupported choices are never dropped.
public enum ClassificationModelPolicy {
    public static func searchCompatible(provider: APIKeyProviderType?, model: String) -> Bool {
        let m = model.lowercased()
        if ["image", "tts", "transcrib", "audio", "realtime", "embedding", "dall-e"].contains(where: m.contains) { return false }
        if provider == .gemini { return m.hasPrefix("gemini-3") || m.hasPrefix("gemini-4") }
        if provider == .xAI { return !m.hasPrefix("grok-3") }
        return !m.contains("nano") && !m.contains("search-api")
    }
    public static func efforts(provider: APIKeyProviderType?, model: String) -> [ClassificationReasoningEffort] {
        let m = model.lowercased(), common: [ClassificationReasoningEffort] = [.providerDefault, .low, .medium, .high]
        if provider == .gemini {
            if m.hasPrefix("gemini-3-pro") { return [.providerDefault, .low, .high] }
            return ["gemini-3.1-pro", "gemini-3.1-flash-lite", "gemini-3-flash", "gemini-3.5-flash-lite", "gemini-3.6-flash", "gemini-3.8-flash", "gemini-4-argon"].contains(where: m.hasPrefix) && searchCompatible(provider: provider, model: m) ? common : [.providerDefault]
        }
        if provider == .xAI { return ["grok-4.5", "grok-4.6", "grok-4.7"].contains(where: m.hasPrefix) ? common : [.providerDefault] }
        if m.contains("-pro") { return [.providerDefault, .high] }
        return ["gpt-5", "gpt-6", "o3", "o4"].contains(where: m.hasPrefix) ? common : [.providerDefault]
    }
    public static func validate(provider: APIKeyProviderType?, model: String, effort: ClassificationReasoningEffort) throws {
        guard searchCompatible(provider: provider, model: model) else { throw CloudClassificationError.searchUnavailable }
        guard efforts(provider: provider, model: model).contains(effort) else { throw CloudClassificationError.reasoningUnavailable }
    }
}

public enum CloudClassificationError: Error, LocalizedError, Equatable, Sendable {
    case notConfigured, signInRequired, usageLimit, invalidOutput, searchUnavailable, reasoningUnavailable
    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "Choose a connection and model for tagging."
        case .signInRequired: return "Connect the selected ChatGPT account again."
        case .usageLimit: return "The classification request limit has been reached. Retry later or change the limit."
        case .searchUnavailable: return "This model cannot combine web search with structured tagging. Choose a model that supports search with structured tagging."
        case .reasoningUnavailable: return "This model does not support the selected reasoning effort. Choose another effort or model."
        case .invalidOutput: return "The provider did not return valid classification tags. Retry the request."
        }
    }
}

public protocol CloudClassificationEngineResolving: Sendable {
    func resolveCloudEngine(for type: ClassifierTypeAsset) async throws -> any ClassificationEngine
}

extension ClassifierTypeAsset {
    /// Cloud confidence is model-reported, rather than local token odds. The
    /// explicit contract/version prevents results from being mistaken for local
    /// calibration, or reused across account/model/rule/search changes.
    public var cloudModelVersion: String {
        if classificationProvider == .apiKey {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let data = (try? encoder.encode(APIKeyCurrency(connection: apiKey, rules: tagging.houseRules, minimumConfidence: tagging.minimumConfidence))) ?? Data()
            return "api-key/certainty-v1/" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(CloudCurrency(
            account: chatGPT.accountID, model: chatGPT.model,
            effort: chatGPT.reasoningEffort, rules: tagging.houseRules,
            minimumConfidence: tagging.minimumConfidence))) ?? Data()
        return "chatgpt/certainty-v1/" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public enum CloudClassificationCurrency {
    public static func input(title: String, summary: String?, text: String?, creatorID: String, creatorName: String?) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode([title, summary ?? "", text ?? "", creatorID, creatorName ?? ""])) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private struct CloudCurrency: Encodable {
    let account: String; let model: String; let effort: ClassificationReasoningEffort; let rules: String
    let minimumConfidence: Int
}

private struct APIKeyCurrency: Encodable {
    let connection: APIKeyClassificationSettings; let rules: String
    let minimumConfidence: Int
}
