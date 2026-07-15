import CryptoKit
import Foundation

// MARK: - Untrusted audit evidence

/// The only evidence shape permitted in a local audit. Browser- and
/// user-supplied text stays data, not instructions: an adapter must preserve
/// the quote boundary when it builds a provider request.
public enum AuditEvidenceOrigin: String, Codable, Equatable, Sendable, CaseIterable {
    case browserDOM
    case userSupplied
    case importedLocalRecord
}

public enum AuditEvidenceTrust: String, Codable, Equatable, Sendable {
    case untrustedQuoted
}

public enum AuditQuoteFormat: String, Codable, Equatable, Sendable {
    /// A fixed pair of delimiters surrounds a structured, bounded JSON value.
    /// The delimiter names are deliberately not configurable by a provider or
    /// by the evidence producer.
    case delimitedJSONV1

    public var openingDelimiter: String { "BEGIN_UNTRUSTED_ENTRY_EVIDENCE_V1" }
    public var closingDelimiter: String { "END_UNTRUSTED_ENTRY_EVIDENCE_V1" }
}

public enum LocalAuditEvidenceError: Error, Equatable, LocalizedError, Sendable {
    case invalidEntry
    case invalidTimestamp
    case integrityMismatch

    public var errorDescription: String? {
        switch self {
        case .invalidEntry: return "Audit evidence does not satisfy the bounded entry contract."
        case .invalidTimestamp: return "Audit evidence has an invalid capture timestamp."
        case .integrityMismatch: return "Audit evidence digest does not match its quoted entry."
        }
    }
}

/// An immutable, bounded snapshot of evidence. `entry` is intentionally named
/// `quotedEntry` so callers do not accidentally treat browser DOM text as a
/// trusted instruction or a verified label.
public struct UntrustedQuotedEvidence: Codable, Equatable, Sendable {
    public var origin: AuditEvidenceOrigin
    public var capturedAtMilliseconds: Int64
    public var quoteFormat: AuditQuoteFormat
    public var quotedEntry: EntryEvidence
    public var evidenceDigest: String

    public var trust: AuditEvidenceTrust { .untrustedQuoted }

    public init(
        origin: AuditEvidenceOrigin,
        capturedAtMilliseconds: Int64,
        quotedEntry: EntryEvidence,
        quoteFormat: AuditQuoteFormat = .delimitedJSONV1
    ) throws {
        self.origin = origin
        self.capturedAtMilliseconds = capturedAtMilliseconds
        self.quoteFormat = quoteFormat
        self.quotedEntry = quotedEntry
        self.evidenceDigest = try Self.digest(for: quotedEntry)
        try validate()
    }

    public func validate() throws {
        guard capturedAtMilliseconds >= 0 else { throw LocalAuditEvidenceError.invalidTimestamp }
        do {
            try EntryEvidenceValidator().validate(quotedEntry)
        } catch {
            throw LocalAuditEvidenceError.invalidEntry
        }
        guard evidenceDigest == (try Self.digest(for: quotedEntry)) else {
            throw LocalAuditEvidenceError.integrityMismatch
        }
    }

    /// This is structured prompt data only. A provider adapter is responsible
    /// for adding the fixed task instruction outside these delimiters.
    public func delimitedJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(quotedEntry)
        let json = String(decoding: data, as: UTF8.self)
        return "\(quoteFormat.openingDelimiter)\n\(json)\n\(quoteFormat.closingDelimiter)"
    }

    public static func digest(for entry: EntryEvidence) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return SHA256.hash(data: try encoder.encode(entry)).hexString
    }
}

// MARK: - Local eligibility and deterministic risk signals

public enum AuditRiskKind: String, Codable, Equatable, Sendable, CaseIterable {
    case userMarked
    case nearPolicyMargin
    case lowConfidence
    case sourceDirectDisagreement
    case novelEvidence
    case randomSample
    case manualReview
}

/// A numeric factor contains only a local measurement, never a title,
/// description, URL, model prompt, or provider-provided free text.
public struct AuditRiskFactor: Codable, Equatable, Sendable, Identifiable {
    public var kind: AuditRiskKind
    public var severity: Double
    public var measuredValue: Double?

    public var id: String { kind.rawValue }

    public init(kind: AuditRiskKind, severity: Double, measuredValue: Double? = nil) {
        self.kind = kind
        self.severity = severity
        self.measuredValue = measuredValue
    }
}

public enum AuditRiskValidationError: Error, Equatable, LocalizedError, Sendable {
    case noFactors
    case tooManyFactors
    case duplicateFactor
    case invalidSeverity
    case invalidMeasuredValue

    public var errorDescription: String? {
        switch self {
        case .noFactors: return "An audit candidate needs at least one local risk signal."
        case .tooManyFactors: return "The audit candidate has too many risk signals."
        case .duplicateFactor: return "Each audit risk signal may appear only once."
        case .invalidSeverity: return "Audit risk severity must be a finite value from zero through one."
        case .invalidMeasuredValue: return "Audit risk measurement must be finite."
        }
    }
}

public struct AuditRiskRecord: Codable, Equatable, Sendable {
    public static let maximumFactors = 8

    public var factors: [AuditRiskFactor]
    public var assessedAtMilliseconds: Int64

    /// The score is derived rather than supplied by an extension or a model.
    /// This leaves selection policy transparent and deterministic.
    public var priority: Double { factors.map(\.severity).max() ?? 0 }

    public init(factors: [AuditRiskFactor], assessedAtMilliseconds: Int64) throws {
        self.factors = factors
        self.assessedAtMilliseconds = assessedAtMilliseconds
        try validate()
    }

    public func validate() throws {
        guard assessedAtMilliseconds >= 0 else { throw AuditRiskValidationError.invalidMeasuredValue }
        guard !factors.isEmpty else { throw AuditRiskValidationError.noFactors }
        guard factors.count <= Self.maximumFactors else { throw AuditRiskValidationError.tooManyFactors }
        guard Set(factors.map(\.kind)).count == factors.count else { throw AuditRiskValidationError.duplicateFactor }
        for factor in factors {
            guard factor.severity.isFinite, (0...1).contains(factor.severity) else {
                throw AuditRiskValidationError.invalidSeverity
            }
            guard factor.measuredValue?.isFinite ?? true else {
                throw AuditRiskValidationError.invalidMeasuredValue
            }
        }
    }

    public func contains(_ kind: AuditRiskKind) -> Bool {
        factors.contains { $0.kind == kind }
    }
}

public enum AuditIntent: String, Codable, Equatable, Sendable, CaseIterable {
    /// Background selection of an allowed entry which may be a false allow.
    case potentialFalseAllow
    /// An explicit local review of an entry the person marked for inspection.
    case userMarkedDecisionReview
}

public enum AuditIneligibilityReason: String, Codable, Equatable, Sendable, CaseIterable {
    case invalidQuotedEvidence
    case classificationDoesNotMatchEvidence
    case insufficientClassificationEvidence
    case noRiskSignal
    case falseAllowRequiresAllowDecision
    case userReviewRequiresUserMark
}

public struct AuditEligibility: Codable, Equatable, Sendable {
    public var isEligible: Bool
    public var reasons: [AuditIneligibilityReason]

    public init(isEligible: Bool, reasons: [AuditIneligibilityReason] = []) {
        self.isEligible = isEligible
        self.reasons = reasons
    }

    public static func assess(
        evidence: UntrustedQuotedEvidence,
        localResult: ClassificationResult,
        intent: AuditIntent,
        risk: AuditRiskRecord
    ) -> AuditEligibility {
        var reasons: [AuditIneligibilityReason] = []
        if (try? evidence.validate()) == nil {
            reasons.append(.invalidQuotedEvidence)
        }
        if localResult.entryID != evidence.quotedEntry.entryID ||
            localResult.sourceID != evidence.quotedEntry.sourceID ||
            localResult.surface != evidence.quotedEntry.surface {
            reasons.append(.classificationDoesNotMatchEvidence)
        }
        if localResult.evidenceState != .sufficient {
            reasons.append(.insufficientClassificationEvidence)
        }
        if risk.factors.isEmpty {
            reasons.append(.noRiskSignal)
        }
        switch intent {
        case .potentialFalseAllow where localResult.strongestAction != .allow:
            reasons.append(.falseAllowRequiresAllowDecision)
        case .userMarkedDecisionReview where !risk.contains(.userMarked):
            reasons.append(.userReviewRequiresUserMark)
        default:
            break
        }
        return .init(isEligible: reasons.isEmpty, reasons: reasons)
    }
}

/// A local-only audit candidate. It carries a snapshot of the local decision
/// so that a provider response cannot be attached to a different entry or
/// silently change a policy decision.
public struct AuditedEntry: Codable, Equatable, Sendable, Identifiable {
    public var auditID: UUID
    public var evidence: UntrustedQuotedEvidence
    public var localResult: ClassificationResult
    /// Exact active package identity captured with the local decision. A nil
    /// value represents legacy state and is never eligible for coordinator
    /// dispatch after identity enforcement is enabled.
    public var modelIdentity: ActiveModelIdentity?
    public var intent: AuditIntent
    public var risk: AuditRiskRecord
    public var eligibility: AuditEligibility
    public var createdAtMilliseconds: Int64

    public var id: UUID { auditID }

    public init(
        auditID: UUID = UUID(),
        evidence: UntrustedQuotedEvidence,
        localResult: ClassificationResult,
        modelIdentity: ActiveModelIdentity? = nil,
        intent: AuditIntent,
        risk: AuditRiskRecord,
        createdAtMilliseconds: Int64
    ) throws {
        guard createdAtMilliseconds >= 0 else { throw LocalAuditEvidenceError.invalidTimestamp }
        self.auditID = auditID
        self.evidence = evidence
        self.localResult = localResult
        self.modelIdentity = modelIdentity
        self.intent = intent
        self.risk = risk
        self.eligibility = AuditEligibility.assess(evidence: evidence, localResult: localResult, intent: intent, risk: risk)
        self.createdAtMilliseconds = createdAtMilliseconds
        try validate()
    }

    public func validate() throws {
        try evidence.validate()
        try risk.validate()
        let expected = AuditEligibility.assess(evidence: evidence, localResult: localResult, intent: intent, risk: risk)
        guard eligibility == expected else { throw LocalAuditEvidenceError.integrityMismatch }
    }
}

// MARK: - Trusted local policy context

/// A bounded, app-generated description of the policies that may be reviewed
/// for one entry. It deliberately contains no browser text, URLs, source IDs,
/// entry IDs, provider instructions, or user-authored policy name. The only
/// labels it exposes are taxonomy-controlled menu leaves and the criteria that
/// make those leaves relevant to an active requested policy.
public struct AuditPolicyContextPolicy: Codable, Equatable, Sendable, Identifiable {
    public var policyID: String
    public var includeAnyTagIDs: [String]
    public var includeAllTagIDs: [String]
    public var excludeTagIDs: [String]
    public var action: PresentationAction

    public var id: String { policyID }

    public init(
        policyID: String,
        includeAnyTagIDs: [String],
        includeAllTagIDs: [String],
        excludeTagIDs: [String],
        action: PresentationAction
    ) {
        self.policyID = policyID
        self.includeAnyTagIDs = includeAnyTagIDs
        self.includeAllTagIDs = includeAllTagIDs
        self.excludeTagIDs = excludeTagIDs
        self.action = action
    }

    public var criterionTagIDs: [String] {
        includeAnyTagIDs + includeAllTagIDs + excludeTagIDs
    }
}

public struct AuditPolicyContextLeaf: Codable, Equatable, Sendable, Identifiable {
    public var tagID: String
    public var name: String

    public var id: String { tagID }

    public init(tagID: String, name: String) {
        self.tagID = tagID
        self.name = name
    }
}

public enum AuditPolicyContextError: Error, Equatable, LocalizedError, Sendable {
    case noRequestedPolicies
    case tooManyPolicies
    case duplicatePolicy
    case invalidPolicyIdentifier
    case invalidCriteria
    case tooManyCriteria
    case tooManyLeaves
    case duplicateLeaf
    case invalidLeaf

    public var errorDescription: String? {
        switch self {
        case .noRequestedPolicies: return "An audit needs at least one active requested policy."
        case .tooManyPolicies: return "The audit policy context contains too many policies."
        case .duplicatePolicy: return "The audit policy context contains a duplicate policy."
        case .invalidPolicyIdentifier: return "The audit policy context contains an invalid policy identifier."
        case .invalidCriteria: return "The audit policy context contains invalid policy criteria."
        case .tooManyCriteria: return "The audit policy context contains too many policy criteria."
        case .tooManyLeaves: return "The audit policy context contains too many leaf labels."
        case .duplicateLeaf: return "The audit policy context contains a duplicate leaf label."
        case .invalidLeaf: return "The audit policy context contains an invalid leaf label."
        }
    }
}

/// This context is rebuilt by `LocalClassifierCoordinator` from the active
/// taxonomy and policy catalog immediately before dispatch and rechecked at
/// settlement. A provider may choose only `menuLeafTagIDs`; it never receives
/// the full taxonomy.
public struct AuditPolicyContext: Codable, Equatable, Sendable {
    public static let maximumPolicies = 32
    public static let maximumCriteria = 128
    public static let maximumLeaves = 256
    public static let identifierLimit = 256
    public static let leafNameLimit = 160

    public var requestedPolicyIDs: [String]
    public var policies: [AuditPolicyContextPolicy]
    public var leafLabels: [AuditPolicyContextLeaf]

    public init(
        requestedPolicyIDs: [String],
        policies: [AuditPolicyContextPolicy],
        leafLabels: [AuditPolicyContextLeaf]
    ) throws {
        self.requestedPolicyIDs = requestedPolicyIDs
        self.policies = policies
        self.leafLabels = leafLabels
        try validate()
    }

    public var menuLeafTagIDs: Set<String> { Set(leafLabels.map(\.tagID)) }

    public func validate() throws {
        guard !requestedPolicyIDs.isEmpty else { throw AuditPolicyContextError.noRequestedPolicies }
        guard requestedPolicyIDs.count <= Self.maximumPolicies,
              policies.count <= Self.maximumPolicies else {
            throw AuditPolicyContextError.tooManyPolicies
        }
        guard requestedPolicyIDs == requestedPolicyIDs.sorted(),
              policies.map(\.policyID) == requestedPolicyIDs else {
            throw AuditPolicyContextError.invalidPolicyIdentifier
        }
        guard Set(requestedPolicyIDs).count == requestedPolicyIDs.count else {
            throw AuditPolicyContextError.duplicatePolicy
        }
        for policy in policies {
            guard Self.isBoundedIdentifier(policy.policyID) else {
                throw AuditPolicyContextError.invalidPolicyIdentifier
            }
            let criteria = policy.criterionTagIDs
            guard !policy.includeAnyTagIDs.isEmpty || !policy.includeAllTagIDs.isEmpty,
                  criteria.count <= Self.maximumCriteria,
                  criteria.allSatisfy(Self.isBoundedIdentifier) else {
                throw AuditPolicyContextError.invalidCriteria
            }
        }
        let totalCriteria = policies.reduce(into: 0) { $0 += $1.criterionTagIDs.count }
        guard totalCriteria <= Self.maximumCriteria else {
            throw AuditPolicyContextError.tooManyCriteria
        }
        guard !leafLabels.isEmpty, leafLabels.count <= Self.maximumLeaves else {
            throw AuditPolicyContextError.tooManyLeaves
        }
        guard Set(leafLabels.map(\.tagID)).count == leafLabels.count else {
            throw AuditPolicyContextError.duplicateLeaf
        }
        for leaf in leafLabels {
            guard Self.isBoundedIdentifier(leaf.tagID),
                  !leaf.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  leaf.name.count <= Self.leafNameLimit else {
                throw AuditPolicyContextError.invalidLeaf
            }
        }
    }

    private static func isBoundedIdentifier(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed == value && value.count <= identifierLimit
    }
}

// MARK: - Provider-independent local configuration

/// This enum identifies fixed adapters, not arbitrary endpoints. It has no
/// API-key, endpoint, account, or credential field by design.
public enum AuditProvider: String, Codable, Equatable, Sendable, CaseIterable {
    case googleGemini
    case openAI
    case anthropic
}

public enum AuditReasoningEffort: String, Codable, Equatable, Sendable, CaseIterable {
    case minimal
    case low
    case medium
    case high
}

public enum AuditSelectionMode: String, Codable, Equatable, Sendable, CaseIterable {
    case targetedFalseAllow
    case userMarkedOnly
    case targetedWithRandomSample
}

public enum LocalAuditLearningMode: String, Codable, Equatable, Sendable, CaseIterable {
    case disabled
    /// Only a later, locally validated result may be offered to the existing
    /// personal polishing path. It is never a global/group contribution.
    case localValidatedOnly
}

public enum AuditConfigurationError: Error, Equatable, LocalizedError, Sendable {
    case invalidModelIdentifier
    case invalidOutputTokenCap
    case disabled

    public var errorDescription: String? {
        switch self {
        case .invalidModelIdentifier: return "Audit model identifiers must be non-empty and bounded."
        case .invalidOutputTokenCap: return "Audit output token cap must be within the supported bound."
        case .disabled: return "Personal LLM auditing is disabled."
        }
    }
}

public struct AuditProviderConfiguration: Codable, Equatable, Sendable {
    public static let modelIdentifierLimit = 128
    public static let maximumOutputTokens = 32_768

    public var provider: AuditProvider
    public var modelIdentifier: String
    public var reasoningEffort: AuditReasoningEffort
    public var maximumOutputTokens: Int

    public init(
        provider: AuditProvider,
        modelIdentifier: String,
        reasoningEffort: AuditReasoningEffort,
        maximumOutputTokens: Int
    ) {
        self.provider = provider
        self.modelIdentifier = modelIdentifier
        self.reasoningEffort = reasoningEffort
        self.maximumOutputTokens = maximumOutputTokens
    }

    public func validate() throws {
        let trimmed = modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= Self.modelIdentifierLimit else {
            throw AuditConfigurationError.invalidModelIdentifier
        }
        guard (1...Self.maximumOutputTokens).contains(maximumOutputTokens) else {
            throw AuditConfigurationError.invalidOutputTokenCap
        }
    }
}

public struct LocalAuditConfiguration: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var selectionMode: AuditSelectionMode
    public var provider: AuditProviderConfiguration
    public var budgetLimits: AuditBudgetLimits
    public var localLearningMode: LocalAuditLearningMode

    public init(
        isEnabled: Bool = false,
        selectionMode: AuditSelectionMode = .targetedFalseAllow,
        provider: AuditProviderConfiguration,
        budgetLimits: AuditBudgetLimits,
        localLearningMode: LocalAuditLearningMode = .disabled
    ) {
        self.isEnabled = isEnabled
        self.selectionMode = selectionMode
        self.provider = provider
        self.budgetLimits = budgetLimits
        self.localLearningMode = localLearningMode
    }

    public func validateForSubmission() throws {
        guard isEnabled else { throw AuditConfigurationError.disabled }
        try provider.validate()
        try budgetLimits.validate()
    }
}

// MARK: - Deterministic token and spend accounting

/// Exact money representation for a provider-reported charge. Decimal strings
/// are deliberately avoided so equality and budget checks stay deterministic.
public struct AuditMoney: Codable, Equatable, Sendable, Comparable {
    public static let currencyCodeLength = 3
    public static let maximumMinorUnits: Int64 = 1_000_000_000_000_000

    public var currencyCode: String
    public var minorUnits: Int64

    public init(currencyCode: String, minorUnits: Int64) {
        self.currencyCode = currencyCode.uppercased()
        self.minorUnits = minorUnits
    }

    public static func < (lhs: AuditMoney, rhs: AuditMoney) -> Bool {
        precondition(lhs.currencyCode == rhs.currencyCode, "Cannot compare different audit currencies.")
        return lhs.minorUnits < rhs.minorUnits
    }
}

public struct AuditUsage: Codable, Equatable, Sendable {
    public static let maximumTokenCount = 100_000_000

    public var inputTokens: Int
    public var outputTokens: Int
    /// Provider-reported billed tokens that are neither normal input nor
    /// normal output, for example reasoning/thought tokens. This field keeps
    /// accounting honest when an adapter exposes a total token value that is
    /// larger than `inputTokens + outputTokens`.
    public var otherBilledTokens: Int
    public var spend: AuditMoney?

    public init(inputTokens: Int, outputTokens: Int, otherBilledTokens: Int = 0, spend: AuditMoney? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.otherBilledTokens = otherBilledTokens
        self.spend = spend
    }

    public func totalTokens() throws -> Int {
        guard inputTokens >= 0, outputTokens >= 0, otherBilledTokens >= 0,
              inputTokens <= Self.maximumTokenCount,
              outputTokens <= Self.maximumTokenCount,
              otherBilledTokens <= Self.maximumTokenCount else {
            throw AuditBudgetError.invalidUsage
        }
        let (inputOutput, firstOverflow) = inputTokens.addingReportingOverflow(outputTokens)
        let (total, secondOverflow) = inputOutput.addingReportingOverflow(otherBilledTokens)
        guard !firstOverflow, !secondOverflow, total <= Self.maximumTokenCount else {
            throw AuditBudgetError.invalidUsage
        }
        return total
    }

    public func validate() throws {
        _ = try totalTokens()
        if let spend {
            try AuditBudgetLimits.validate(spend: spend)
        }
    }

    fileprivate func fits(within ceiling: AuditUsage) throws -> Bool {
        guard inputTokens <= ceiling.inputTokens,
              outputTokens <= ceiling.outputTokens,
              otherBilledTokens <= ceiling.otherBilledTokens,
              try totalTokens() <= ceiling.totalTokens() else { return false }
        switch (spend, ceiling.spend) {
        case (.none, .none): return true
        case (.none, .some): return false
        case (.some, .none): return false
        case let (.some(actual), .some(limit)):
            return actual.currencyCode == limit.currencyCode && actual.minorUnits <= limit.minorUnits
        }
    }

    private enum CodingKeys: String, CodingKey {
        case inputTokens, outputTokens, otherBilledTokens, spend
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inputTokens = try container.decode(Int.self, forKey: .inputTokens)
        outputTokens = try container.decode(Int.self, forKey: .outputTokens)
        otherBilledTokens = try container.decodeIfPresent(Int.self, forKey: .otherBilledTokens) ?? 0
        spend = try container.decodeIfPresent(AuditMoney.self, forKey: .spend)
    }
}

/// At least one dimension must be capped. A nil dimension is intentionally
/// absent rather than an implicit unlimited value.
///
/// Token limits are local accounting reservations, not a claim that every
/// provider can hard-cap reasoning or other billed tokens. A completed request
/// that reports more than its reservation is still recorded as actual use and
/// can therefore put later requests over budget; it is never silently dropped.
public enum AuditTokenLimitEnforcement: String, Codable, Equatable, Sendable {
    case localReservationOnly
}

public struct AuditUsageLimit: Codable, Equatable, Sendable {
    public var tokenLimit: Int?
    public var spendLimit: AuditMoney?
    public var tokenLimitEnforcement: AuditTokenLimitEnforcement

    public init(
        tokenLimit: Int? = nil,
        spendLimit: AuditMoney? = nil,
        tokenLimitEnforcement: AuditTokenLimitEnforcement = .localReservationOnly
    ) {
        self.tokenLimit = tokenLimit
        self.spendLimit = spendLimit
        self.tokenLimitEnforcement = tokenLimitEnforcement
    }

    private enum CodingKeys: String, CodingKey {
        case tokenLimit, spendLimit, tokenLimitEnforcement
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tokenLimit = try container.decodeIfPresent(Int.self, forKey: .tokenLimit)
        spendLimit = try container.decodeIfPresent(AuditMoney.self, forKey: .spendLimit)
        tokenLimitEnforcement = try container.decodeIfPresent(AuditTokenLimitEnforcement.self, forKey: .tokenLimitEnforcement) ?? .localReservationOnly
    }
}

public struct AuditBudgetLimits: Codable, Equatable, Sendable {
    public var perRequest: AuditUsageLimit
    public var weekly: AuditUsageLimit
    public var monthly: AuditUsageLimit

    public init(perRequest: AuditUsageLimit, weekly: AuditUsageLimit, monthly: AuditUsageLimit) {
        self.perRequest = perRequest
        self.weekly = weekly
        self.monthly = monthly
    }

    public func validate() throws {
        for limit in [perRequest, weekly, monthly] {
            try Self.validate(limit: limit)
        }
        let currencies = [perRequest.spendLimit, weekly.spendLimit, monthly.spendLimit].compactMap(\.?.currencyCode)
        guard Set(currencies).count <= 1 else { throw AuditBudgetError.currencyMismatch }
    }

    fileprivate static func validate(limit: AuditUsageLimit) throws {
        guard limit.tokenLimit != nil || limit.spendLimit != nil else { throw AuditBudgetError.emptyLimit }
        if let tokenLimit = limit.tokenLimit {
            guard (0...10_000_000).contains(tokenLimit) else { throw AuditBudgetError.invalidLimit }
        }
        if let spendLimit = limit.spendLimit {
            try validate(spend: spendLimit)
        }
    }

    fileprivate static func validate(spend: AuditMoney) throws {
        let code = spend.currencyCode
        guard code.count == AuditMoney.currencyCodeLength,
              code.unicodeScalars.allSatisfy({ (65...90).contains(Int($0.value)) }),
              (0...AuditMoney.maximumMinorUnits).contains(spend.minorUnits) else {
            throw AuditBudgetError.invalidLimit
        }
    }
}

public enum AuditBudgetScope: String, Codable, Equatable, Sendable, CaseIterable {
    case perRequest
    case weekly
    case monthly
}

public struct AuditBudgetViolation: Codable, Equatable, Sendable, Identifiable {
    public var scope: AuditBudgetScope
    public var dimension: String
    public var requested: Int64
    public var limit: Int64

    public var id: String { "\(scope.rawValue):\(dimension)" }

    public init(scope: AuditBudgetScope, dimension: String, requested: Int64, limit: Int64) {
        self.scope = scope
        self.dimension = dimension
        self.requested = requested
        self.limit = limit
    }
}

public struct AuditBudgetAssessment: Codable, Equatable, Sendable {
    public var isAllowed: Bool
    public var violations: [AuditBudgetViolation]

    public init(violations: [AuditBudgetViolation]) {
        self.violations = violations
        self.isAllowed = violations.isEmpty
    }
}

public enum AuditBudgetError: Error, Equatable, LocalizedError, Sendable {
    case invalidUsage
    case invalidLimit
    case emptyLimit
    case currencyMismatch
    case budgetExceeded
    case duplicateAuditID
    case ledgerCapacityExceeded
    case unknownReservation
    case reservationAlreadyFinalized
    case usageExceedsReservation
    case reservationMayHaveBeenSent
    case reservationWasNotSent

    public var errorDescription: String? {
        switch self {
        case .invalidUsage: return "Audit usage is invalid."
        case .invalidLimit: return "Audit budget limits are invalid."
        case .emptyLimit: return "Every audit budget period needs a token or spend cap."
        case .currencyMismatch: return "Audit spend limits must use one currency."
        case .budgetExceeded: return "The audit would exceed a configured local budget."
        case .duplicateAuditID: return "This audit has already been budgeted."
        case .ledgerCapacityExceeded: return "The bounded local audit budget ledger is full."
        case .unknownReservation: return "The audit budget reservation was not found."
        case .reservationAlreadyFinalized: return "The audit budget reservation is already finalized."
        case .usageExceedsReservation: return "Provider usage exceeded the pre-authorized audit budget."
        case .reservationMayHaveBeenSent: return "A possibly sent audit request cannot be cancelled and uncharged automatically."
        case .reservationWasNotSent: return "This audit reservation was not marked as possibly sent."
        }
    }
}

public enum AuditBudgetRecordState: String, Codable, Equatable, Sendable {
    /// Reserved locally before a request is sent. It can still be safely
    /// cancelled and released because no provider dispatch has begun.
    case reserved
    /// The caller marked this reservation immediately before dispatch. It
    /// remains charged while a response is pending.
    case possiblySent
    case settled
    case cancelled
    /// Dispatch may have reached a provider but no attributable response was
    /// obtained. It deliberately continues to consume its reservation until a
    /// later result settles it or a user explicitly reconciles it.
    case uncertain
}

/// A reservation debits its declared maximum until the provider result is
/// settled. This makes an async provider call unable to oversubscribe the
/// weekly/monthly cap between preflight and response handling.
public struct AuditBudgetRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    /// A distinct request attempt identifier. Older records used the candidate
    /// identifier here; `candidateAuditID` preserves that compatibility while
    /// allowing a cancelled/uncertain candidate to be retried safely.
    public var auditID: UUID
    public var candidateAuditID: UUID
    public var reservedAtMilliseconds: Int64
    public var usageCeiling: AuditUsage
    public var settledUsage: AuditUsage?
    public var state: AuditBudgetRecordState

    public init(
        id: UUID = UUID(),
        auditID: UUID,
        candidateAuditID: UUID? = nil,
        reservedAtMilliseconds: Int64,
        usageCeiling: AuditUsage,
        settledUsage: AuditUsage? = nil,
        state: AuditBudgetRecordState = .reserved
    ) {
        self.id = id
        self.auditID = auditID
        self.candidateAuditID = candidateAuditID ?? auditID
        self.reservedAtMilliseconds = reservedAtMilliseconds
        self.usageCeiling = usageCeiling
        self.settledUsage = settledUsage
        self.state = state
    }

    fileprivate var effectiveUsage: AuditUsage? {
        switch state {
        case .reserved, .possiblySent, .uncertain: return usageCeiling
        case .settled: return settledUsage
        case .cancelled: return nil
        }
    }

    /// A reservation is a conservative local estimate. This exposes an actual
    /// provider overage instead of pretending the provider had a hard thought-
    /// token cap or discarding the cost from later budget accounting.
    public var settledUsageExceededReservation: Bool {
        guard state == .settled, let settledUsage else { return false }
        return (try? !settledUsage.fits(within: usageCeiling)) ?? true
    }

    private enum CodingKeys: String, CodingKey {
        case id, auditID, candidateAuditID, reservedAtMilliseconds, usageCeiling, settledUsage, state
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        auditID = try container.decode(UUID.self, forKey: .auditID)
        candidateAuditID = try container.decodeIfPresent(UUID.self, forKey: .candidateAuditID) ?? auditID
        reservedAtMilliseconds = try container.decode(Int64.self, forKey: .reservedAtMilliseconds)
        usageCeiling = try container.decode(AuditUsage.self, forKey: .usageCeiling)
        settledUsage = try container.decodeIfPresent(AuditUsage.self, forKey: .settledUsage)
        state = try container.decode(AuditBudgetRecordState.self, forKey: .state)
    }
}

public struct AuditBudgetReservation: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    /// The distinct attempt ID, retained under the historic `auditID` spelling
    /// for source compatibility.
    public var auditID: UUID
    public var candidateAuditID: UUID
    public var reservedAtMilliseconds: Int64
    public var usageCeiling: AuditUsage

    public init(id: UUID, auditID: UUID, candidateAuditID: UUID? = nil, reservedAtMilliseconds: Int64, usageCeiling: AuditUsage) {
        self.id = id
        self.auditID = auditID
        self.candidateAuditID = candidateAuditID ?? auditID
        self.reservedAtMilliseconds = reservedAtMilliseconds
        self.usageCeiling = usageCeiling
    }
}

public struct AuditBudgetWindow: Codable, Equatable, Sendable {
    public var scope: AuditBudgetScope
    public var startMilliseconds: Int64
    public var endMilliseconds: Int64

    public init(scope: AuditBudgetScope, startMilliseconds: Int64, endMilliseconds: Int64) {
        self.scope = scope
        self.startMilliseconds = startMilliseconds
        self.endMilliseconds = endMilliseconds
    }

    public static func containing(_ timestampMilliseconds: Int64, scope: AuditBudgetScope) -> AuditBudgetWindow {
        precondition(timestampMilliseconds >= 0, "Audit timestamps must be non-negative.")
        switch scope {
        case .perRequest:
            return .init(scope: scope, startMilliseconds: timestampMilliseconds, endMilliseconds: timestampMilliseconds)
        case .weekly:
            var calendar = Calendar(identifier: .iso8601)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let date = Date(timeIntervalSince1970: TimeInterval(timestampMilliseconds) / 1_000)
            let interval = calendar.dateInterval(of: .weekOfYear, for: date)!
            return .init(scope: scope, startMilliseconds: milliseconds(interval.start), endMilliseconds: milliseconds(interval.end))
        case .monthly:
            var calendar = Calendar(identifier: .gregorian)
            calendar.locale = Locale(identifier: "en_US_POSIX")
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let date = Date(timeIntervalSince1970: TimeInterval(timestampMilliseconds) / 1_000)
            let interval = calendar.dateInterval(of: .month, for: date)!
            return .init(scope: scope, startMilliseconds: milliseconds(interval.start), endMilliseconds: milliseconds(interval.end))
        }
    }

    public func contains(_ timestampMilliseconds: Int64) -> Bool {
        timestampMilliseconds >= startMilliseconds && timestampMilliseconds < endMilliseconds
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded(.towardZero))
    }
}

public struct AuditBudgetLedger: Codable, Equatable, Sendable {
    public static let defaultMaximumRecords = 2_048
    public static let maximumRecordLimit = 20_000

    public var records: [AuditBudgetRecord]
    public var maximumRecords: Int

    public init(records: [AuditBudgetRecord] = [], maximumRecords: Int = Self.defaultMaximumRecords) {
        self.records = records
        self.maximumRecords = maximumRecords
    }

    public func validate() throws {
        guard (1...Self.maximumRecordLimit).contains(maximumRecords), records.count <= maximumRecords else {
            throw AuditBudgetError.ledgerCapacityExceeded
        }
        var auditIDs = Set<UUID>()
        var recordIDs = Set<UUID>()
        for record in records {
            guard record.reservedAtMilliseconds >= 0 else { throw AuditBudgetError.invalidUsage }
            try record.usageCeiling.validate()
            if let settled = record.settledUsage { try settled.validate() }
            guard auditIDs.insert(record.auditID).inserted else { throw AuditBudgetError.duplicateAuditID }
            guard recordIDs.insert(record.id).inserted else { throw AuditBudgetError.invalidUsage }
            switch record.state {
            case .reserved, .possiblySent, .uncertain:
                guard record.settledUsage == nil else { throw AuditBudgetError.invalidUsage }
            case .settled:
                guard let settled = record.settledUsage else {
                    throw AuditBudgetError.invalidUsage
                }
                try settled.validate()
            case .cancelled where record.settledUsage != nil:
                throw AuditBudgetError.invalidUsage
            default:
                break
            }
        }
    }

    public func assess(
        auditID: UUID,
        proposedUsage: AuditUsage,
        limits: AuditBudgetLimits,
        at timestampMilliseconds: Int64
    ) throws -> AuditBudgetAssessment {
        guard timestampMilliseconds >= 0 else { throw AuditBudgetError.invalidUsage }
        try proposedUsage.validate()
        try limits.validate()
        if records.contains(where: { $0.auditID == auditID }) { throw AuditBudgetError.duplicateAuditID }

        var budgetViolations = makeViolations(for: proposedUsage, accumulated: .zero, limit: limits.perRequest, scope: .perRequest)
        let weeklyWindow = AuditBudgetWindow.containing(timestampMilliseconds, scope: .weekly)
        budgetViolations += makeViolations(
            for: proposedUsage,
            accumulated: try totalUsage(in: weeklyWindow),
            limit: limits.weekly,
            scope: .weekly
        )
        let monthlyWindow = AuditBudgetWindow.containing(timestampMilliseconds, scope: .monthly)
        budgetViolations += makeViolations(
            for: proposedUsage,
            accumulated: try totalUsage(in: monthlyWindow),
            limit: limits.monthly,
            scope: .monthly
        )
        return .init(violations: budgetViolations)
    }

    /// The effective local token charge for a fixed calendar window. A settled
    /// request contributes the provider-reported total; an in-flight or
    /// uncertain request contributes its conservative reservation; a cancelled
    /// pre-dispatch request contributes nothing. This is suitable for a local
    /// budget display and deliberately has no provider/network semantics.
    public func effectiveTokenCount(in window: AuditBudgetWindow) throws -> Int64 {
        try totalUsage(in: window).tokens
    }

    public mutating func reserve(
        auditID: UUID,
        candidateAuditID: UUID? = nil,
        usageCeiling: AuditUsage,
        limits: AuditBudgetLimits,
        at timestampMilliseconds: Int64
    ) throws -> AuditBudgetReservation {
        guard records.count < maximumRecords else { throw AuditBudgetError.ledgerCapacityExceeded }
        let assessment = try assess(auditID: auditID, proposedUsage: usageCeiling, limits: limits, at: timestampMilliseconds)
        guard assessment.isAllowed else { throw AuditBudgetError.budgetExceeded }
        let record = AuditBudgetRecord(
            auditID: auditID,
            candidateAuditID: candidateAuditID,
            reservedAtMilliseconds: timestampMilliseconds,
            usageCeiling: usageCeiling
        )
        records.append(record)
        return .init(
            id: record.id,
            auditID: auditID,
            candidateAuditID: record.candidateAuditID,
            reservedAtMilliseconds: timestampMilliseconds,
            usageCeiling: usageCeiling
        )
    }

    /// Mark this reservation just before a provider call. Once this happens,
    /// cancellation must not release the reservation because the provider may
    /// have received (and billed) the request even if the client sees an error.
    public mutating func markPossiblySent(reservationID: UUID) throws {
        guard let index = records.firstIndex(where: { $0.id == reservationID }) else {
            throw AuditBudgetError.unknownReservation
        }
        guard records[index].state == .reserved else { throw AuditBudgetError.reservationAlreadyFinalized }
        records[index].state = .possiblySent
    }

    /// Preserve a conservative charge after a timeout, cancellation, malformed
    /// response, or other outcome where dispatch may already have occurred.
    /// A late attributable result may still settle this record accurately.
    public mutating func markUncertain(reservationID: UUID) throws {
        guard let index = records.firstIndex(where: { $0.id == reservationID }) else {
            throw AuditBudgetError.unknownReservation
        }
        guard records[index].state == .possiblySent else {
            if records[index].state == .reserved {
                throw AuditBudgetError.reservationWasNotSent
            }
            throw AuditBudgetError.reservationAlreadyFinalized
        }
        records[index].state = .uncertain
    }

    public mutating func settle(reservationID: UUID, actualUsage: AuditUsage) throws {
        try actualUsage.validate()
        guard let index = records.firstIndex(where: { $0.id == reservationID }) else {
            throw AuditBudgetError.unknownReservation
        }
        guard [.reserved, .possiblySent, .uncertain].contains(records[index].state) else {
            throw AuditBudgetError.reservationAlreadyFinalized
        }
        // This is intentionally not a `fits(within:)` guard. Providers can
        // bill unbounded reasoning/other tokens even when output is capped.
        // Persist the actual reported usage so it affects all later budget
        // assessments rather than silently disappearing after dispatch.
        records[index].settledUsage = actualUsage
        records[index].state = .settled
    }

    public mutating func cancel(reservationID: UUID) throws {
        guard let index = records.firstIndex(where: { $0.id == reservationID }) else {
            throw AuditBudgetError.unknownReservation
        }
        guard records[index].state == .reserved else {
            if [.possiblySent, .uncertain].contains(records[index].state) {
                throw AuditBudgetError.reservationMayHaveBeenSent
            }
            throw AuditBudgetError.reservationAlreadyFinalized
        }
        records[index].state = .cancelled
    }

    /// Explicit, deterministic retention. Active reservations are never pruned.
    /// Callers choose the cutoff after they no longer need old local history.
    public mutating func discardFinalizedRecords(before timestampMilliseconds: Int64) {
        records.removeAll {
            [.settled, .cancelled].contains($0.state) && $0.reservedAtMilliseconds < timestampMilliseconds
        }
    }

    private func totalUsage(in window: AuditBudgetWindow) throws -> AccumulatedUsage {
        var total = AccumulatedUsage.zero
        for record in records where window.contains(record.reservedAtMilliseconds) {
            guard let usage = record.effectiveUsage else { continue }
            total = try total.adding(usage)
        }
        return total
    }

    private func makeViolations(
        for proposed: AuditUsage,
        accumulated: AccumulatedUsage,
        limit: AuditUsageLimit,
        scope: AuditBudgetScope
    ) -> [AuditBudgetViolation] {
        var result: [AuditBudgetViolation] = []
        let proposedTokens = Int64((try? proposed.totalTokens()) ?? Int.max)
        let requestedTokens = accumulated.tokens.saturatingAdd(proposedTokens)
        if let tokenLimit = limit.tokenLimit, requestedTokens > Int64(tokenLimit) {
            result.append(.init(scope: scope, dimension: "tokens", requested: requestedTokens, limit: Int64(tokenLimit)))
        }

        if let spendLimit = limit.spendLimit {
            let proposedSpend = proposed.spend
            guard let proposedSpend, proposedSpend.currencyCode == spendLimit.currencyCode else {
                result.append(.init(scope: scope, dimension: "spend", requested: Int64.max, limit: spendLimit.minorUnits))
                return result
            }
            let existingSpend = accumulated.spend(for: spendLimit.currencyCode)
            let requestedSpend = existingSpend.saturatingAdd(proposedSpend.minorUnits)
            if requestedSpend > spendLimit.minorUnits {
                result.append(.init(scope: scope, dimension: "spend", requested: requestedSpend, limit: spendLimit.minorUnits))
            }
        }
        return result
    }
}

private struct AccumulatedUsage {
    var tokens: Int64
    var spendByCurrency: [String: Int64]

    static let zero = AccumulatedUsage(tokens: 0, spendByCurrency: [:])

    func adding(_ usage: AuditUsage) throws -> AccumulatedUsage {
        let tokenTotal = Int64(try usage.totalTokens())
        var next = self
        next.tokens = next.tokens.saturatingAdd(tokenTotal)
        if let spend = usage.spend {
            next.spendByCurrency[spend.currencyCode] = (next.spendByCurrency[spend.currencyCode] ?? 0).saturatingAdd(spend.minorUnits)
        }
        return next
    }

    func spend(for currencyCode: String) -> Int64 { spendByCurrency[currencyCode] ?? 0 }
}

private extension Int64 {
    func saturatingAdd(_ other: Int64) -> Int64 {
        let (value, overflow) = addingReportingOverflow(other)
        guard overflow else { return value }
        return other >= 0 ? .max : .min
    }
}

// MARK: - Request/result validation and attribution

public enum LocalAuditRequestError: Error, Equatable, LocalizedError, Sendable {
    case ineligibleEntry
    case auditIdentifierMismatch
    case invalidPolicyContext
    case ceilingExceedsModelOutputCap
    case ceilingExceedsConfiguredBudget
    case invalidUsageCeiling

    public var errorDescription: String? {
        switch self {
        case .ineligibleEntry: return "This entry is not eligible for a local audit."
        case .auditIdentifierMismatch: return "The audit request identifier does not match its audited entry."
        case .invalidPolicyContext: return "The audit request policy context is invalid."
        case .ceilingExceedsModelOutputCap: return "The audit usage ceiling exceeds the configured output token cap."
        case .ceilingExceedsConfiguredBudget: return "The audit usage ceiling exceeds a configured local budget."
        case .invalidUsageCeiling: return "The audit usage ceiling is invalid."
        }
    }
}

/// A provider adapter may send only this data shape. It contains no API key,
/// endpoint, prompt override, browsing URL, tool grant, or policy mutation.
public struct LocalAuditRequest: Codable, Equatable, Sendable, Identifiable {
    /// Stable local candidate identifier. Results use it to associate one
    /// review finding with the entry the person may later confirm.
    public var auditID: UUID
    /// Distinct provider-request attempt identifier. A candidate may retry
    /// after a safe pre-dispatch cancellation or an uncertain outcome without
    /// confusing a late result from an older attempt.
    public var attemptID: UUID
    public var candidate: AuditedEntry
    /// Generated from the active local taxonomy/policy catalog by the
    /// coordinator. A direct test/adapter request may omit it, but the
    /// coordinator never dispatches or settles an unscoped request.
    public var policyContext: AuditPolicyContext?
    public var configuration: LocalAuditConfiguration
    public var usageCeiling: AuditUsage
    public var requestedAtMilliseconds: Int64

    public var id: UUID { auditID }

    public init(
        candidate: AuditedEntry,
        policyContext: AuditPolicyContext? = nil,
        configuration: LocalAuditConfiguration,
        usageCeiling: AuditUsage,
        requestedAtMilliseconds: Int64,
        attemptID: UUID? = nil
    ) throws {
        guard requestedAtMilliseconds >= 0 else { throw LocalAuditRequestError.invalidUsageCeiling }
        self.auditID = candidate.auditID
        self.attemptID = attemptID ?? candidate.auditID
        self.candidate = candidate
        self.policyContext = policyContext
        self.configuration = configuration
        self.usageCeiling = usageCeiling
        self.requestedAtMilliseconds = requestedAtMilliseconds
        try validate()
    }

    public func validate() throws {
        guard requestedAtMilliseconds >= 0 else { throw LocalAuditRequestError.invalidUsageCeiling }
        guard auditID == candidate.auditID else { throw LocalAuditRequestError.auditIdentifierMismatch }
        try candidate.validate()
        if let policyContext {
            do {
                try policyContext.validate()
            } catch {
                throw LocalAuditRequestError.invalidPolicyContext
            }
        }
        guard candidate.eligibility.isEligible else { throw LocalAuditRequestError.ineligibleEntry }
        try configuration.validateForSubmission()
        try usageCeiling.validate()
        guard usageCeiling.outputTokens <= configuration.provider.maximumOutputTokens else {
            throw LocalAuditRequestError.ceilingExceedsModelOutputCap
        }
        let preflight = try AuditBudgetLedger(maximumRecords: 1).assess(
            auditID: auditID,
            proposedUsage: usageCeiling,
            limits: configuration.budgetLimits,
            at: requestedAtMilliseconds
        )
        guard preflight.isAllowed else { throw LocalAuditRequestError.ceilingExceedsConfiguredBudget }
    }
}

public enum AuditFinding: String, Codable, Equatable, Sendable, CaseIterable {
    case noPolicyIssue
    case potentialFalseAllow
    case potentialFalseDimOrBlock
    case insufficientEvidence
}

public struct AuditResultAttribution: Codable, Equatable, Sendable {
    public var auditID: UUID
    public var attemptID: UUID
    public var provider: AuditProvider
    public var modelIdentifier: String
    public var reasoningEffort: AuditReasoningEffort
    public var evidenceDigest: String
    public var completedAtMilliseconds: Int64
    public var responseSchemaVersion: Int

    public init(
        auditID: UUID,
        attemptID: UUID? = nil,
        provider: AuditProvider,
        modelIdentifier: String,
        reasoningEffort: AuditReasoningEffort,
        evidenceDigest: String,
        completedAtMilliseconds: Int64,
        responseSchemaVersion: Int = 1
    ) {
        self.auditID = auditID
        self.attemptID = attemptID ?? auditID
        self.provider = provider
        self.modelIdentifier = modelIdentifier
        self.reasoningEffort = reasoningEffort
        self.evidenceDigest = evidenceDigest
        self.completedAtMilliseconds = completedAtMilliseconds
        self.responseSchemaVersion = responseSchemaVersion
    }

    private enum CodingKeys: String, CodingKey {
        case auditID, attemptID, provider, modelIdentifier, reasoningEffort, evidenceDigest, completedAtMilliseconds, responseSchemaVersion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        auditID = try container.decode(UUID.self, forKey: .auditID)
        attemptID = try container.decodeIfPresent(UUID.self, forKey: .attemptID) ?? auditID
        provider = try container.decode(AuditProvider.self, forKey: .provider)
        modelIdentifier = try container.decode(String.self, forKey: .modelIdentifier)
        reasoningEffort = try container.decode(AuditReasoningEffort.self, forKey: .reasoningEffort)
        evidenceDigest = try container.decode(String.self, forKey: .evidenceDigest)
        completedAtMilliseconds = try container.decode(Int64.self, forKey: .completedAtMilliseconds)
        responseSchemaVersion = try container.decodeIfPresent(Int.self, forKey: .responseSchemaVersion) ?? 1
    }
}

/// This is still untrusted provider output. Only `AuditResultValidator` turns
/// it into a locally attributable result.
public struct UnvalidatedAuditResult: Codable, Equatable, Sendable {
    public static let maximumLeafTags = 16
    public static let rationaleLimit = 4_000

    public var finding: AuditFinding
    public var leafTagIDs: [String]
    public var confidence: Double?
    public var rationale: String
    public var attribution: AuditResultAttribution
    public var usage: AuditUsage

    public init(
        finding: AuditFinding,
        leafTagIDs: [String],
        confidence: Double?,
        rationale: String,
        attribution: AuditResultAttribution,
        usage: AuditUsage
    ) {
        self.finding = finding
        self.leafTagIDs = leafTagIDs
        self.confidence = confidence
        self.rationale = rationale
        self.attribution = attribution
        self.usage = usage
    }
}

public struct ValidatedAuditResult: Codable, Equatable, Sendable, Identifiable {
    public var auditID: UUID
    public var finding: AuditFinding
    public var leafTagIDs: [String]
    public var confidence: Double?
    public var rationale: String
    public var attribution: AuditResultAttribution
    public var usage: AuditUsage
    /// Set by the local coordinator after it validates the exact candidate
    /// currently bound to a cache row. Legacy/provider-only results remain
    /// decodable but cannot be applied or dispatched through the coordinator.
    public var modelIdentity: ActiveModelIdentity?

    public var id: UUID { auditID }

    fileprivate init(from result: UnvalidatedAuditResult) {
        self.auditID = result.attribution.auditID
        self.finding = result.finding
        self.leafTagIDs = result.leafTagIDs
        self.confidence = result.confidence
        self.rationale = result.rationale
        self.attribution = result.attribution
        self.usage = result.usage
        self.modelIdentity = nil
    }
}

public enum AuditResultValidationError: Error, Equatable, LocalizedError, Sendable {
    case attributionMismatch
    case staleResult
    case invalidSchemaVersion
    case invalidLeafTags
    case invalidConfidence
    case invalidRationale
    case invalidFindingForDecision
    case insufficientEvidenceMustNotLabel
    case usageExceedsRequestCeiling

    public var errorDescription: String? {
        switch self {
        case .attributionMismatch: return "Audit result attribution does not match the local request."
        case .staleResult: return "Audit result predates the local request."
        case .invalidSchemaVersion: return "Audit result uses an unsupported response schema."
        case .invalidLeafTags: return "Audit result contains invalid leaf tags."
        case .invalidConfidence: return "Audit result confidence is invalid."
        case .invalidRationale: return "Audit result rationale is invalid."
        case .invalidFindingForDecision: return "Audit finding does not match the local decision being reviewed."
        case .insufficientEvidenceMustNotLabel: return "An insufficient-evidence result may not return labels."
        case .usageExceedsRequestCeiling: return "Audit usage exceeds the locally pre-authorized request ceiling."
        }
    }
}

public struct AuditResultValidator: Sendable {
    public init() {}

    public func validate(
        _ result: UnvalidatedAuditResult,
        for request: LocalAuditRequest,
        allowedLeafTagIDs: Set<String>
    ) throws -> ValidatedAuditResult {
        try request.validate()
        let attribution = result.attribution
        guard attribution.responseSchemaVersion == 1 else { throw AuditResultValidationError.invalidSchemaVersion }
        guard attribution.auditID == request.auditID,
              attribution.attemptID == request.attemptID,
              attribution.provider == request.configuration.provider.provider,
              attribution.modelIdentifier == request.configuration.provider.modelIdentifier,
              attribution.reasoningEffort == request.configuration.provider.reasoningEffort,
              attribution.evidenceDigest == request.candidate.evidence.evidenceDigest else {
            throw AuditResultValidationError.attributionMismatch
        }
        guard attribution.completedAtMilliseconds >= request.requestedAtMilliseconds else {
            throw AuditResultValidationError.staleResult
        }
        let permittedLeaves = request.policyContext?.menuLeafTagIDs ?? allowedLeafTagIDs
        guard result.leafTagIDs.count <= UnvalidatedAuditResult.maximumLeafTags,
              Set(result.leafTagIDs).count == result.leafTagIDs.count,
              result.leafTagIDs.allSatisfy({ permittedLeaves.contains($0) }) else {
            throw AuditResultValidationError.invalidLeafTags
        }
        if let confidence = result.confidence {
            guard confidence.isFinite, (0...1).contains(confidence) else {
                throw AuditResultValidationError.invalidConfidence
            }
        }
        let trimmedRationale = result.rationale.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRationale.isEmpty, trimmedRationale.count <= UnvalidatedAuditResult.rationaleLimit else {
            throw AuditResultValidationError.invalidRationale
        }
        try result.usage.validate()
        // `usageCeiling` is a local reservation. It is not treated as a hard
        // provider cap because reasoning/other billed tokens may exceed an API
        // output limit. Settlement records such an overage explicitly.
        switch result.finding {
        case .potentialFalseAllow:
            guard request.candidate.localResult.strongestAction == .allow else {
                throw AuditResultValidationError.invalidFindingForDecision
            }
            guard !result.leafTagIDs.isEmpty else { throw AuditResultValidationError.invalidLeafTags }
        case .potentialFalseDimOrBlock:
            guard request.candidate.localResult.strongestAction != .allow else {
                throw AuditResultValidationError.invalidFindingForDecision
            }
            guard !result.leafTagIDs.isEmpty else { throw AuditResultValidationError.invalidLeafTags }
        case .insufficientEvidence:
            guard result.leafTagIDs.isEmpty else { throw AuditResultValidationError.insufficientEvidenceMustNotLabel }
        case .noPolicyIssue:
            break
        }
        return .init(from: result)
    }
}

// MARK: - Redacted local diagnostic export

/// The export deliberately carries only non-identifying counts, local model
/// metadata and audit accounting. It has no raw evidence, stable evidence
/// digest, entry/source/audit identifiers (including hashes), browser URLs,
/// provider credential, or request content.
public struct RedactedAuditEvidenceSummary: Codable, Equatable, Sendable {
    public var platform: String
    public var surface: EntrySurface
    public var hasTitle: Bool
    public var hasText: Bool
    public var hasSummary: Bool
    public var suppliedTagCount: Int
    public var metadataKeyCount: Int

    public init(evidence: UntrustedQuotedEvidence) {
        let entry = evidence.quotedEntry
        self.platform = entry.platform
        self.surface = entry.surface
        self.hasTitle = !(entry.evidence.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        self.hasText = !(entry.evidence.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        self.hasSummary = !(entry.evidence.summary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        self.suppliedTagCount = entry.evidence.suppliedTags.count
        self.metadataKeyCount = entry.evidence.metadata.count
    }

}

/// Provider rationale is intentionally excluded: a model can repeat sensitive
/// quoted text in its explanation even when the application never asked it to.
public struct RedactedAuditResultSummary: Codable, Equatable, Sendable {
    public var finding: AuditFinding
    public var leafTagIDs: [String]
    public var confidence: Double?
    public var provider: AuditProvider
    public var modelIdentifier: String
    public var reasoningEffort: AuditReasoningEffort
    public var completedAtMilliseconds: Int64
    public var usage: AuditUsage

    public init(result: ValidatedAuditResult) {
        finding = result.finding
        leafTagIDs = result.leafTagIDs
        confidence = result.confidence
        provider = result.attribution.provider
        modelIdentifier = result.attribution.modelIdentifier
        reasoningEffort = result.attribution.reasoningEffort
        completedAtMilliseconds = result.attribution.completedAtMilliseconds
        usage = result.usage
    }
}

public struct RedactedAuditDiagnosticRecord: Codable, Equatable, Sendable, Identifiable {
    /// Local ordinal, scoped to this one export. It cannot correlate an entry
    /// across exports or be reversed into an audit/entry/source identifier.
    public var recordOrdinal: Int
    public var createdAtMilliseconds: Int64
    public var intent: AuditIntent
    public var eligibility: AuditEligibility
    public var risk: AuditRiskRecord
    public var evidence: RedactedAuditEvidenceSummary
    public var localAction: PresentationAction
    public var selectedLeafTagIDs: [String]
    public var packageID: String
    public var modelVersion: String
    public var result: RedactedAuditResultSummary?

    public var id: String { "record-\(recordOrdinal)" }

    public init(recordOrdinal: Int, candidate: AuditedEntry, result: ValidatedAuditResult?) {
        self.recordOrdinal = recordOrdinal
        self.createdAtMilliseconds = candidate.createdAtMilliseconds
        self.intent = candidate.intent
        self.eligibility = candidate.eligibility
        self.risk = candidate.risk
        self.evidence = .init(evidence: candidate.evidence)
        self.localAction = candidate.localResult.strongestAction
        self.selectedLeafTagIDs = candidate.localResult.selectedLeafTagIDs
        self.packageID = candidate.localResult.packageID
        self.modelVersion = candidate.localResult.modelVersion
        self.result = result.map(RedactedAuditResultSummary.init)
    }
}

public struct RedactedAuditBudgetSummary: Codable, Equatable, Sendable {
    public var recordCount: Int
    public var reservedCount: Int
    public var possiblySentCount: Int
    public var uncertainCount: Int
    public var settledCount: Int
    public var cancelledCount: Int
    /// Number of settled records whose actual provider-reported usage was
    /// above the conservative local reservation.
    public var settledOverReservationCount: Int
    /// Positive token difference for those records. Spend overages remain
    /// represented by the count even if the provider did not report a spend.
    public var settledOverReservationTokens: Int64
    public var maximumRecords: Int

    public init(ledger: AuditBudgetLedger) {
        recordCount = ledger.records.count
        reservedCount = ledger.records.filter { $0.state == .reserved }.count
        possiblySentCount = ledger.records.filter { $0.state == .possiblySent }.count
        uncertainCount = ledger.records.filter { $0.state == .uncertain }.count
        settledCount = ledger.records.filter { $0.state == .settled }.count
        cancelledCount = ledger.records.filter { $0.state == .cancelled }.count
        let overReservations = ledger.records.filter(\.settledUsageExceededReservation)
        settledOverReservationCount = overReservations.count
        settledOverReservationTokens = overReservations.reduce(into: Int64(0)) { total, record in
            guard let settled = record.settledUsage,
                  let actual = try? settled.totalTokens(),
                  let reserved = try? record.usageCeiling.totalTokens() else { return }
            total = total.saturatingAdd(Int64(max(0, actual - reserved)))
        }
        maximumRecords = ledger.maximumRecords
    }
}

public struct RedactedAuditDiagnosticExport: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public var schemaVersion: Int
    public var generatedAtMilliseconds: Int64
    public var records: [RedactedAuditDiagnosticRecord]
    public var budget: RedactedAuditBudgetSummary

    public init(
        generatedAtMilliseconds: Int64,
        candidates: [AuditedEntry],
        results: [ValidatedAuditResult],
        ledger: AuditBudgetLedger
    ) {
        self.schemaVersion = Self.schemaVersion
        self.generatedAtMilliseconds = generatedAtMilliseconds
        let resultByID = Dictionary(uniqueKeysWithValues: results.map { ($0.auditID, $0) })
        self.records = candidates.enumerated().map { index, candidate in
            .init(recordOrdinal: index + 1, candidate: candidate, result: resultByID[candidate.auditID])
        }
        self.budget = .init(ledger: ledger)
    }
}

private extension SHA256Digest {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
