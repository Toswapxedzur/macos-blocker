import Foundation

/// The browser-facing operation vocabulary carried by the shared local Vault
/// hub. The hub relays only these bounded request shapes and never classifies.
public enum SharedBrowserBridgeOperation: String, CaseIterable, Codable, Sendable {
    case bridgeInfo = "bridge-info"
    case collectionInfo = "collection-info"
    case diagnostic = "diagnostic"
    case collect
    case sourceTags = "source-tags"
    case sourceTagsBatch = "source-tags-batch"
    // Local-LLM rework: per-video tags, keyed by the video's entryID + evidence
    // (not the creator). The pill on the extension is now per-video.
    case videoTags = "video-tags"
    case videoTagsBatch = "video-tags-batch"
    // Dev-only: extension layers forward structured log lines into the unified
    // VaultDevLog file (blockerGroup/misc/dev.log). No-op unless the app is in
    // the development environment.
    case devLog = "dev-log"
    case classify
    case correct
}

public enum SharedBrowserBridgeProtocol {
    public static var address: String { address(for: .current) }
    public static let version = 4
    public static let maximumBodyBytes = 88_000
    public static let maximumRequestIDLength = 128
    public static let maximumPeerIDLength = 128
    public static let maximumErrorLength = 256

    public static func address(for environment: VaultRuntimeEnvironment) -> String {
        environment.hubAddress
    }

    public static func isValidRequestID(_ value: String) -> Bool {
        isVisibleIdentifier(value, maximumLength: maximumRequestIDLength)
    }

    public static func isValidPeerID(_ value: String) -> Bool {
        isVisibleIdentifier(value, maximumLength: maximumPeerIDLength)
    }

    public static func isValidBody(_ value: Any) -> Bool {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else {
            return false
        }
        return data.count <= maximumBodyBytes
    }

    public static func bodyData(from value: Any) -> Data? {
        guard isValidBody(value) else { return nil }
        return try? JSONSerialization.data(withJSONObject: value)
    }

    public static func isAcceptedHubProgram(_ value: String) -> Bool {
        value == "macapp" || value == "classifier"
    }

    public static func safeError(_ value: String?) -> String {
        let fallback = "classifier-request-rejected"
        guard let value else { return fallback }
        let bounded = String(value.prefix(maximumErrorLength))
        guard !bounded.isEmpty,
              bounded.unicodeScalars.allSatisfy({
                  $0.value >= 0x20 && $0.value <= 0x7e
              }) else {
            return fallback
        }
        return bounded
    }

    private static func isVisibleIdentifier(_ value: String, maximumLength: Int) -> Bool {
        !value.isEmpty && value.count <= maximumLength && value.unicodeScalars.allSatisfy {
            $0.value >= 0x21 && $0.value <= 0x7e
        }
    }
}
