import CryptoKit
import Foundation

/// The body stays base64-encoded inside the envelope. This makes its hash and
/// MAC independent of JSON key ordering in a browser or native JSON encoder.
public struct NativeEnvelope: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var kind: String
    public var requestID: String
    public var timestampMilliseconds: Int64
    public var nonce: String
    public var bodyBase64: String
    public var bodyHash: String
    public var mac: String?

    public init(protocolVersion: Int = 1, kind: String, requestID: String = UUID().uuidString, timestampMilliseconds: Int64 = Int64(Date().timeIntervalSince1970 * 1_000), nonce: String, bodyBase64: String, bodyHash: String, mac: String? = nil) {
        self.protocolVersion = protocolVersion
        self.kind = kind
        self.requestID = requestID
        self.timestampMilliseconds = timestampMilliseconds
        self.nonce = nonce
        self.bodyBase64 = bodyBase64
        self.bodyHash = bodyHash
        self.mac = mac
    }

    public static func unsigned<Body: Encodable>(kind: String, body: Body, requestID: String = UUID().uuidString, timestampMilliseconds: Int64 = Int64(Date().timeIntervalSince1970 * 1_000), nonce: String = NativeEnvelope.randomNonce()) throws -> NativeEnvelope {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bodyData = try encoder.encode(body)
        return .init(kind: kind, requestID: requestID, timestampMilliseconds: timestampMilliseconds, nonce: nonce, bodyBase64: bodyData.base64EncodedString(), bodyHash: Self.sha256(bodyData))
    }

    public mutating func sign(using secret: Data) {
        let key = SymmetricKey(data: secret)
        let code = HMAC<SHA256>.authenticationCode(for: Data(canonicalString.utf8), using: key)
        mac = Data(code).base64EncodedString()
    }

    public func bodyData() throws -> Data {
        guard let data = Data(base64Encoded: bodyBase64), Self.sha256(data) == bodyHash.lowercased() else {
            throw NativeProtocolError.bodyIntegrity
        }
        return data
    }

    public var canonicalString: String {
        "v=\(protocolVersion)\nkind=\(kind)\nid=\(requestID)\nts=\(timestampMilliseconds)\nnonce=\(nonce)\nbody=\(bodyHash.lowercased())"
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func randomNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 18)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
    }
}

public enum NativeProtocolError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedVersion
    case malformed
    case bodyIntegrity
    case missingMac
    case invalidMac
    case stale
    case replay

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion: return "Unsupported native protocol version."
        case .malformed: return "Malformed native protocol envelope."
        case .bodyIntegrity: return "Native message body failed integrity verification."
        case .missingMac: return "Authenticated native message is missing its MAC."
        case .invalidMac: return "Native message MAC is invalid."
        case .stale: return "Native message is outside the allowed time window."
        case .replay: return "Native message nonce was already used."
        }
    }
}

public struct NativeReplayWindow: Codable, Equatable, Sendable {
    public var acceptedNonces: [String: Int64]
    public var maximumEntries: Int

    public init(acceptedNonces: [String: Int64] = [:], maximumEntries: Int = 2_048) {
        self.acceptedNonces = acceptedNonces
        self.maximumEntries = max(1, maximumEntries)
    }

    public mutating func verifyAndRecord(_ envelope: NativeEnvelope, secret: Data, nowMilliseconds: Int64 = Int64(Date().timeIntervalSince1970 * 1_000), maximumAgeMilliseconds: Int64 = 5 * 60 * 1_000) throws {
        guard envelope.protocolVersion == 1,
              envelope.kind.count <= 64,
              envelope.requestID.count <= 128,
              envelope.nonce.count >= 16,
              envelope.bodyBase64.count <= 88_000,
              envelope.bodyHash.range(of: "^[0-9a-fA-F]{64}$", options: .regularExpression) != nil else {
            throw NativeProtocolError.malformed
        }
        guard abs(nowMilliseconds - envelope.timestampMilliseconds) <= maximumAgeMilliseconds else { throw NativeProtocolError.stale }
        _ = try envelope.bodyData()
        guard let encodedMac = envelope.mac, let supplied = Data(base64Encoded: encodedMac) else { throw NativeProtocolError.missingMac }
        let expected = HMAC<SHA256>.authenticationCode(for: Data(envelope.canonicalString.utf8), using: SymmetricKey(data: secret))
        guard Data(expected).constantTimeEquals(supplied) else { throw NativeProtocolError.invalidMac }
        acceptedNonces = acceptedNonces.filter { nowMilliseconds - $0.value <= maximumAgeMilliseconds }
        guard acceptedNonces[envelope.nonce] == nil else { throw NativeProtocolError.replay }
        acceptedNonces[envelope.nonce] = nowMilliseconds
        if acceptedNonces.count > maximumEntries {
            let old = acceptedNonces.sorted { $0.value < $1.value }.prefix(acceptedNonces.count - maximumEntries)
            for (nonce, _) in old { acceptedNonces.removeValue(forKey: nonce) }
        }
    }
}

private extension Data {
    func constantTimeEquals(_ other: Data) -> Bool {
        guard count == other.count else { return false }
        return zip(self, other).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

public struct NativePairRequest: Codable, Equatable, Sendable {
    public var clientID: String
    public init(clientID: String) { self.clientID = clientID }
}

public struct NativePairResponse: Codable, Equatable, Sendable {
    public var secretBase64: String
    public init(secretBase64: String) { self.secretBase64 = secretBase64 }
}

/// A browser can request this small, local-only inventory after native-host
/// pairing. It deliberately contains policy names and identifiers only: the
/// extension never receives a tree, model, ledger, evidence, or credential.
public struct NativeBridgeInfoRequest: Codable, Equatable, Sendable {
    public init() {}
}

public struct NativeBridgePolicy: Codable, Equatable, Sendable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct NativeBridgeInfoResponse: Codable, Equatable, Sendable {
    public var policies: [NativeBridgePolicy]

    public init(policies: [NativeBridgePolicy]) {
        self.policies = policies
    }
}

/// A browser obtains this tiny local-only inventory before it sends any
/// rendered platform metadata. It contains no titles, creator identities,
/// trees, datasets, labels, models, or credentials.
public struct NativeCollectionInfoRequest: Codable, Equatable, Sendable {
    public init() {}
}

public struct NativeCollectionInfoResponse: Codable, Equatable, Sendable {
    public var enabledPlatformIDs: [String]

    public init(enabledPlatformIDs: [String]) {
        self.enabledPlatformIDs = enabledPlatformIDs.sorted()
    }
}

public struct NativeCollectionRequest: Codable, Equatable, Sendable {
    public var entry: EntryEvidence

    public init(entry: EntryEvidence) {
        self.entry = entry
    }
}

public struct NativeCollectionResponse: Codable, Equatable, Sendable {
    public var accepted: Bool
    public var inserted: Bool

    public init(accepted: Bool, inserted: Bool) {
        self.accepted = accepted
        self.inserted = inserted
    }
}

/// Fixed, metadata-free checkpoints for diagnosing the local collection path.
/// These records deliberately exclude page text, titles, creator identity,
/// URLs, entry IDs, and credentials. They only make it possible to identify
/// which hop (content script, extension bridge, hub, or local app) stopped.
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
    case rejected = "rejected"
    case timeout = "timeout"
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
              platformID.unicodeScalars.allSatisfy({ scalar in
                  (scalar.value >= 0x61 && scalar.value <= 0x7a) ||
                  (scalar.value >= 0x30 && scalar.value <= 0x39) ||
                  scalar.value == 0x2d
              }) else {
            throw NativeCollectionDiagnosticError.invalidPlatform
        }
    }
}

public struct NativeCollectionDiagnosticResponse: Codable, Equatable, Sendable {
    public var accepted: Bool

    public init(accepted: Bool) {
        self.accepted = accepted
    }
}

public enum NativeCollectionDiagnosticError: Error, LocalizedError, Sendable {
    case invalidPlatform

    public var errorDescription: String? {
        switch self {
        case .invalidPlatform: return "The collection diagnostic platform is invalid."
        }
    }
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
