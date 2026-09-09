import Foundation

/// A data-minimized entity that may be sent to configured research providers.
/// Raw titles, summaries, body text, URLs, and platform-scoped opaque creator
/// identifiers cannot be represented by this type.
public struct ResearchSubject: Equatable, Sendable {
    public static let maximumCharacters = 120
    public static let maximumWords = 8

    public let kind: KnowledgeEntryKind
    public let subject: String

    public init?(kind: KnowledgeEntryKind, subject rawSubject: String) {
        guard let sanitized = Self.sanitize(kind: kind, value: rawSubject) else { return nil }
        self.kind = kind
        self.subject = sanitized
    }

    public var key: String { KnowledgeEntry.key(kind: kind, subject: subject) }

    public static func sanitize(kind: KnowledgeEntryKind, value: String) -> String? {
        var cleaned = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        let pairedQuotes: [(Character, Character)] = [
            ("\"", "\""), ("'", "'"), ("“", "”"), ("‘", "’"),
        ]
        if let first = cleaned.first, let last = cleaned.last,
           pairedQuotes.contains(where: { $0.0 == first && $0.1 == last }), cleaned.count > 1 {
            cleaned.removeFirst()
            cleaned.removeLast()
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if kind == .creator, let marker = cleaned.range(of: ":handle:", options: .caseInsensitive) {
            cleaned = String(cleaned[marker.upperBound...])
        }

        let lowercase = cleaned.lowercased()
        let words = cleaned.split(whereSeparator: \.isWhitespace)
        guard !cleaned.isEmpty,
              cleaned.count <= maximumCharacters,
              words.count <= maximumWords,
              !lowercase.contains("://"),
              !lowercase.hasPrefix("www."),
              !lowercase.contains("\n"),
              !lowercase.contains("\r"),
              cleaned.unicodeScalars.allSatisfy({ $0.properties.generalCategory != .control })
        else { return nil }

        if kind == .creator {
            // Raw channel/account IDs are not acceptable research subjects. A
            // public handle or short human-readable creator name is.
            if cleaned.hasPrefix("@") {
                guard cleaned.count > 1 else { return nil }
            } else {
                guard words.count <= 5,
                      !cleaned.contains(":"),
                      cleaned.range(of: #"^(UC|user:|channel:)"#, options: [.regularExpression, .caseInsensitive]) == nil
                else { return nil }
            }
        } else {
            // A noun phrase may contain title punctuation, but a sentence is
            // outside the consented entity-only data boundary.
            guard !cleaned.hasSuffix("?"), !cleaned.hasSuffix("!") else { return nil }
        }
        return cleaned
    }
}

/// Local routing metadata plus already-sanitized subjects. It deliberately has
/// no title/summary/body fields, so the remote executor cannot leak them.
public struct ResearchTask: Equatable, Sendable {
    public static let maximumSubjects = 3

    public let classifierTypeID: String
    public let platformID: String
    public let entryID: String
    public let creatorID: String
    public let subjects: [ResearchSubject]

    public init(
        classifierTypeID: String,
        platformID: String,
        entryID: String,
        creatorID: String,
        subjects: [ResearchSubject]
    ) {
        self.classifierTypeID = String(classifierTypeID.prefix(256))
        self.platformID = platformID
        self.entryID = entryID
        self.creatorID = creatorID
        var seen = Set<String>()
        self.subjects = Array(subjects.filter { seen.insert($0.key).inserted }.prefix(Self.maximumSubjects))
    }
}

public struct GroundedResearchProviderConfiguration: Sendable {
    public var searchMode: ResearchSearchMode
    public var llmProfile: APIKeyProviderProfile
    public var llmCredential: ProviderCredentialRecord
    public var llmModelIdentifier: String
    /// Required only for `.rawSearchProvider`. In `.providerGrounding` the LLM
    /// provider searches natively, so no separate search provider is used.
    public var webSearchProfile: APIKeyProviderProfile?
    public var webSearchCredential: ProviderCredentialRecord?
    public var maximumOutputTokens: Int
    public var searchResultCount: Int
    public var snippetContextChars: Int

    public init(
        searchMode: ResearchSearchMode = .rawSearchProvider,
        llmProfile: APIKeyProviderProfile,
        llmCredential: ProviderCredentialRecord,
        llmModelIdentifier: String,
        webSearchProfile: APIKeyProviderProfile? = nil,
        webSearchCredential: ProviderCredentialRecord? = nil,
        maximumOutputTokens: Int = 512,
        searchResultCount: Int = ResearchSettings.defaultSearchResultCount,
        snippetContextChars: Int = ResearchSettings.defaultSnippetContextChars
    ) {
        self.searchMode = searchMode
        self.llmProfile = llmProfile
        self.llmCredential = llmCredential
        self.llmModelIdentifier = llmModelIdentifier
        self.webSearchProfile = webSearchProfile
        self.webSearchCredential = webSearchCredential
        self.maximumOutputTokens = min(
            ProviderGenerationProtocol.maximumOutputTokens,
            max(1, maximumOutputTokens)
        )
        self.searchResultCount = min(
            ResearchSettings.maximumSearchResultCount,
            max(1, searchResultCount)
        )
        self.snippetContextChars = min(
            ResearchSettings.maximumSnippetContextChars,
            max(ResearchSettings.minimumSnippetContextChars, snippetContextChars)
        )
    }
}

public struct GroundedResearchResult: Equatable, Sendable {
    public var knowledge: KnowledgeEntry
    /// Missing provider usage is charged conservatively as the requested cap.
    public var chargedTokenCount: Int

    public init(knowledge: KnowledgeEntry, chargedTokenCount: Int) {
        self.knowledge = knowledge
        self.chargedTokenCount = max(0, chargedTokenCount)
    }
}

public struct GroundedResearchExecutor: Sendable {
    public static let requestTimeout: TimeInterval = 30
    private let http: any ProviderHTTPClient

    public init(http: any ProviderHTTPClient) {
        self.http = http
    }

    public func research(
        _ subject: ResearchSubject,
        using configuration: GroundedResearchProviderConfiguration
    ) async throws -> GroundedResearchResult {
        guard let sanitized = ResearchSubject(kind: subject.kind, subject: subject.subject),
              sanitized == subject,
              configuration.llmProfile.type.supportsLLMConfiguration
        else {
            throw GroundedResearchError.invalidConfiguration
        }
        switch configuration.searchMode {
        case .providerGrounding:
            return try await researchViaProviderGrounding(sanitized, using: configuration)
        case .rawSearchProvider:
            return try await researchViaRawSearch(sanitized, using: configuration)
        }
    }

    /// Provider-grounding mode: the LLM provider searches natively (Gemini
    /// google_search, OpenAI/Anthropic web_search) and distills in one call.
    private func researchViaProviderGrounding(
        _ sanitized: ResearchSubject,
        using configuration: GroundedResearchProviderConfiguration
    ) async throws -> GroundedResearchResult {
        guard GroundedGenerationProtocol.supportsProviderGrounding(profile: configuration.llmProfile) else {
            throw GroundedResearchError.invalidConfiguration
        }
        let request = try GroundedGenerationProtocol.prepareGroundedGenerate(
            profile: configuration.llmProfile,
            modelIdentifier: configuration.llmModelIdentifier,
            subject: sanitized.subject,
            kind: sanitized.kind,
            maximumOutputTokens: configuration.maximumOutputTokens
        )
        let response = try await http.send(
            plan: request.plan,
            body: request.body,
            credential: configuration.llmCredential,
            timeout: Self.requestTimeout
        )
        let parsed = try GroundedGenerationProtocol.parseGroundedGeneration(
            response.data,
            format: request.plan.bodyFormat
        )
        let meaning = parsed.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !meaning.isEmpty else { throw GroundedResearchError.emptyMeaning }
        let knowledge = KnowledgeEntry(
            kind: sanitized.kind,
            subject: sanitized.subject,
            meaning: meaning,
            contextTagHints: [],
            sourceURLs: parsed.sourceURLs
        )
        return GroundedResearchResult(
            knowledge: knowledge,
            chargedTokenCount: parsed.usage.tokenCount ?? configuration.maximumOutputTokens
        )
    }

    /// Raw-search mode: a separate search provider supplies snippets, then the
    /// LLM provider distills them.
    private func researchViaRawSearch(
        _ sanitized: ResearchSubject,
        using configuration: GroundedResearchProviderConfiguration
    ) async throws -> GroundedResearchResult {
        guard let webSearchProfile = configuration.webSearchProfile,
              let webSearchCredential = configuration.webSearchCredential,
              webSearchProfile.type.supportsRawWebSearch
        else {
            throw GroundedResearchError.invalidConfiguration
        }

        let search = try RawWebSearchProtocol.prepareSearch(
            profile: webSearchProfile,
            query: sanitized.subject,
            resultCount: configuration.searchResultCount
        )
        let searchResponse = try await http.send(
            plan: search.plan,
            body: search.body,
            credential: webSearchCredential,
            timeout: Self.requestTimeout
        )
        let results = Array(try RawWebSearchProtocol.parseResults(
            searchResponse.data,
            format: search.plan.bodyFormat
        ).prefix(configuration.searchResultCount))

        let unboundedEvidence = results.enumerated().map { index, result in
            "[\(index + 1)] \(result.title)\n\(result.url)\n\(result.snippet)"
        }.joined(separator: "\n\n")
        let evidence = String(unboundedEvidence.prefix(configuration.snippetContextChars))
        let distillPrompt: String
        switch sanitized.kind {
        case .creator:
            distillPrompt = "Distill a short factual description of the named creator or channel from the supplied public web results: who they are and the kinds of topics, genres, or content they are known for. Never assign, suggest, or mention classification tags. Do not infer facts absent from the evidence. Return plain text only."
        case .term:
            distillPrompt = "Distill a short factual description of the named subject from the supplied public web results. Never assign, suggest, or mention classification tags. Do not infer facts absent from the evidence. Return plain text only."
        }
        let generation = try ProviderGenerationProtocol.prepareGenerateText(
            profile: configuration.llmProfile,
            modelIdentifier: configuration.llmModelIdentifier,
            systemPrompt: distillPrompt,
            userPrompt: "Subject: \(sanitized.subject)\n\nPublic web results:\n\(evidence)",
            maximumOutputTokens: configuration.maximumOutputTokens
        )
        let generatedResponse = try await http.send(
            plan: generation.plan,
            body: generation.body,
            credential: configuration.llmCredential,
            timeout: Self.requestTimeout
        )
        let parsed = try ProviderGenerationProtocol.parseGeneratedText(
            generatedResponse.data,
            format: generation.plan.bodyFormat
        )
        let meaning = parsed.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !meaning.isEmpty else { throw GroundedResearchError.emptyMeaning }

        let knowledge = KnowledgeEntry(
            kind: sanitized.kind,
            subject: sanitized.subject,
            meaning: meaning,
            contextTagHints: [],
            sourceURLs: results.map(\.url)
        )
        return GroundedResearchResult(
            knowledge: knowledge,
            chargedTokenCount: parsed.usage.tokenCount ?? configuration.maximumOutputTokens
        )
    }
}

public enum GroundedResearchError: Error, Equatable, LocalizedError, Sendable {
    case invalidConfiguration
    case emptyMeaning

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "The research providers or sanitized subject are invalid."
        case .emptyMeaning: return "The research provider returned no grounded meaning."
        }
    }
}

/// Why a research request failed, reduced to a category the UI can show and
/// the queue can act on. Never carries provider text, so it is safe to persist.
public enum GroundedResearchFailureKind: String, Codable, Equatable, Sendable, CaseIterable {
    case timeout
    case network
    case rateLimited
    case serverError
    case providerRejected
    case invalidConfiguration
    case emptyResponse
    case unknown

    /// Transient failures are retried in place and then parked on a SHORT,
    /// escalating cooldown; everything else waits the configured cooldown.
    public var isTransient: Bool {
        switch self {
        case .timeout, .network, .rateLimited, .serverError: return true
        case .providerRejected, .invalidConfiguration, .emptyResponse, .unknown: return false
        }
    }

    public static func classify(_ error: Error) -> GroundedResearchFailureKind {
        if let research = error as? GroundedResearchError {
            switch research {
            case .invalidConfiguration: return .invalidConfiguration
            case .emptyMeaning: return .emptyResponse
            }
        }
        if let http = error as? ProviderTestHTTPError {
            switch http {
            case .status(let status):
                if status == 429 || status == 408 { return .rateLimited }
                if (500..<600).contains(status) { return .serverError }
                return .providerRejected
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut: return .timeout
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
                 .cannotConnectToHost, .dnsLookupFailed, .internationalRoamingOff,
                 .dataNotAllowed, .secureConnectionFailed:
                return .network
            default: return .unknown
            }
        }
        return .unknown
    }
}

/// Durable negative-cache entry. Successful subjects are deduplicated by the
/// knowledge map; failures need their own persisted cooldown across launches.
/// `failureCount` and `failureKind` are additive (older records decode as one
/// unknown failure) and drive the escalating transient cooldown.
public struct ResearchAttemptRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: String {
        classifierTypeID.map { "\($0)\u{1F}\(subjectKey)" } ?? subjectKey
    }
    public var classifierTypeID: String?
    public var subjectKey: String
    public var lastAttemptAtMilliseconds: Int64
    public var retryAfterMilliseconds: Int64
    public var failureCount: Int
    public var failureKind: GroundedResearchFailureKind?

    public init(
        classifierTypeID: String? = nil,
        subjectKey: String,
        lastAttemptAtMilliseconds: Int64,
        retryAfterMilliseconds: Int64,
        failureCount: Int = 1,
        failureKind: GroundedResearchFailureKind? = nil
    ) {
        self.classifierTypeID = classifierTypeID.map { String($0.prefix(256)) }
        self.subjectKey = String(subjectKey.prefix(ResearchSubject.maximumCharacters + 16))
        self.lastAttemptAtMilliseconds = max(0, lastAttemptAtMilliseconds)
        self.retryAfterMilliseconds = max(self.lastAttemptAtMilliseconds, retryAfterMilliseconds)
        self.failureCount = min(1_000, max(1, failureCount))
        self.failureKind = failureKind
    }

    private enum CodingKeys: String, CodingKey {
        case classifierTypeID, subjectKey, lastAttemptAtMilliseconds, retryAfterMilliseconds, failureCount, failureKind
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            classifierTypeID: try c.decodeIfPresent(String.self, forKey: .classifierTypeID),
            subjectKey: try c.decode(String.self, forKey: .subjectKey),
            lastAttemptAtMilliseconds: try c.decode(Int64.self, forKey: .lastAttemptAtMilliseconds),
            retryAfterMilliseconds: try c.decode(Int64.self, forKey: .retryAfterMilliseconds),
            failureCount: try c.decodeIfPresent(Int.self, forKey: .failureCount) ?? 1,
            failureKind: try c.decodeIfPresent(GroundedResearchFailureKind.self, forKey: .failureKind)
        )
    }

    /// The subject as a human-readable string (the key minus its kind prefix).
    public var displaySubject: String {
        if let separator = subjectKey.firstIndex(of: ":") {
            return String(subjectKey[subjectKey.index(after: separator)...])
        }
        return subjectKey
    }
}

/// Live, in-memory view of the research lane for the UI. Session counters
/// reset on launch; durable cooldown state lives in the persisted attempt
/// records.
public struct GroundedResearchQueueStatus: Equatable, Sendable {
    public struct Failure: Equatable, Sendable {
        public var subjectKey: String
        public var kind: GroundedResearchFailureKind
        public var atMilliseconds: Int64
        public var retryAfterMilliseconds: Int64
        public var failureCount: Int
        public init(subjectKey: String, kind: GroundedResearchFailureKind, atMilliseconds: Int64, retryAfterMilliseconds: Int64, failureCount: Int) {
            self.subjectKey = subjectKey
            self.kind = kind
            self.atMilliseconds = atMilliseconds
            self.retryAfterMilliseconds = retryAfterMilliseconds
            self.failureCount = failureCount
        }
    }

    public var pendingCount = 0
    public var inFlightSubjectKey: String?
    public var succeededCount = 0
    public var failedCount = 0
    public var transientRetryCount = 0
    public var skippedForBudgetCount = 0
    public var skippedForCooldownCount = 0
    public var retryableFailedCount = 0
    public var lastFailure: Failure?
    public var lastSuccessAtMilliseconds: Int64?

    public init() {}
}

public struct GroundedResearchQueueConfiguration: Sendable {
    public var providers: GroundedResearchProviderConfiguration
    public var requestsPerMinute: Int
    public var dailyTokenLimit: Int
    public var failureCooldownMilliseconds: Int64

    public init(
        providers: GroundedResearchProviderConfiguration,
        requestsPerMinute: Int,
        dailyTokenLimit: Int,
        failureCooldownMilliseconds: Int64 = Int64(ResearchSettings.defaultCooldownHours) * 60 * 60 * 1_000
    ) {
        self.providers = providers
        self.requestsPerMinute = min(120, max(1, requestsPerMinute))
        self.dailyTokenLimit = min(10_000_000, max(1, dailyTokenLimit))
        self.failureCooldownMilliseconds = min(
            Int64(ResearchSettings.maximumCooldownHours) * 60 * 60 * 1_000,
            max(60 * 60 * 1_000, failureCooldownMilliseconds)
        )
    }
}

public struct GroundedResearchQueueSnapshot: Sendable {
    public var existingKnowledgeKeys: Set<String>
    public var failedAttempts: [ResearchAttemptRecord]
    public var tokenUsage: [TokenUsageRecord]

    public init(
        existingKnowledgeKeys: Set<String> = [],
        failedAttempts: [ResearchAttemptRecord] = [],
        tokenUsage: [TokenUsageRecord] = []
    ) {
        self.existingKnowledgeKeys = existingKnowledgeKeys
        self.failedAttempts = failedAttempts
        self.tokenUsage = tokenUsage
    }
}

public enum GroundedResearchQueueMutation: Sendable {
    case succeeded(task: ResearchTask, result: GroundedResearchResult, usage: TokenUsageRecord)
    case failed(task: ResearchTask, attempt: ResearchAttemptRecord)
    /// The user asked to retry: drop the persisted cooldown before re-queueing.
    case retryRequested(task: ResearchTask, subjectKey: String)
}

/// Serial, bounded background lane. `enqueue` only appends; all rate limiting,
/// network work, persistence, and callbacks happen in the detached drain.
public actor GroundedResearchQueue {
    public static let maximumPendingSubjects = 32
    public static let researchUsageStatus = "grounded-research"
    /// A transient failure (timeout, network, 429, 5xx) is retried in place
    /// this many times, sleeping `transientRetryDelays[i]` before each retry.
    public static let maximumTransientRetries = 2
    public static let transientRetryDelays: [TimeInterval] = [2, 6]
    /// After the in-place retries, a transient failure parks on a short
    /// cooldown that doubles per consecutive failure (15 min, 30 min, 1 h, …),
    /// never exceeding the configured failure cooldown.
    public static let baseTransientCooldownMilliseconds: Int64 = 15 * 60 * 1_000
    public static let maximumRetryableFailures = 64

    public typealias ConfigurationProvider = @Sendable (ResearchTask) -> GroundedResearchQueueConfiguration?
    public typealias SnapshotProvider = @Sendable (ResearchTask) -> GroundedResearchQueueSnapshot
    public typealias MutationWriter = @Sendable (GroundedResearchQueueMutation) async -> Void
    public typealias Researcher = @Sendable (
        ResearchSubject,
        GroundedResearchProviderConfiguration
    ) async throws -> GroundedResearchResult

    private struct Pending: Sendable {
        let task: ResearchTask
        let subject: ResearchSubject
    }

    private let configurationProvider: ConfigurationProvider
    private let snapshotProvider: SnapshotProvider
    private let mutationWriter: MutationWriter
    private let researcher: Researcher
    private let now: @Sendable () -> Date
    private let sleeper: @Sendable (TimeInterval) async -> Void
    private var pending: [Pending] = []
    private var pendingKeys = Set<String>()
    private var isDraining = false
    private var lastRequestStartedAt: Date?
    private var status = GroundedResearchQueueStatus()
    private var statusObserver: (@Sendable (GroundedResearchQueueStatus) -> Void)?
    /// Subjects that failed this session, kept so "retry now" can re-queue
    /// them without waiting for their video to be classified again.
    private var retryableFailures: [String: Pending] = [:]
    private var retryableFailureOrder: [String] = []

    public init(
        executor: GroundedResearchExecutor,
        configurationProvider: @escaping ConfigurationProvider,
        snapshotProvider: @escaping SnapshotProvider,
        mutationWriter: @escaping MutationWriter
    ) {
        self.init(
            configurationProvider: configurationProvider,
            snapshotProvider: snapshotProvider,
            mutationWriter: mutationWriter,
            researcher: { subject, configuration in
                try await executor.research(subject, using: configuration)
            }
        )
    }

    public init(
        configurationProvider: @escaping ConfigurationProvider,
        snapshotProvider: @escaping SnapshotProvider,
        mutationWriter: @escaping MutationWriter,
        researcher: @escaping Researcher,
        now: @escaping @Sendable () -> Date = { Date() },
        sleeper: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            guard seconds > 0 else { return }
            try? await Task<Never, Never>.sleep(nanoseconds: UInt64(min(seconds, 60) * 1_000_000_000))
        }
    ) {
        self.configurationProvider = configurationProvider
        self.snapshotProvider = snapshotProvider
        self.mutationWriter = mutationWriter
        self.researcher = researcher
        self.now = now
        self.sleeper = sleeper
    }

    /// Returns false only when every subject was already queued or the bounded
    /// lane was full. The caller never waits for the drain.
    @discardableResult
    public func enqueue(_ task: ResearchTask) -> Bool {
        var accepted = false
        for subject in task.subjects {
            let pendingKey = "\(task.classifierTypeID)\u{1F}\(subject.key)"
            guard pendingKeys.count < Self.maximumPendingSubjects,
                  pendingKeys.insert(pendingKey).inserted else { continue }
            pending.append(Pending(task: task, subject: subject))
            accepted = true
        }
        if accepted, !isDraining {
            isDraining = true
            Task { await drain() }
        }
        publishStatus()
        return accepted
    }

    public var pendingCount: Int { pending.count }

    public var currentStatus: GroundedResearchQueueStatus { status }

    /// Observes every status change (pending count, in-flight subject, counters,
    /// last failure). Called on the actor; hop to the main actor for UI.
    public func setStatusObserver(_ observer: (@Sendable (GroundedResearchQueueStatus) -> Void)?) {
        statusObserver = observer
        observer?(status)
    }

    private func publishStatus() {
        status.pendingCount = pending.count
        status.retryableFailedCount = retryableFailures.count
        statusObserver?(status)
    }

    private func rememberRetryable(_ item: Pending, key: String) {
        if retryableFailures[key] == nil {
            retryableFailureOrder.append(key)
            while retryableFailureOrder.count > Self.maximumRetryableFailures {
                let evicted = retryableFailureOrder.removeFirst()
                retryableFailures[evicted] = nil
            }
        }
        retryableFailures[key] = item
    }

    /// Re-queues every subject that failed this session, first asking the
    /// store to drop its persisted cooldown. Returns how many were re-queued.
    @discardableResult
    public func retryFailedNow() async -> Int {
        let items = retryableFailureOrder.compactMap { retryableFailures[$0] }
        retryableFailures.removeAll()
        retryableFailureOrder.removeAll()
        var requeued = 0
        for item in items {
            await mutationWriter(.retryRequested(task: item.task, subjectKey: item.subject.key))
            let pendingKey = "\(item.task.classifierTypeID)\u{1F}\(item.subject.key)"
            guard pendingKeys.count < Self.maximumPendingSubjects,
                  pendingKeys.insert(pendingKey).inserted else { continue }
            pending.append(item)
            requeued += 1
        }
        if requeued > 0, !isDraining {
            isDraining = true
            Task { await drain() }
        }
        publishStatus()
        return requeued
    }

    public func waitUntilIdle() async {
        while isDraining || !pending.isEmpty {
            await Task.yield()
        }
    }

    private func drain() async {
        while !pending.isEmpty {
            let item = pending.removeFirst()
            let pendingKey = "\(item.task.classifierTypeID)\u{1F}\(item.subject.key)"
            defer { pendingKeys.remove(pendingKey) }
            guard var configuration = configurationProvider(item.task) else { continue }
            let snapshot = snapshotProvider(item.task)
            let nowDate = now()
            let nowMilliseconds = Int64(nowDate.timeIntervalSince1970 * 1_000)

            guard !snapshot.existingKnowledgeKeys.contains(item.subject.key) else { continue }
            let priorAttempt = snapshot.failedAttempts.first(where: {
                $0.classifierTypeID == item.task.classifierTypeID &&
                    $0.subjectKey == item.subject.key
            })
            if let priorAttempt, priorAttempt.retryAfterMilliseconds > nowMilliseconds {
                status.skippedForCooldownCount += 1
                publishStatus()
                continue
            }

            let usedToday = Self.usedResearchTokens(
                in: snapshot.tokenUsage,
                at: nowDate,
                classifierTypeID: item.task.classifierTypeID
            )
            let remaining = configuration.dailyTokenLimit - usedToday
            guard remaining > 0 else {
                // Out of budget for today: keep the subject retryable rather
                // than dropping it on the floor.
                status.skippedForBudgetCount += 1
                rememberRetryable(item, key: pendingKey)
                publishStatus()
                continue
            }
            configuration.providers.maximumOutputTokens = min(configuration.providers.maximumOutputTokens, remaining)

            if let lastRequestStartedAt {
                let minimumInterval = 60.0 / Double(configuration.requestsPerMinute)
                let elapsed = nowDate.timeIntervalSince(lastRequestStartedAt)
                if elapsed < minimumInterval {
                    await sleeper(minimumInterval - elapsed)
                }
            }
            let requestStart = now()
            lastRequestStartedAt = requestStart
            status.inFlightSubjectKey = item.subject.key
            publishStatus()

            // Transient failures are retried in place before the subject is
            // parked; permanent ones are not worth a second request.
            var outcome: Result<GroundedResearchResult, Error>
            var transientRetries = 0
            while true {
                do {
                    outcome = .success(try await researcher(item.subject, configuration.providers))
                    break
                } catch {
                    outcome = .failure(error)
                    let kind = GroundedResearchFailureKind.classify(error)
                    guard kind.isTransient, transientRetries < Self.maximumTransientRetries else { break }
                    let delay = Self.transientRetryDelays[min(transientRetries, Self.transientRetryDelays.count - 1)]
                    transientRetries += 1
                    status.transientRetryCount += 1
                    VaultDevLog.shared.log("research", "retry", [
                        "subject": item.subject.key,
                        "kind": kind.rawValue,
                        "attempt": String(transientRetries),
                    ])
                    await sleeper(delay)
                }
            }
            status.inFlightSubjectKey = nil

            switch outcome {
            case .success(let result):
                let usage = TokenUsageRecord(
                    provider: configuration.providers.llmProfile.id,
                    model: configuration.providers.llmModelIdentifier,
                    // Record what the provider actually reported (or the
                    // executor's conservative requested-cap fallback). The
                    // output cap is reduced to the remaining allowance before
                    // dispatch, but a provider may still report input + output
                    // usage above that cap; retaining the full charge keeps the
                    // persisted daily gate conservative on subsequent drains.
                    tokenCount: result.chargedTokenCount,
                    status: Self.researchUsageStatus,
                    classifierTypeID: item.task.classifierTypeID,
                    createdAtMilliseconds: Int64(requestStart.timeIntervalSince1970 * 1_000)
                )
                await mutationWriter(.succeeded(task: item.task, result: result, usage: usage))
                status.succeededCount += 1
                status.lastSuccessAtMilliseconds = Int64(requestStart.timeIntervalSince1970 * 1_000)
                publishStatus()
            case .failure(let error):
                let kind = GroundedResearchFailureKind.classify(error)
                let failureCount = (priorAttempt?.failureCount ?? 0) + 1
                VaultDevLog.shared.log("research", "failed", [
                    "subject": item.subject.key,
                    "kind": kind.rawValue,
                    "failures": String(failureCount),
                    "retries": String(transientRetries),
                    "error": String(describing: error),
                ])
                let attemptedAt = Int64(requestStart.timeIntervalSince1970 * 1_000)
                let cooldown = Self.cooldownMilliseconds(
                    for: kind,
                    failureCount: failureCount,
                    configured: configuration.failureCooldownMilliseconds
                )
                let retry = attemptedAt.addingReportingOverflow(cooldown)
                let attempt = ResearchAttemptRecord(
                    classifierTypeID: item.task.classifierTypeID,
                    subjectKey: item.subject.key,
                    lastAttemptAtMilliseconds: attemptedAt,
                    retryAfterMilliseconds: retry.overflow ? Int64.max : retry.partialValue,
                    failureCount: failureCount,
                    failureKind: kind
                )
                await mutationWriter(.failed(task: item.task, attempt: attempt))
                rememberRetryable(item, key: pendingKey)
                status.failedCount += 1
                status.lastFailure = .init(
                    subjectKey: item.subject.key,
                    kind: kind,
                    atMilliseconds: attemptedAt,
                    retryAfterMilliseconds: attempt.retryAfterMilliseconds,
                    failureCount: failureCount
                )
                publishStatus()
            }
        }
        isDraining = false
        publishStatus()
    }

    /// Transient: 15 min doubling per consecutive failure, capped at the
    /// configured cooldown. Permanent: the configured cooldown.
    public static func cooldownMilliseconds(
        for kind: GroundedResearchFailureKind,
        failureCount: Int,
        configured: Int64
    ) -> Int64 {
        guard kind.isTransient else { return configured }
        let exponent = min(max(failureCount - 1, 0), 10)
        let escalated = baseTransientCooldownMilliseconds.multipliedReportingOverflow(by: Int64(1) << exponent)
        return min(configured, escalated.overflow ? Int64.max : escalated.partialValue)
    }

    public static func usedResearchTokens(
        in records: [TokenUsageRecord],
        at date: Date,
        classifierTypeID: String? = nil,
        calendar: Calendar = .current
    ) -> Int {
        let start = Int64(calendar.startOfDay(for: date).timeIntervalSince1970 * 1_000)
        var total = 0
        for record in records where record.status == researchUsageStatus &&
            record.createdAtMilliseconds >= start &&
            (classifierTypeID == nil || record.classifierTypeID == classifierTypeID) {
            let addition = total.addingReportingOverflow(record.tokenCount)
            total = addition.overflow ? Int.max : addition.partialValue
        }
        return total
    }
}
