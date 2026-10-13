import Foundation

/// Browser authorization is native-known, ephemeral ordering metadata, never
/// part of an on-disk ActivityRecord or a caller-supplied enabled setting.
public struct ActivityRecordAuthorization: Equatable, Sendable {
    public let epoch: String
    public let revision: Int
    public init(epoch: String, revision: Int) { self.epoch = epoch; self.revision = revision }
}

public struct ActivityBrowserRecord: Sendable {
    public let record: ActivityRecord
    public let authorization: ActivityRecordAuthorization?
    public let observedEndedAtMs: Double?
    public init(record: ActivityRecord, authorization: ActivityRecordAuthorization?, observedEndedAtMs: Double?) {
        self.record = record; self.authorization = authorization; self.observedEndedAtMs = observedEndedAtMs
    }
}

public enum ActivityBrowserRecordResult: Equatable, Sendable {
    case stored, alreadyStored, rejected, pending
    public var accepted: Bool { self == .stored || self == .alreadyStored }
}
