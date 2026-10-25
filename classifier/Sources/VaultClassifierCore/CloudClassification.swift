import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public enum ClassificationProvider: String, Codable, CaseIterable, Sendable {
    case local, chatGPT
}

/// Public configuration only. Account credentials never enter classifier state,
/// backups, web snapshots or hub messages.
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

public enum CloudClassificationError: Error, LocalizedError, Equatable, Sendable {
    case notConfigured, signInRequired, usageLimit, invalidOutput
    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "Choose a connected ChatGPT account and model."
        case .signInRequired: return "Connect the selected ChatGPT account again."
        case .usageLimit: return "The classification request limit has been reached. Retry later or change the limit."
        case .invalidOutput: return "ChatGPT did not return valid classification tags. Retry the request."
        }
    }
}

public protocol CloudClassificationEngineResolving: Sendable {
    func resolveCloudEngine(for type: ClassifierTypeAsset) async throws -> any OnDeviceLLM
}

extension ClassifierTypeAsset {
    /// Cloud confidence is model-reported, rather than local token odds. The
    /// explicit contract/version prevents results from being mistaken for local
    /// calibration, or reused across account/model/rule/search changes.
    public var cloudModelVersion: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(CloudCurrency(
            account: chatGPT.accountID, model: chatGPT.model,
            search: chatGPT.searchEnabled, rules: localModel.houseRules,
            strictness: localModel.strictness, bounds: localModel.tagBounds))) ?? Data()
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
