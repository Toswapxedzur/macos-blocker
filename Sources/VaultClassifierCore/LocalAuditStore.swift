import Foundation

/// A user-confirmed, local-only application of an already validated audit.
/// Provider output alone never creates this record or trains the personal
/// model. It also prevents one UI action from accidentally applying the same
/// correction more than once.
public struct LocalAuditLearningApplication: Codable, Equatable, Sendable, Identifiable {
    public var auditID: UUID
    public var policyID: String
    public var leafTagIDs: [String]
    public var appliedAtMilliseconds: Int64

    public var id: UUID { auditID }

    public init(auditID: UUID, policyID: String, leafTagIDs: [String], appliedAtMilliseconds: Int64) {
        self.auditID = auditID
        self.policyID = policyID
        self.leafTagIDs = leafTagIDs
        self.appliedAtMilliseconds = appliedAtMilliseconds
    }
}

/// Persisted, bounded local state for optional personal audits. It has no
/// network endpoint, credential, account, or contribution path. Raw evidence
/// exists only here on the user's device; the export type is separately
/// redacted by `RedactedAuditDiagnosticExport`.
public struct LocalAuditState: Codable, Equatable, Sendable {
    public static let defaultCandidateLimit = 1_024
    public static let defaultResultLimit = 1_024

    public var configuration: LocalAuditConfiguration?
    public var candidates: [AuditedEntry]
    public var results: [ValidatedAuditResult]
    public var learningApplications: [LocalAuditLearningApplication]
    public var budgetLedger: AuditBudgetLedger
    public var candidateLimit: Int
    public var resultLimit: Int

    public init(
        configuration: LocalAuditConfiguration? = nil,
        candidates: [AuditedEntry] = [],
        results: [ValidatedAuditResult] = [],
        learningApplications: [LocalAuditLearningApplication] = [],
        budgetLedger: AuditBudgetLedger = .init(),
        candidateLimit: Int = Self.defaultCandidateLimit,
        resultLimit: Int = Self.defaultResultLimit
    ) {
        self.configuration = configuration
        self.candidates = candidates
        self.results = results
        self.learningApplications = learningApplications
        self.budgetLedger = budgetLedger
        self.candidateLimit = max(1, candidateLimit)
        self.resultLimit = max(1, resultLimit)
    }

    public mutating func upsertCandidate(_ candidate: AuditedEntry) {
        candidates.removeAll { $0.auditID == candidate.auditID }
        candidates.append(candidate)
        trim()
    }

    public mutating func upsertResult(_ result: ValidatedAuditResult) {
        results.removeAll { $0.auditID == result.auditID }
        results.append(result)
        trim()
    }

    public mutating func recordLearningApplication(_ application: LocalAuditLearningApplication) {
        learningApplications.removeAll { $0.auditID == application.auditID }
        learningApplications.append(application)
        trim()
    }

    /// Audit candidates and results are bound to the exact local model that
    /// produced their decision. Budget reservations are intentionally retained:
    /// a provider may already have billed a possibly-sent request, and model
    /// replacement must never erase that accounting record.
    public mutating func invalidatePackageBoundRecords(except identity: ActiveModelIdentity) {
        let currentCandidateIDs = Set(candidates.compactMap { candidate in
            candidate.modelIdentity == identity ? candidate.auditID : nil
        })
        candidates.removeAll { $0.modelIdentity != identity }
        results.removeAll { result in
            result.modelIdentity != identity || !currentCandidateIDs.contains(result.auditID)
        }
        // Learning applications are immutable local-user history. They cannot
        // be replayed without a current candidate/result, so retain that audit
        // trail while removing all actionable package-bound records above.
    }

    public mutating func trim() {
        candidateLimit = max(1, candidateLimit)
        resultLimit = max(1, resultLimit)
        if candidates.count > candidateLimit { candidates.removeFirst(candidates.count - candidateLimit) }
        if results.count > resultLimit { results.removeFirst(results.count - resultLimit) }
        if learningApplications.count > resultLimit {
            learningApplications.removeFirst(learningApplications.count - resultLimit)
        }
    }

    public func redactedExport(generatedAtMilliseconds: Int64) -> RedactedAuditDiagnosticExport {
        .init(
            generatedAtMilliseconds: generatedAtMilliseconds,
            candidates: candidates,
            results: results,
            ledger: budgetLedger
        )
    }

    private enum CodingKeys: String, CodingKey {
        case configuration, candidates, results, learningApplications, budgetLedger, candidateLimit, resultLimit
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        configuration = try container.decodeIfPresent(LocalAuditConfiguration.self, forKey: .configuration)
        candidates = try container.decodeIfPresent([AuditedEntry].self, forKey: .candidates) ?? []
        results = try container.decodeIfPresent([ValidatedAuditResult].self, forKey: .results) ?? []
        learningApplications = try container.decodeIfPresent([LocalAuditLearningApplication].self, forKey: .learningApplications) ?? []
        budgetLedger = try container.decodeIfPresent(AuditBudgetLedger.self, forKey: .budgetLedger) ?? .init()
        candidateLimit = max(1, try container.decodeIfPresent(Int.self, forKey: .candidateLimit) ?? Self.defaultCandidateLimit)
        resultLimit = max(1, try container.decodeIfPresent(Int.self, forKey: .resultLimit) ?? Self.defaultResultLimit)
        trim()
    }
}

public enum LocalAuditStoreError: Error, Equatable, LocalizedError, Sendable {
    case auditNotFound
    case configurationMissing
    case localAuditDisabledByResourceSettings
    case reservationMismatch
    case policyContextUnavailable
    case policyContextMismatch
    case attemptAlreadyInFlight
    case auditFindingNotApplicable
    case localLearningDisabled
    case auditAlreadyApplied
    case staleModelIdentity

    public var errorDescription: String? {
        switch self {
        case .auditNotFound: return "The local audit candidate is no longer available."
        case .configurationMissing: return "Personal LLM auditing is not configured locally."
        case .localAuditDisabledByResourceSettings: return "Personal LLM auditing is disabled by this Mac's resource settings."
        case .reservationMismatch: return "The local audit budget reservation does not match this request."
        case .policyContextUnavailable: return "No bounded active policy context is available for this audit entry."
        case .policyContextMismatch: return "The audit request no longer matches the active local policy context."
        case .attemptAlreadyInFlight: return "This audit candidate already has a request that may still be in flight."
        case .auditFindingNotApplicable: return "This audit finding is not a current policy-changing false allow."
        case .localLearningDisabled: return "Local learning from confirmed audits is disabled."
        case .auditAlreadyApplied: return "This audit finding was already applied to the local model."
        case .staleModelIdentity: return "This audit record belongs to a different or legacy local model."
        }
    }
}
