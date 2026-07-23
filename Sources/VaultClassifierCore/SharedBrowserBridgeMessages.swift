import Foundation

/// Bounded request/response shapes relayed over the shared local hub. These
/// messages contain no hub-authentication material; authentication is handled
/// before a peer is allowed to send any of them.
public struct NativeBridgeInfoRequest: Codable, Equatable, Sendable {
    public init() {}
}

public struct NativeBridgePolicy: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

public struct NativeBridgeInfoResponse: Codable, Equatable, Sendable {
    public var policies: [NativeBridgePolicy]
    public init(policies: [NativeBridgePolicy]) { self.policies = policies }
}

public struct NativeCollectionInfoRequest: Codable, Equatable, Sendable {
    public init() {}
}

public struct NativeCollectionInfoResponse: Codable, Equatable, Sendable {
    public var enabledPlatformIDs: [String]
    public init(enabledPlatformIDs: [String]) { self.enabledPlatformIDs = enabledPlatformIDs.sorted() }
}

public struct NativeCollectionRequest: Codable, Equatable, Sendable {
    public var entry: EntryEvidence
    public init(entry: EntryEvidence) { self.entry = entry }
}

public struct NativeCollectionResponse: Codable, Equatable, Sendable {
    public var accepted: Bool
    public var inserted: Bool
    public init(accepted: Bool, inserted: Bool) { self.accepted = accepted; self.inserted = inserted }
}

public enum NativeCollectionDiagnosticEvent: String, CaseIterable, Codable, Sendable {
    case collectorStarted = "collector-started"
    case collectionInfoRequested = "collection-info-requested"
    case collectionInfoEnabled = "collection-info-enabled"
    case collectionInfoDisabled = "collection-info-disabled"
    case collectionInfoFailed = "collection-info-failed"
    case pageEvidenceReady = "page-evidence-ready"
    case pageEvidenceMissing = "page-evidence-missing"
    case collectionRequested = "collection-requested"
    case collectionAccepted = "collection-accepted"
    case collectionRejected = "collection-rejected"
}

public enum NativeCollectionDiagnosticDetail: String, CaseIterable, Codable, Sendable {
    case missingVideoID = "missing-video-id"
    case missingWatchRoot = "missing-watch-root"
    case missingTitle = "missing-title"
    case missingCreator = "missing-creator"
    case runtimeLastError = "runtime-last-error"
    case bridgeUnavailable = "bridge-unavailable"
    case rejected
    case timeout
}

public struct NativeCollectionDiagnosticRequest: Codable, Equatable, Sendable {
    public var platformID: String
    public var event: NativeCollectionDiagnosticEvent
    public var detail: NativeCollectionDiagnosticDetail?

    public init(platformID: String, event: NativeCollectionDiagnosticEvent, detail: NativeCollectionDiagnosticDetail? = nil) {
        self.platformID = platformID
        self.event = event
        self.detail = detail
    }

    public func validate() throws {
        guard !platformID.isEmpty, platformID.count <= 64,
              platformID.unicodeScalars.allSatisfy({
                  ($0.value >= 0x61 && $0.value <= 0x7a) ||
                  ($0.value >= 0x30 && $0.value <= 0x39) ||
                  $0.value == 0x2d
              }) else {
            throw NativeCollectionDiagnosticError.invalidPlatform
        }
    }
}

public struct NativeCollectionDiagnosticResponse: Codable, Equatable, Sendable {
    public var accepted: Bool
    public init(accepted: Bool) { self.accepted = accepted }
}

public struct NativeClassificationRequest: Codable, Equatable, Sendable {
    public var entry: EntryEvidence
    public init(entry: EntryEvidence) { self.entry = entry }
}

public struct NativeClassificationResponse: Codable, Equatable, Sendable {
    public var result: ClassificationResult
    public var ledgerID: UUID?
    public init(result: ClassificationResult, ledgerID: UUID? = nil) { self.result = result; self.ledgerID = ledgerID }
}

public struct NativeCorrectionRequest: Codable, Equatable, Sendable {
    public var ledgerID: UUID
    public var correction: UserCorrection?
    public init(ledgerID: UUID, correction: UserCorrection?) { self.ledgerID = ledgerID; self.correction = correction }
}

public struct NativeCorrectionResponse: Codable, Equatable, Sendable {
    public var accepted: Bool
    public init(accepted: Bool) { self.accepted = accepted }
}

public enum NativeCollectionDiagnosticError: Error, LocalizedError, Sendable {
    case invalidPlatform

    public var errorDescription: String? {
        switch self {
        case .invalidPlatform: return "The collection diagnostic platform is invalid."
        }
    }
}
