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
    /// True when the native app runs in the development environment. Lets the
    /// extension auto-enable dev logging without a manual toggle.
    public var developmentMode: Bool
    public init(enabledPlatformIDs: [String], developmentMode: Bool = false) {
        self.enabledPlatformIDs = enabledPlatformIDs.sorted()
        self.developmentMode = developmentMode
    }

    private enum CodingKeys: String, CodingKey { case enabledPlatformIDs, developmentMode }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabledPlatformIDs = (try container.decodeIfPresent([String].self, forKey: .enabledPlatformIDs) ?? []).sorted()
        developmentMode = try container.decodeIfPresent(Bool.self, forKey: .developmentMode) ?? false
    }
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

// MARK: - Per-video tags

/// A request for one video's tags, keyed by the video's durable `entryID` and
/// carrying the evidence the on-device LLM classifies (the creator is only a
/// weak derived prior, not the key).
public struct NativeVideoTagsRequest: Codable, Equatable, Sendable {
    public var platformID: String
    public var entryID: String
    public var creatorID: String
    public var title: String
    public var summary: String?
    public var text: String?

    public static let maximumTitleLength = 500
    public static let maximumEvidenceLength = 4_000

    public init(platformID: String, entryID: String, creatorID: String, title: String, summary: String? = nil, text: String? = nil) {
        self.platformID = platformID
        self.entryID = entryID
        self.creatorID = creatorID
        self.title = title
        self.summary = summary
        self.text = text
    }

    private enum CodingKeys: String, CodingKey { case platformID, entryID, creatorID, title, summary, text }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        platformID = try container.decode(String.self, forKey: .platformID)
        entryID = try container.decode(String.self, forKey: .entryID)
        creatorID = try container.decode(String.self, forKey: .creatorID)
        title = try container.decode(String.self, forKey: .title)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        text = try container.decodeIfPresent(String.self, forKey: .text)
    }

    public func validate() throws {
        guard NativeVideoTagsRequest.isValidPlatformID(platformID) else {
            throw NativeVideoTagsError.invalidPlatform
        }
        guard !entryID.isEmpty, entryID.count <= 256,
              entryID.hasPrefix("\(platformID):"),
              entryID == entryID.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw NativeVideoTagsError.invalidEvidence
        }
        guard !creatorID.isEmpty, creatorID.count <= 256,
              creatorID.hasPrefix("\(platformID):") else {
            throw NativeVideoTagsError.invalidEvidence
        }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              title.count <= Self.maximumTitleLength else {
            throw NativeVideoTagsError.invalidEvidence
        }
        guard (summary?.count ?? 0) <= Self.maximumEvidenceLength,
              (text?.count ?? 0) <= Self.maximumEvidenceLength else {
            throw NativeVideoTagsError.invalidEvidence
        }
    }

    static func isValidPlatformID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 64 && value.unicodeScalars.allSatisfy {
            ($0.value >= 0x61 && $0.value <= 0x7a) ||
            ($0.value >= 0x30 && $0.value <= 0x39) ||
            $0.value == 0x2d
        }
    }
}

public struct NativeVideoTagsResponse: Codable, Equatable, Sendable {
    public var platformID: String
    public var entryID: String
    public var tags: [NativeVideoTag]
    public var predicted: Bool
    /// True when the video is not yet classified: classification was queued and
    /// the caller should re-request shortly (the pill fills in on the next pass).
    public var pending: Bool

    public init(platformID: String, entryID: String, tags: [NativeVideoTag], predicted: Bool = false, pending: Bool = false) {
        self.platformID = platformID
        self.entryID = entryID
        self.tags = NativeVideoTag.accepted(tags)
        self.predicted = predicted
        self.pending = pending
    }

    private enum CodingKeys: String, CodingKey { case platformID, entryID, tags, predicted, pending }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        platformID = try container.decode(String.self, forKey: .platformID)
        entryID = try container.decode(String.self, forKey: .entryID)
        tags = NativeVideoTag.accepted(try container.decode([NativeVideoTag].self, forKey: .tags))
        predicted = try container.decodeIfPresent(Bool.self, forKey: .predicted) ?? false
        pending = try container.decodeIfPresent(Bool.self, forKey: .pending) ?? false
    }
}

/// Unsolicited push emitted when queued classification completes: the hub
/// relays it to every connected browser so provisional pills resolve without
/// polling. Reuses the batch response item shape (including its color-pair
/// filtering) so pushed tags are exactly what a re-request would return.
public struct NativeVideoTagsBroadcast: Codable, Equatable, Sendable {
    public var platformID: String
    public var items: [NativeVideoTagsBatchResponseItem]

    public init(platformID: String, items: [NativeVideoTagsBatchResponseItem]) {
        self.platformID = platformID
        self.items = items
    }
}

/// One video inside a batched per-video request. `platformID` rides on the
/// envelope; per item the entryID + evidence travel.
public struct NativeVideoTagsBatchItem: Codable, Equatable, Sendable {
    public var entryID: String
    public var creatorID: String
    public var title: String
    public var summary: String?
    public var text: String?

    public init(entryID: String, creatorID: String, title: String, summary: String? = nil, text: String? = nil) {
        self.entryID = entryID
        self.creatorID = creatorID
        self.title = title
        self.summary = summary
        self.text = text
    }

    private enum CodingKeys: String, CodingKey { case entryID, creatorID, title, summary, text }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entryID = try container.decode(String.self, forKey: .entryID)
        creatorID = try container.decode(String.self, forKey: .creatorID)
        title = try container.decode(String.self, forKey: .title)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        text = try container.decodeIfPresent(String.self, forKey: .text)
    }
}

public struct NativeVideoTagsBatchRequest: Codable, Equatable, Sendable {
    public var platformID: String
    public var items: [NativeVideoTagsBatchItem]

    public static let maximumItems = 64

    public init(platformID: String, items: [NativeVideoTagsBatchItem]) {
        self.platformID = platformID
        self.items = items
    }

    public func validate() throws {
        guard NativeVideoTagsRequest.isValidPlatformID(platformID) else {
            throw NativeVideoTagsError.invalidPlatform
        }
        guard items.count <= Self.maximumItems else { throw NativeVideoTagsError.invalidEvidence }
        for item in items {
            try NativeVideoTagsRequest(
                platformID: platformID, entryID: item.entryID, creatorID: item.creatorID,
                title: item.title, summary: item.summary, text: item.text
            ).validate()
        }
    }
}

public struct NativeVideoTagsBatchResponseItem: Codable, Equatable, Sendable {
    public var entryID: String
    public var tags: [NativeVideoTag]
    public var predicted: Bool
    public var pending: Bool

    public init(entryID: String, tags: [NativeVideoTag], predicted: Bool = false, pending: Bool = false) {
        self.entryID = entryID
        self.tags = NativeVideoTag.accepted(tags)
        self.predicted = predicted
        self.pending = pending
    }

    private enum CodingKeys: String, CodingKey { case entryID, tags, predicted, pending }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entryID = try container.decode(String.self, forKey: .entryID)
        tags = NativeVideoTag.accepted(try container.decode([NativeVideoTag].self, forKey: .tags))
        predicted = try container.decodeIfPresent(Bool.self, forKey: .predicted) ?? false
        pending = try container.decodeIfPresent(Bool.self, forKey: .pending) ?? false
    }
}

public struct NativeVideoTagsBatchResponse: Codable, Equatable, Sendable {
    public var platformID: String
    public var items: [NativeVideoTagsBatchResponseItem]

    public init(platformID: String, items: [NativeVideoTagsBatchResponseItem]) {
        self.platformID = platformID
        self.items = items
    }
}

/// Dev-only: a structured log line forwarded from an extension layer into the
/// unified VaultDevLog. The native side only persists it in the development
/// environment; it is discarded otherwise.
public struct NativeDevLogRequest: Codable, Equatable, Sendable {
    public var layer: String
    public var event: String
    public var fields: [String: String]

    public static let maximumFields = 24
    public static let maximumValueLength = 512

    public init(layer: String, event: String, fields: [String: String] = [:]) {
        self.layer = layer
        self.event = event
        self.fields = fields
    }

    private enum CodingKeys: String, CodingKey { case layer, event, fields }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        layer = try container.decode(String.self, forKey: .layer)
        event = try container.decode(String.self, forKey: .event)
        fields = try container.decodeIfPresent([String: String].self, forKey: .fields) ?? [:]
    }

    public func validate() throws {
        guard !layer.isEmpty, layer.count <= 32,
              !event.isEmpty, event.count <= 200,
              fields.count <= Self.maximumFields,
              fields.allSatisfy({ $0.key.count <= 64 && $0.value.count <= Self.maximumValueLength }) else {
            throw NativeBridgePayloadError.invalidPayload
        }
    }
}

public struct NativeDevLogResponse: Codable, Equatable, Sendable {
    public var accepted: Bool
    public init(accepted: Bool) { self.accepted = accepted }
}

public struct NativeVideoTag: Codable, Equatable, Sendable {
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

    public static func accepted(_ tags: [NativeVideoTag]) -> [NativeVideoTag] {
        Array(
            tags
                .filter {
                    TagColorAssignment.isValidThemePair(
                        lightHex: $0.lightColorHex,
                        darkHex: $0.darkColorHex
                    )
                }
                .prefix(16)
        )
    }
}

// MARK: - In-page tag correction (classifier-taxonomy + submit-correction)

/// The predictable tag choices the in-page pill UI offers for one platform.
public struct NativeClassifierTaxonomyRequest: Codable, Equatable, Sendable {
    public var platformID: String
    public init(platformID: String) { self.platformID = platformID }
    public func validate() throws {
        guard NativeVideoTagsRequest.isValidPlatformID(platformID) else {
            throw NativeVideoTagsError.invalidPlatform
        }
    }
}

public struct NativeClassifierTypeTaxonomy: Codable, Equatable, Sendable {
    public var typeID: String
    public var name: String
    public var tags: [NativeVideoTag]
    public init(typeID: String, name: String, tags: [NativeVideoTag]) {
        self.typeID = typeID
        self.name = name
        self.tags = tags
    }
}

public struct NativeClassifierTaxonomyResponse: Codable, Equatable, Sendable {
    public var platformID: String
    public var types: [NativeClassifierTypeTaxonomy]
    public init(platformID: String, types: [NativeClassifierTypeTaxonomy]) {
        self.platformID = platformID
        self.types = types
    }
}

/// A user correction from the in-page pill UI: the authoritative tag set for one
/// video under one classifier type.
public struct NativeSubmitCorrectionRequest: Codable, Equatable, Sendable {
    public var platformID: String
    public var entryID: String
    public var creatorID: String
    public var typeID: String
    public var correctTagIDs: [String]

    public init(platformID: String, entryID: String, creatorID: String, typeID: String, correctTagIDs: [String]) {
        self.platformID = platformID
        self.entryID = entryID
        self.creatorID = creatorID
        self.typeID = typeID
        self.correctTagIDs = correctTagIDs
    }

    public func validate() throws {
        guard NativeVideoTagsRequest.isValidPlatformID(platformID) else {
            throw NativeVideoTagsError.invalidPlatform
        }
        guard !entryID.isEmpty, entryID.count <= 256, entryID.hasPrefix("\(platformID):"),
              !creatorID.isEmpty, creatorID.count <= 256, creatorID.hasPrefix("\(platformID):"),
              !typeID.isEmpty, typeID.count <= 256,
              correctTagIDs.count <= CorrectionExample.maximumTagIDs,
              correctTagIDs.allSatisfy({ !$0.isEmpty && $0.count <= 256 }) else {
            throw NativeVideoTagsError.invalidEvidence
        }
    }
}

public struct NativeSubmitCorrectionResponse: Codable, Equatable, Sendable {
    public var platformID: String
    public var entryID: String
    public var tags: [NativeVideoTag]
    public init(platformID: String, entryID: String, tags: [NativeVideoTag]) {
        self.platformID = platformID
        self.entryID = entryID
        self.tags = tags
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

public enum NativeCollectionDiagnosticError: Error, LocalizedError, Sendable {
    case invalidPlatform

    public var errorDescription: String? {
        switch self {
        case .invalidPlatform: return "The collection diagnostic platform is invalid."
        }
    }
}

public enum NativeVideoTagsError: Error, LocalizedError, Sendable {
    case invalidPlatform
    case invalidEvidence

    public var errorDescription: String? {
        switch self {
        case .invalidPlatform: return "The video-tag platform is invalid."
        case .invalidEvidence: return "The video-tag evidence is invalid."
        }
    }
}

public enum NativeBridgePayloadError: Error, LocalizedError, Sendable {
    case invalidPayload

    public var errorDescription: String? { "The bridge payload is invalid." }
}
