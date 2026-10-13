import Foundation

/// In-process ordering for authoritative settings notifications. A new store
/// lifetime starts a new epoch; no ordering metadata changes saved schemas.
public struct ActivitySettingsSnapshot: Equatable, Sendable {
    public static let maxRevision = 9_007_199_254_740_991
    public let settings: ActivitySettings
    public let epoch: String
    public let revision: Int
    public let changedAtMs: Double
}
