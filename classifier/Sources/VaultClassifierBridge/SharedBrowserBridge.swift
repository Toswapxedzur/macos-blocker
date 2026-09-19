import Foundation
import VaultClassifierCore

/// The browser-facing operation vocabulary carried by the shared local Vault
/// hub. The hub relays only these bounded request shapes and never classifies.
public enum SharedBrowserBridgeOperation: String, CaseIterable, Codable, Sendable {
    case bridgeInfo = "bridge-info"
    case collectionInfo = "collection-info"
    case diagnostic = "diagnostic"
    case collect
    case videoTags = "video-tags"
    case videoTagsBatch = "video-tags-batch"
    // The predictable tag taxonomy for a platform's classifier types — used by
    // the in-page pill UI to offer add-a-tag choices. Read-only.
    case classifierTaxonomy = "classifier-taxonomy"
    // A user correction from the in-page pill UI: the authoritative tag set for
    // one video under one classifier type.
    case submitCorrection = "submit-correction"
    // Dev-only: extension layers forward structured log lines into the unified
    // VaultDevLog file (blockerGroup/misc/dev.log). No-op unless the app is in
    // the development environment.
    case devLog = "dev-log"
    // Activity log (see macosBlocker/ACTIVITY-LOG.md). The extension flushes
    // buffered browser-activity records (webVisit / contentWatched) to the native
    // store, and gets/sets the per-category recording settings. The hub host
    // handles these locally (writes its own store); they are not relayed to the
    // classifier peer.
    case activityRecord = "activity-record"
    case activitySettings = "activity-settings"
}

public extension SharedBrowserBridgeOperation {
    /// The request operations the local hub will relay browser→classifier —
    /// exactly this vocabulary, so the broker's guard and the enum can never
    /// drift (adding a case here is enough; there is no second list to update).
    static let relayableRequestOperations: Set<String> = Set(allCases.map(\.rawValue))

    /// The single classifier→browser broadcast the hub forwards (a completed
    /// classification). Broadcast-only, so it is not a request case above.
    static let videoTagsUpdatedBroadcast = "video-tags-updated"
    static let relayableBroadcastOperations: Set<String> = [videoTagsUpdatedBroadcast]
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
