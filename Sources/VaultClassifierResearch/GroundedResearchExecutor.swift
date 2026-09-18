import Foundation
import VaultClassifierCore

// The cloud grounded-research EXECUTION layer: the executor that turns a
// data-minimized ResearchSubject into a provider call, and the queue's
// convenience init that wires it in. Everything the queue/store persist or
// classify (subjects, tasks, attempt records, failure kinds, queue state)
// stays in VaultClassifierCore.

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
        // The only search execution (RESEARCH-REDESIGN Cut A): the LLM provider
        // searches natively (Gemini google_search, OpenAI/Anthropic web_search)
        // and distills in one call. The separate raw-search provider is gone.
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
}

extension GroundedResearchQueue {
    /// Convenience wiring: run the queue against the real network executor.
    /// Lives here (not in Core) so the tagging core never references the
    /// cloud-research execution layer; Core only knows the `Researcher` closure.
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
}
