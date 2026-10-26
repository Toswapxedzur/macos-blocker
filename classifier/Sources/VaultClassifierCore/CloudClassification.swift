import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public enum ClassificationProvider: String, Codable, CaseIterable, Sendable {
    case chatGPT, apiKey
}

/// Group selection stores public IDs and model choices. Subscription credentials
/// remain separate from workspace state, backups, snapshots and hub messages.
public struct ChatGPTClassificationSettings: Codable, Equatable, Sendable {
    public var accountID: String
    public var model: String
    public var searchEnabled: Bool
    public init(accountID: String = "", model: String = "", searchEnabled: Bool = false) {
        self.accountID = accountID; self.model = model
        self.searchEnabled = searchEnabled
    }
    public func validate() throws {
        guard !accountID.isEmpty, accountID.count <= 256, !model.isEmpty, model.count <= 512 else {
            throw CloudClassificationError.notConfigured
        }
    }
}

public struct APIKeyClassificationSettings: Codable, Equatable, Sendable {
    public var profileID: String
    public var model: String
    public var searchEnabled: Bool
    public init(profileID: String = "", model: String = "", searchEnabled: Bool = false) {
        self.profileID = profileID; self.model = model; self.searchEnabled = searchEnabled
    }
    public func validate() throws {
        guard !profileID.isEmpty, !model.isEmpty, model.count <= 256 else { throw CloudClassificationError.notConfigured }
    }
}

public enum CloudClassificationError: Error, LocalizedError, Equatable, Sendable {
    case notConfigured, signInRequired, usageLimit, invalidOutput, searchUnavailable
    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "Choose a connection and model for tagging."
        case .signInRequired: return "Connect the selected ChatGPT account again."
        case .usageLimit: return "The classification request limit has been reached. Retry later or change the limit."
        case .searchUnavailable: return "This model cannot combine web search with structured tagging. Turn off web search or choose another model."
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
            let data = (try? encoder.encode(APIKeyCurrency(connection: apiKey, rules: tagging.houseRules, strictness: tagging.strictness, bounds: tagging.tagBounds))) ?? Data()
            return "api-key/self-reported-v1/" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(CloudCurrency(
            account: chatGPT.accountID, model: chatGPT.model,
            search: chatGPT.searchEnabled, rules: tagging.houseRules,
            strictness: tagging.strictness, bounds: tagging.tagBounds))) ?? Data()
        return "chatgpt/self-reported-v1/" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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
    let account: String; let model: String; let search: Bool; let rules: String
    let strictness: StrictnessDial; let bounds: TagBounds
}

private struct APIKeyCurrency: Encodable {
    let connection: APIKeyClassificationSettings; let rules: String
    let strictness: StrictnessDial; let bounds: TagBounds
}
