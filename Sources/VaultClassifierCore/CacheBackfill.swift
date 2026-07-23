import Foundation

/// A direct-only refresh is useful for making the newest retained entries
/// current quickly, but it is not a causal source-prior result. Only the FIFO
/// phase may produce a final cached decision.
public enum CacheBackfillPhase: String, Codable, Equatable, Sendable {
    /// Re-evaluate newest retained evidence first with no source profile.
    case directRefresh
    /// Rebuild source observations and final decisions strictly oldest-first.
    case causalReplay
}

/// A persisted, local-only continuation for an explicit cache backfill. It is
/// deliberately not a scheduler: a caller must explicitly invoke
/// `backfillCachedEntries` for every bounded batch.
///
/// The two queues intentionally have opposite orders. `directRefresh` may
/// prioritize recency because it records no source observations. The causal
/// queue is always FIFO; reversing it would leak a newer entry into an older
/// entry's source prior.
public struct CacheBackfillProgress: Codable, Equatable, Sendable {
    public var packageID: String
    public var modelVersion: String
    /// Package/model names are not unique release identities. Bind a pending
    /// replay to the signed manifest's monotonic release and exact payload so
    /// another verified release with the same display names cannot resume it.
    public var releaseSequence: Int64
    public var payloadSHA256: String
    public var activatedAt: Date
    public var startedAt: Date?
    public var phase: CacheBackfillPhase
    /// Newest-to-oldest while `phase == .directRefresh`.
    public var directRefreshPendingCacheKeys: [String]
    /// Oldest-to-newest while `phase == .causalReplay`.
    public var causalReplayPendingCacheKeys: [String]
    public var directRefreshCompletedEntryCount: Int
    public var causalReplayCompletedEntryCount: Int

    private enum CodingKeys: String, CodingKey {
        case packageID
        case modelVersion
        case releaseSequence
        case payloadSHA256
        case activatedAt
        case startedAt
        case phase
        case directRefreshPendingCacheKeys
        case causalReplayPendingCacheKeys
        case directRefreshCompletedEntryCount
        case causalReplayCompletedEntryCount
        // Legacy single-phase fields. They deliberately decode as a fresh
        // continuation because a partially rebuilt old source profile cannot
        // be safely converted into this two-stage contract.
        case pendingCacheKeys
        case completedEntryCount
    }

    public init(
        packageID: String,
        modelVersion: String,
        releaseSequence: Int64,
        payloadSHA256: String,
        activatedAt: Date = .now,
        startedAt: Date? = nil,
        phase: CacheBackfillPhase = .directRefresh,
        directRefreshPendingCacheKeys: [String] = [],
        causalReplayPendingCacheKeys: [String] = [],
        directRefreshCompletedEntryCount: Int = 0,
        causalReplayCompletedEntryCount: Int = 0
    ) {
        self.packageID = packageID
        self.modelVersion = modelVersion
        self.releaseSequence = releaseSequence
        self.payloadSHA256 = payloadSHA256
        self.activatedAt = activatedAt
        self.startedAt = startedAt
        self.phase = phase
        self.directRefreshPendingCacheKeys = directRefreshPendingCacheKeys
        self.causalReplayPendingCacheKeys = causalReplayPendingCacheKeys
        self.directRefreshCompletedEntryCount = directRefreshCompletedEntryCount
        self.causalReplayCompletedEntryCount = causalReplayCompletedEntryCount
    }

    /// Older source-only development state did not persist the signed release
    /// identity. Decode it as deliberately ineligible rather than preventing
    /// the whole local state file from opening; the coordinator will require a
    /// fresh verified activation before it can resume that continuation.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        packageID = try container.decode(String.self, forKey: .packageID)
        modelVersion = try container.decode(String.self, forKey: .modelVersion)
        releaseSequence = try container.decodeIfPresent(Int64.self, forKey: .releaseSequence) ?? 0
        payloadSHA256 = try container.decodeIfPresent(String.self, forKey: .payloadSHA256) ?? ""
        activatedAt = try container.decodeIfPresent(Date.self, forKey: .activatedAt) ?? .distantPast
        guard let decodedPhase = try container.decodeIfPresent(CacheBackfillPhase.self, forKey: .phase) else {
            // Do not accidentally resume a legacy FIFO continuation after its
            // direct/source split has changed. A later explicit call starts a
            // clean two-stage replay from the retained cache.
            startedAt = nil
            phase = .directRefresh
            directRefreshPendingCacheKeys = []
            causalReplayPendingCacheKeys = []
            directRefreshCompletedEntryCount = 0
            causalReplayCompletedEntryCount = 0
            return
        }
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        phase = decodedPhase
        directRefreshPendingCacheKeys = try container.decodeIfPresent([String].self, forKey: .directRefreshPendingCacheKeys) ?? []
        causalReplayPendingCacheKeys = try container.decodeIfPresent([String].self, forKey: .causalReplayPendingCacheKeys) ?? []
        directRefreshCompletedEntryCount = try container.decodeIfPresent(Int.self, forKey: .directRefreshCompletedEntryCount) ?? 0
        causalReplayCompletedEntryCount = try container.decodeIfPresent(Int.self, forKey: .causalReplayCompletedEntryCount) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(packageID, forKey: .packageID)
        try container.encode(modelVersion, forKey: .modelVersion)
        try container.encode(releaseSequence, forKey: .releaseSequence)
        try container.encode(payloadSHA256, forKey: .payloadSHA256)
        try container.encode(activatedAt, forKey: .activatedAt)
        try container.encodeIfPresent(startedAt, forKey: .startedAt)
        try container.encode(phase, forKey: .phase)
        try container.encode(directRefreshPendingCacheKeys, forKey: .directRefreshPendingCacheKeys)
        try container.encode(causalReplayPendingCacheKeys, forKey: .causalReplayPendingCacheKeys)
        try container.encode(directRefreshCompletedEntryCount, forKey: .directRefreshCompletedEntryCount)
        try container.encode(causalReplayCompletedEntryCount, forKey: .causalReplayCompletedEntryCount)
    }

    public var isStarted: Bool { startedAt != nil }

    /// Compatibility/readability view of the queue active in this phase.
    public var pendingCacheKeys: [String] {
        switch phase {
        case .directRefresh: directRefreshPendingCacheKeys
        case .causalReplay: causalReplayPendingCacheKeys
        }
    }

    public var completedEntryCount: Int {
        directRefreshCompletedEntryCount + causalReplayCompletedEntryCount
    }

    public func remainingEntryCount(retainedCacheEntryCount: Int) -> Int {
        switch phase {
        case .directRefresh:
            // Every retained row still needs one causal finalization even if
            // its newest-first direct result has already been refreshed.
            return directRefreshPendingCacheKeys.count + max(0, retainedCacheEntryCount)
        case .causalReplay:
            return causalReplayPendingCacheKeys.count
        }
    }

    public mutating func start(withFIFOKeys keys: [String], at date: Date) {
        phase = .directRefresh
        directRefreshPendingCacheKeys = Array(keys.reversed())
        causalReplayPendingCacheKeys = []
        directRefreshCompletedEntryCount = 0
        causalReplayCompletedEntryCount = 0
        startedAt = date
    }

    public mutating func beginCausalReplay(withFIFOKeys keys: [String]) {
        phase = .causalReplay
        directRefreshPendingCacheKeys = []
        causalReplayPendingCacheKeys = keys
    }

    public mutating func restart() {
        startedAt = nil
        phase = .directRefresh
        directRefreshPendingCacheKeys = []
        causalReplayPendingCacheKeys = []
        directRefreshCompletedEntryCount = 0
        causalReplayCompletedEntryCount = 0
    }
}

/// The caller-owned work bound for one local backfill call. There is no
/// implicit idle worker or automatic package-activation work in this API.
public struct CacheBackfillRequest: Codable, Equatable, Sendable {
    public static let maximumEntryLimit = 1_000
    public var maximumEntries: Int

    public init(maximumEntries: Int) throws {
        guard (1...Self.maximumEntryLimit).contains(maximumEntries) else {
            throw CacheBackfillError.invalidMaximumEntries(maximumEntries)
        }
        self.maximumEntries = maximumEntries
    }
}

/// A bounded summary that intentionally contains no cached evidence, source
/// ID, or entry ID. A future user-controlled background mode can repeat calls
/// while `remainingEntries` is non-zero.
public struct CacheBackfillReport: Codable, Equatable, Sendable {
    public var packageID: String
    public var modelVersion: String
    public var startedBackfill: Bool
    public var reclassifiedEntries: Int
    public var skippedMissingEntries: Int
    public var remainingEntries: Int
    public var retainedCacheEntries: Int
    public var staleEntriesBeforeBatch: Int
    public var isComplete: Bool
    /// The persisted phase after this batch. A direct refresh is deliberately
    /// not final until the later causal replay completes its row.
    public var phase: CacheBackfillPhase
    public var directRefreshedEntries: Int
    public var causallyReplayedEntries: Int

    public init(
        packageID: String,
        modelVersion: String,
        startedBackfill: Bool,
        reclassifiedEntries: Int,
        skippedMissingEntries: Int,
        remainingEntries: Int,
        retainedCacheEntries: Int,
        staleEntriesBeforeBatch: Int,
        isComplete: Bool,
        phase: CacheBackfillPhase = .directRefresh,
        directRefreshedEntries: Int = 0,
        causallyReplayedEntries: Int = 0
    ) {
        self.packageID = packageID
        self.modelVersion = modelVersion
        self.startedBackfill = startedBackfill
        self.reclassifiedEntries = reclassifiedEntries
        self.skippedMissingEntries = skippedMissingEntries
        self.remainingEntries = remainingEntries
        self.retainedCacheEntries = retainedCacheEntries
        self.staleEntriesBeforeBatch = staleEntriesBeforeBatch
        self.isComplete = isComplete
        self.phase = phase
        self.directRefreshedEntries = directRefreshedEntries
        self.causallyReplayedEntries = causallyReplayedEntries
    }
}

public enum CacheBackfillError: Error, Equatable, LocalizedError, Sendable {
    case invalidMaximumEntries(Int)
    case noEligibleVerifiedPackage
    case packageMismatch
    case invalidContinuation

    public var errorDescription: String? {
        switch self {
        case .invalidMaximumEntries(let value):
            return "A cache backfill batch must contain between 1 and \(CacheBackfillRequest.maximumEntryLimit) entries (received \(value))."
        case .noEligibleVerifiedPackage:
            return "Cache backfill is available only after a verified package activation."
        case .packageMismatch:
            return "The pending cache backfill does not match the active verified package."
        case .invalidContinuation:
            return "The local cache-backfill continuation is invalid."
        }
    }
}
