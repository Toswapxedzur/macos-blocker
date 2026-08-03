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
    public var firstObservedAtMilliseconds: Int64?
    public var lastObservedAtMilliseconds: Int64?
    public var observationCount: Int?

    public init(
        entry: EntryEvidence,
        firstObservedAtMilliseconds: Int64? = nil,
        lastObservedAtMilliseconds: Int64? = nil,
        observationCount: Int? = nil
    ) {
        self.entry = entry
        self.firstObservedAtMilliseconds = firstObservedAtMilliseconds
        self.lastObservedAtMilliseconds = lastObservedAtMilliseconds
        self.observationCount = observationCount
    }
}

public struct NativeCollectionResponse: Codable, Equatable, Sendable {
    public var accepted: Bool
    public var inserted: Bool
    public init(accepted: Bool, inserted: Bool) { self.accepted = accepted; self.inserted = inserted }
}

public struct NativeSourceTagsRequest: Codable, Equatable, Sendable {
    public var platformID: String
    public var sourceID: String
    /// Best-effort display names for cards that expose no creator link (YouTube
    /// collaboration cards). Used only when `sourceID` resolves nothing.
    public var creatorNames: [String]

    public static let maximumCreatorNames = 4
    public static let maximumCreatorNameLength = 120

    public init(platformID: String, sourceID: String, creatorNames: [String] = []) {
        self.platformID = platformID
        self.sourceID = sourceID
        self.creatorNames = creatorNames
    }

    private enum CodingKeys: String, CodingKey { case platformID, sourceID, creatorNames }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        platformID = try container.decode(String.self, forKey: .platformID)
        sourceID = try container.decode(String.self, forKey: .sourceID)
        // Crash-guard for payloads from an older extension that omit the field.
        creatorNames = (try container.decodeIfPresent([String].self, forKey: .creatorNames)) ?? []
    }

    public func validate() throws {
        guard Self.isValidPlatformID(platformID) else {
            throw NativeSourceTagsError.invalidPlatform
        }
        guard !sourceID.isEmpty,
              sourceID.count <= 256,
              sourceID.hasPrefix("\(platformID):"),
              sourceID == sourceID.trimmingCharacters(in: .whitespacesAndNewlines),
              sourceID.unicodeScalars.allSatisfy({
                  $0.value >= 0x21 && $0.value != 0x7f
              }) else {
            throw NativeSourceTagsError.invalidSource
        }
        guard creatorNames.count <= Self.maximumCreatorNames,
              creatorNames.allSatisfy({ !$0.isEmpty && $0.count <= Self.maximumCreatorNameLength }) else {
            throw NativeSourceTagsError.invalidSource
        }
    }

    private static func isValidPlatformID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 64 && value.unicodeScalars.allSatisfy {
            ($0.value >= 0x61 && $0.value <= 0x7a) ||
            ($0.value >= 0x30 && $0.value <= 0x39) ||
            $0.value == 0x2d
        }
    }
}

public struct NativeSourceTag: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var lightColorHex: String
    public var darkColorHex: String

    public init(id: String, name: String, lightColorHex: String, darkColorHex: String) {
        self.id = id
        self.name = name
        self.lightColorHex = TagColorAssignment.normalizedHex(lightColorHex) ?? ""
        self.darkColorHex = TagColorAssignment.normalizedHex(darkColorHex) ?? ""
    }
}

public struct NativeSourceTagsResponse: Codable, Equatable, Sendable {
    public var platformID: String
    public var sourceID: String
    public var tags: [NativeSourceTag]

    public init(platformID: String, sourceID: String, tags: [NativeSourceTag]) {
        self.platformID = platformID
        self.sourceID = sourceID
        self.tags = Array(
            tags
                .filter {
                    TagColorAssignment.isValidThemePair(
                        lightHex: $0.lightColorHex,
                        darkHex: $0.darkColorHex
                    )
                }
                .prefix(CreatorClassificationRecord.maximumTagIDs)
        )
    }
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
    case missingContentID = "missing-content-id"
    case missingContentRoot = "missing-content-root"
    case missingTitle = "missing-title"
    case missingCreator = "missing-creator"
    case missingSource = "missing-source"
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

public enum NativeSourceTagsError: Error, LocalizedError, Sendable {
    case invalidPlatform
    case invalidSource

    public var errorDescription: String? {
        switch self {
        case .invalidPlatform: return "The source-tag platform is invalid."
        case .invalidSource: return "The source-tag identity is invalid."
        }
    }
}
