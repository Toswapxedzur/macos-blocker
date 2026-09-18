import Foundation
import VaultClassifierCore
import VaultClassifierBridge
import VaultClassifierLLM

// The knowledge/research lane surface: knowledge entry edits, corrections, failed-research retry and the research status payload; plus the grounded-research install and its provider configuration.
// Split out of VaultClassifierApp.swift (CLASSIFIER-INDEPENDENCE §7, Phase 5):
// same type, same behaviour — pinned by ViewModelCharacterizationTests.
@MainActor
extension VaultClassifierViewModel {
    /// Installs the opt-in research lane once. Its closures read a fresh
    /// coordinator snapshot for every subject, so provider edits, budgets, and
    /// disabling the feature take effect without rebuilding the queue.
    func installGroundedResearch(coordinator: LocalClassifierCoordinator) {
        let executor = GroundedResearchExecutor(http: URLSessionProviderHTTPClient())
        let queue = GroundedResearchQueue(
            executor: executor,
            configurationProvider: { [weak coordinator] task in
                guard let coordinator else { return nil }
                return Self.groundedResearchConfiguration(
                    from: coordinator.snapshot(),
                    classifierTypeID: task.classifierTypeID
                )
            },
            snapshotProvider: { [weak coordinator] task in
                coordinator?.groundedResearchQueueSnapshot(for: task) ?? .init()
            },
            mutationWriter: { [weak coordinator] mutation in
                await coordinator?.recordResearchMutation(mutation)
            }
        )
        groundedResearchQueue = queue
        coordinator.setGroundedResearchQueue(queue)
        Task {
            await queue.setStatusObserver { [weak self] status in
                Task { @MainActor [weak self] in
                    guard let self, self.researchQueueStatus != status else { return }
                    self.researchQueueStatus = status
                    self.onWebStateChange?()
                }
            }
        }
        coordinator.setOnVideoReclassified { [weak self] platformID, entryID, projection in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.broadcastResolvedVideoTags(
                    platformID: platformID,
                    entryID: entryID,
                    projection: projection
                )
                self.refreshLocalState()
                self.onWebStateChange?()
            }
        }
    }

    nonisolated private static func groundedResearchConfiguration(
        from state: LocalClassifierState,
        classifierTypeID: String
    ) -> GroundedResearchQueueConfiguration? {
        let globalSettings = state.settings.research
        guard let classifierType = state.workspaceCatalog.classifierTypes.first(where: {
            $0.id == classifierTypeID
        }), let settings = LocalClassifierCoordinator.effectiveResearchSettings(
            global: globalSettings,
            for: classifierType
        ) else { return nil }
        let profiles = state.workspaceCatalog.providerProfiles
        guard let llmProfileID = settings.llmProviderProfileID,
              let modelIdentifier = settings.llmModelIdentifier,
              let llmProfile = profiles.first(where: { $0.id == llmProfileID }),
              ProviderGenerationProtocol.supportsGeneration(profile: llmProfile),
              let llmCredential = try? researchCredential(for: llmProfile)
        else { return nil }

        // Research is provider-grounding only: the LLM provider searches natively,
        // so it must be grounding-capable (OpenAI / Gemini / Anthropic).
        guard GroundedGenerationProtocol.supportsProviderGrounding(profile: llmProfile) else { return nil }

        return .init(
            providers: .init(
                llmProfile: llmProfile,
                llmCredential: llmCredential,
                llmModelIdentifier: modelIdentifier
            ),
            requestsPerMinute: settings.requestsPerMinute,
            dailyTokenLimit: settings.dailyTokenLimit,
            failureCooldownMilliseconds: Int64(settings.cooldownHours) * 60 * 60 * 1_000
        )
    }

    nonisolated static func researchSettings(
        _ current: ResearchSettings,
        removingProviderID profileID: String
    ) -> ResearchSettings {
        var updated = current
        if updated.llmProviderProfileID == profileID {
            updated.llmProviderProfileID = nil
            updated.llmModelIdentifier = nil
        }
        return updated
    }

    func deleteKnowledgeEntry(id: String) {
        guard let coordinator else { return }
        do {
            try coordinator.deleteKnowledgeEntry(id: id)
            refreshLocalState()
            issue = nil
        } catch {
            issue = error.localizedDescription
        }
    }

    func editKnowledgeEntry(id: String, meaning: String) {
        guard let coordinator else { return }
        do {
            try coordinator.updateKnowledgeEntryMeaning(id: id, meaning: meaning)
            refreshLocalState()
            issue = nil
        } catch {
            issue = error.localizedDescription
        }
    }

    /// "Retry failed subjects now": drop every persisted cooldown, then re-queue
    /// the subjects that failed this session.
    func retryFailedResearch() {
        let cleared = coordinator?.clearResearchAttempts() ?? 0
        guard let queue = groundedResearchQueue else {
            refreshLocalState()
            return
        }
        Task { @MainActor [weak self] in
            let requeued = await queue.retryFailedNow()
            VaultDevLog.shared.log("research", "retry-now", [
                "cleared": String(cleared),
                "requeued": String(requeued),
            ])
            self?.refreshLocalState()
            self?.onWebStateChange?()
        }
    }

    /// Research lane status for the settings panel: live queue counters plus
    /// the durable cooldown picture from the persisted attempt records.
    nonisolated static func researchStatusPayload(
        queue: GroundedResearchQueueStatus,
        attempts: [ResearchAttemptRecord],
        now: Date
    ) -> [String: Any] {
        let nowMilliseconds = Int64(now.timeIntervalSince1970 * 1_000)
        let cooling = attempts.filter { $0.retryAfterMilliseconds > nowMilliseconds }
        let transientCooling = cooling.filter { $0.failureKind?.isTransient == true }
        let latest = attempts.max(by: { $0.lastAttemptAtMilliseconds < $1.lastAttemptAtMilliseconds })
        var lastFailure: Any = NSNull()
        if let latest {
            lastFailure = [
                "subject": latest.displaySubject,
                "kind": (latest.failureKind ?? .unknown).rawValue,
                "agoSeconds": max(0, (nowMilliseconds - latest.lastAttemptAtMilliseconds) / 1_000),
                "retryInSeconds": max(0, (latest.retryAfterMilliseconds - nowMilliseconds) / 1_000),
                "failureCount": latest.failureCount,
            ] as [String: Any]
        }
        return [
            "pending": queue.pendingCount,
            "inFlight": queue.inFlightSubjectKey.map { key -> String in
                ResearchAttemptRecord(subjectKey: key, lastAttemptAtMilliseconds: 0, retryAfterMilliseconds: 0).displaySubject
            } ?? "",
            "succeeded": queue.succeededCount,
            "failed": queue.failedCount,
            "retries": queue.transientRetryCount,
            "skippedBudget": queue.skippedForBudgetCount,
            "retryable": queue.retryableFailedCount,
            "inCooldown": cooling.count,
            "transientInCooldown": transientCooling.count,
            "lastFailure": lastFailure,
        ]
    }

    func submitCorrection(
        classifierTypeID: String,
        platformID: String,
        entryID: String,
        correctTagIDs: [String],
        note: String?
    ) {
        do {
            _ = try coordinator?.submitCorrection(
                classifierTypeID: classifierTypeID,
                platformID: platformID,
                entryID: entryID,
                correctTagIDs: correctTagIDs,
                note: note
            )
            refreshLocalState()
            issue = nil
        } catch {
            issue = error.localizedDescription
        }
    }
}
