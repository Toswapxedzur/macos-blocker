import Foundation
import XCTest
@testable import VaultClassifierCore

final class LocalAuditStoreIntegrationTests: XCTestCase {
    private func seed() throws -> VerifiedSeedPackage { try SeedPackageLoader.bundled() }

    private func enablePersonalAudits(on coordinator: LocalClassifierCoordinator) throws {
        var settings = coordinator.snapshot().settings
        settings.allowLocalLLMAudit = true
        try coordinator.updateSettings(settings)
    }

    private func configuration() -> LocalAuditConfiguration {
        .init(
            isEnabled: true,
            selectionMode: .targetedWithRandomSample,
            provider: .init(
                provider: .googleGemini,
                modelIdentifier: "local-audit-test-model",
                reasoningEffort: .low,
                maximumOutputTokens: 96
            ),
            budgetLimits: .init(
                perRequest: .init(tokenLimit: 160),
                weekly: .init(tokenLimit: 320),
                monthly: .init(tokenLimit: 640)
            ),
            localLearningMode: .localValidatedOnly
        )
    }

    func testCoordinatorKeepsAuditsLocalBudgetsBoundedAndExportsRedactedDiagnostics() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stateURL = root.appendingPathComponent("state.json")
        let coordinator = try LocalClassifierCoordinator(
            verifiedPackage: seed(),
            stateFile: LocalStateFile(url: stateURL),
            defaultPolicies: [StarterPolicies.clashRoyale]
        )
        let privateTitle = "PRIVATE_TITLE_NOT_FOR_EXPORT"
        let entry = EntryEvidence(
            requestID: "integration-audit-entry",
            platform: "youtube",
            entryID: "private-video-id",
            sourceID: "private-source-id",
            surface: .feed,
            evidence: .init(title: privateTitle, text: "Private local visible text"),
            policyIDs: [StarterPolicies.clashRoyale.id]
        )
        let result = try coordinator.classify(entry)
        XCTAssertEqual(result.strongestAction, .allow)

        try enablePersonalAudits(on: coordinator)
        try coordinator.updateAuditConfiguration(configuration())
        let candidates = try coordinator.enqueueSuggestedFalseAllowAudits(limit: 5, at: Date(timeIntervalSince1970: 1_700_000_000))
        let candidate = try XCTUnwrap(candidates.first)
        XCTAssertEqual(candidate.intent, .potentialFalseAllow)
        XCTAssertEqual(candidate.evidence.trust, .untrustedQuoted)

        let prepared = try coordinator.prepareAuditRequest(
            auditID: candidate.auditID,
            usageCeiling: .init(inputTokens: 40, outputTokens: 50),
            at: Date(timeIntervalSince1970: 1_700_000_001)
        )
        let context = try XCTUnwrap(prepared.request.policyContext)
        XCTAssertEqual(context.requestedPolicyIDs, [StarterPolicies.clashRoyale.id])
        XCTAssertEqual(context.leafLabels.map(\.tagID), ["content.entities.clash-royale"])
        let unvalidated = UnvalidatedAuditResult(
            finding: .potentialFalseAllow,
            leafTagIDs: ["content.entities.clash-royale"],
            confidence: 0.88,
            rationale: "Local potential false allow based on quoted evidence only.",
            attribution: .init(
                auditID: candidate.auditID,
                provider: .googleGemini,
                modelIdentifier: "local-audit-test-model",
                reasoningEffort: .low,
                evidenceDigest: candidate.evidence.evidenceDigest,
                completedAtMilliseconds: 1_700_000_002_000
            ),
            usage: .init(inputTokens: 32, outputTokens: 34)
        )
        let settled = try coordinator.settleAuditResult(unvalidated, for: prepared.request, reservationID: prepared.reservation.id)
        XCTAssertEqual(settled.finding, .potentialFalseAllow)

        let state = coordinator.snapshot()
        XCTAssertEqual(state.auditState.results, [settled])
        XCTAssertEqual(state.auditState.budgetLedger.records.first?.state, .settled)
        XCTAssertTrue(state.personalModel.state.isEmpty, "Provider output alone must not train the personal model.")

        try coordinator.applyConfirmedFalseAllowAudit(
            auditID: settled.auditID,
            policyID: StarterPolicies.clashRoyale.id,
            at: Date(timeIntervalSince1970: 1_700_000_003)
        )
        let appliedState = coordinator.snapshot()
        XCTAssertFalse(appliedState.personalModel.state.isEmpty, "Only an explicit local user confirmation may train the personal model.")
        XCTAssertEqual(appliedState.auditState.learningApplications.first?.auditID, settled.auditID)
        XCTAssertEqual(appliedState.trainingCorpus.examples.count, 1)
        XCTAssertEqual(appliedState.trainingCorpus.examples.first?.origin, .confirmedPersonalAudit)
        XCTAssertEqual(appliedState.trainingCorpus.lastRun?.exampleCount, 1)

        let diagnostic = String(decoding: try coordinator.redactedAuditDiagnostics(at: Date(timeIntervalSince1970: 1_700_000_003)), as: UTF8.self)
        XCTAssertFalse(diagnostic.contains(privateTitle))
        XCTAssertFalse(diagnostic.contains("private-video-id"))
        XCTAssertFalse(diagnostic.contains("Private local visible text"))

        let reloaded = try LocalStateFile(url: stateURL).load()
        XCTAssertEqual(reloaded.auditState.results, [settled])
        XCTAssertEqual(reloaded.auditState.budgetLedger.records.first?.state, .settled)
    }

    func testCoordinatorCancelsAReservedAuditWithoutTrainingOrBudgetUse() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = try LocalClassifierCoordinator(
            verifiedPackage: seed(),
            stateFile: LocalStateFile(url: root.appendingPathComponent("state.json")),
            defaultPolicies: [StarterPolicies.clashRoyale]
        )
        _ = try coordinator.classify(.init(
            platform: "youtube",
            entryID: "audit-cancel",
            surface: .feed,
            evidence: .init(title: "A general project update"),
            policyIDs: [StarterPolicies.clashRoyale.id]
        ))
        try enablePersonalAudits(on: coordinator)
        try coordinator.updateAuditConfiguration(configuration())
        let candidate = try XCTUnwrap(try coordinator.enqueueSuggestedFalseAllowAudits(limit: 5).first)
        let prepared = try coordinator.prepareAuditRequest(auditID: candidate.auditID, usageCeiling: .init(inputTokens: 10, outputTokens: 10))
        try coordinator.cancelAuditReservation(prepared.reservation.id)
        let state = coordinator.snapshot()
        XCTAssertEqual(state.auditState.budgetLedger.records.first?.state, .cancelled)
        XCTAssertTrue(state.auditState.results.isEmpty)
        XCTAssertTrue(state.personalModel.state.isEmpty)
    }

    func testAutomaticSelectionHonorsEnabledAndUserMarkedOnlyModes() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = try LocalClassifierCoordinator(
            verifiedPackage: seed(),
            stateFile: LocalStateFile(url: root.appendingPathComponent("state.json")),
            defaultPolicies: [StarterPolicies.clashRoyale]
        )
        _ = try coordinator.classify(.init(
            platform: "youtube",
            entryID: "selection-mode-entry",
            surface: .feed,
            evidence: .init(title: "A broadly worded update"),
            policyIDs: [StarterPolicies.clashRoyale.id]
        ))

        var disabled = configuration()
        disabled.isEnabled = false
        try coordinator.updateAuditConfiguration(disabled)
        XCTAssertTrue(try coordinator.enqueueSuggestedFalseAllowAudits(limit: 5).isEmpty)

        var userMarkedOnly = configuration()
        userMarkedOnly.selectionMode = .userMarkedOnly
        try coordinator.updateAuditConfiguration(userMarkedOnly)
        XCTAssertTrue(try coordinator.enqueueSuggestedFalseAllowAudits(limit: 5).isEmpty)

        try enablePersonalAudits(on: coordinator)
        try coordinator.updateAuditConfiguration(configuration())
        let sampled = try coordinator.enqueueSuggestedFalseAllowAudits(limit: 5)
        XCTAssertEqual(sampled.count, 1)
        XCTAssertTrue(sampled[0].risk.contains(.randomSample))
    }

    func testResourceSettingsPreventAutomaticSelectionAndProviderDispatch() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = try LocalClassifierCoordinator(
            verifiedPackage: seed(),
            stateFile: LocalStateFile(url: root.appendingPathComponent("state.json")),
            defaultPolicies: [StarterPolicies.clashRoyale]
        )
        _ = try coordinator.classify(.init(
            platform: "youtube",
            entryID: "resource-gate-entry",
            surface: .feed,
            evidence: .init(title: "A broadly worded update"),
            policyIDs: [StarterPolicies.clashRoyale.id]
        ))
        try enablePersonalAudits(on: coordinator)
        try coordinator.updateAuditConfiguration(configuration())
        let candidate = try XCTUnwrap(try coordinator.enqueueSuggestedFalseAllowAudits(limit: 5).first)

        var settings = coordinator.snapshot().settings
        settings.allowLocalLLMAudit = false
        try coordinator.updateSettings(settings)

        XCTAssertTrue(try coordinator.enqueueSuggestedFalseAllowAudits(limit: 5).isEmpty)
        XCTAssertThrowsError(
            try coordinator.prepareAuditRequest(auditID: candidate.auditID, usageCeiling: .init(inputTokens: 10, outputTokens: 10))
        ) { error in
            XCTAssertEqual(error as? LocalAuditStoreError, .localAuditDisabledByResourceSettings)
        }
        XCTAssertEqual(coordinator.snapshot().auditState.candidates.map(\.auditID), [candidate.auditID])
    }
}
