import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
import VaultClassifierCore

@main
struct VaultClassifierApp: App {
    var body: some Scene {
        WindowGroup("Vault Classifier") {
            VaultClassifierRootView()
        }
    }
}

@MainActor
private final class VaultClassifierViewModel: ObservableObject {
    enum Workspace: String, CaseIterable, Identifiable {
        case inspect
        case policies
        case activity
        case audit
        case integration

        var id: String { rawValue }
    }

    @Published var workspace: Workspace = .inspect
    @Published var title = "Clash Royale deck gameplay - ranked match"
    @Published var sourceID = "youtube:channel:demo"
    @Published var surface: EntrySurface = .feed
    @Published var result: ClassificationResult?
    @Published var issue: String?
    @Published var localState: LocalClassifierState?
    @Published var policies: [NamedPolicy] = []
    @Published var editingPolicyID = ""
    @Published var editingPolicyName = ""
    @Published var editingPolicyIncludeTag = "content.entities.clash-royale"
    @Published var editingPolicyExcludeTag = ""
    @Published var editingFeedAction: PresentationAction = .dim
    @Published var editingPageAction: PresentationAction = .block
    @Published var auditEnabled = false
    @Published var auditProvider: AuditProvider = .googleGemini
    @Published var auditModelIdentifier = "gemini-3.1-flash-lite"
    @Published var auditEffort: AuditReasoningEffort = .low
    @Published var auditSelectionMode: AuditSelectionMode = .targetedFalseAllow
    @Published var auditOutputCap = "512"
    @Published var auditRequestTokenCap = "1,200"
    @Published var auditWeeklyTokenCap = "8,000"
    @Published var auditMonthlyTokenCap = "25,000"
    @Published var auditLocalLearning = false
    @Published var auditGeminiAPIKey = ""
    @Published private(set) var hasStoredGeminiAPIKey = false
    @Published private(set) var auditRunningCandidateIDs = Set<UUID>()
    @Published private(set) var auditDiagnosticNotice: String?
    @Published var profile: ResourceProfile = .balanced
    @Published var resourceCacheCapacity = "50,000"
    @Published var allowIdleWork = true
    @Published var allowBackgroundSync = true
    @Published var allowLocalLLMAudit = false
    @Published var packageUpdateMode: PackageUpdateMode = .automatic

    private var coordinator: LocalClassifierCoordinator?
    private var ipcServer: LocalIPCServer?
    private var latestLedgerID: UUID?

    init() {
        do {
            let package = try SeedPackageLoader.bundled()
            let appSupport = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let vaultDirectory = appSupport.appendingPathComponent("VaultClassifier", isDirectory: true)
            let coordinator = try LocalClassifierCoordinator(verifiedPackage: package, stateFile: LocalStateFile(url: vaultDirectory.appendingPathComponent("state.json")), defaultPolicies: [StarterPolicies.clashRoyale])
            _ = try DevicePairingSecretStore.ensure()
            self.coordinator = coordinator
            self.policies = coordinator.policies()
            self.localState = coordinator.snapshot()
            loadResourceSettings(from: coordinator.snapshot().settings)
            loadAuditConfiguration(from: coordinator.snapshot().auditState.configuration)
            self.hasStoredGeminiAPIKey = PersonalAuditCredentialStore.hasGeminiAPIKey()
            let server = LocalIPCServer(socketURL: vaultDirectory.appendingPathComponent("classifier-v1.sock")) { request in
                do {
                    try coordinator.verifyAndRecordNativeEnvelope(request.envelope)
                    switch request.envelope.kind {
                    case "classify":
                        let classification = try JSONDecoder().decode(NativeClassificationRequest.self, from: request.envelope.bodyData())
                        let output = try coordinator.classifyWithLedger(classification.entry)
                        return .init(requestID: request.requestID, classification: .init(result: output.result, ledgerID: output.ledgerID))
                    case "correct":
                        let correction = try JSONDecoder().decode(NativeCorrectionRequest.self, from: request.envelope.bodyData())
                        try coordinator.setCorrection(ledgerID: correction.ledgerID, correction: correction.correction)
                        return .init(requestID: request.requestID, correction: .init(accepted: true))
                    default:
                        return .init(requestID: request.requestID, error: "Unsupported local IPC operation.")
                    }
                } catch {
                    return .init(requestID: request.requestID, error: error.localizedDescription)
                }
            }
            try server.start()
            self.ipcServer = server
        } catch {
            issue = error.localizedDescription
        }
    }

    func classify() {
        do {
            guard let coordinator else { return }
            let entry = EntryEvidence(
                platform: "demo",
                sourceID: sourceID.isEmpty ? nil : sourceID,
                surface: surface,
                evidence: .init(title: title),
                policyIDs: policies.map(\.id)
            )
            let output = try coordinator.classifyWithLedger(entry)
            result = output.result
            latestLedgerID = output.ledgerID
            issue = nil
            refreshLocalState()
        } catch {
            issue = error.localizedDescription
        }
    }

    func savePolicy() {
        do {
            guard let coordinator else { return }
            let identifier = editingPolicyID.trimmingCharacters(in: .whitespacesAndNewlines)
            let policy = NamedPolicy(
                id: identifier,
                name: editingPolicyName.trimmingCharacters(in: .whitespacesAndNewlines),
                includeAnyTagIDs: splitTagList(editingPolicyIncludeTag),
                excludeTagIDs: splitTagList(editingPolicyExcludeTag),
                feedAction: editingFeedAction,
                pageAction: editingPageAction
            )
            var replacement = policies.filter { $0.id != policy.id }
            replacement.append(policy)
            try coordinator.replacePolicies(replacement.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
            policies = coordinator.policies()
            select(policy)
            refreshLocalState()
            issue = nil
        } catch {
            issue = error.localizedDescription
        }
    }

    func select(_ policy: NamedPolicy) {
        editingPolicyID = policy.id
        editingPolicyName = policy.name
        editingPolicyIncludeTag = policy.includeAnyTagIDs.joined(separator: ", ")
        editingPolicyExcludeTag = policy.excludeTagIDs.joined(separator: ", ")
        editingFeedAction = policy.feedAction
        editingPageAction = policy.pageAction
    }

    func startNewPolicy() {
        editingPolicyID = ""
        editingPolicyName = ""
        editingPolicyIncludeTag = ""
        editingPolicyExcludeTag = ""
        editingFeedAction = .dim
        editingPageAction = .block
    }

    func deleteEditingPolicy() {
        do {
            guard let coordinator else { return }
            let identifier = editingPolicyID
            guard !identifier.isEmpty else { return }
            let replacement = policies.filter { $0.id != identifier }
            try coordinator.replacePolicies(replacement)
            policies = coordinator.policies()
            startNewPolicy()
            refreshLocalState()
            issue = nil
        } catch {
            issue = error.localizedDescription
        }
    }

    func markCurrentResult(_ correction: UserCorrection) {
        do {
            guard let coordinator, let latestLedgerID else { return }
            try coordinator.setCorrection(ledgerID: latestLedgerID, correction: correction)
            refreshLocalState()
            issue = nil
        } catch {
            issue = error.localizedDescription
        }
    }

    func clearCorrection(_ ledgerID: UUID) {
        do {
            try coordinator?.setCorrection(ledgerID: ledgerID, correction: nil)
            refreshLocalState()
        } catch {
            issue = error.localizedDescription
        }
    }

    func refreshLocalState() {
        localState = coordinator?.snapshot()
    }

    func applyResourceProfileDefaults() {
        resourceCacheCapacity = profile.defaultCacheCapacity.formatted()
        saveResourceSettings()
    }

    func saveResourceSettings() {
        do {
            guard let coordinator else { return }
            let settings = ClassifierSettings(
                resourceProfile: profile,
                cacheCapacity: try positiveInteger(resourceCacheCapacity, label: "Local cache capacity"),
                allowIdleWork: allowIdleWork,
                allowBackgroundSync: allowBackgroundSync,
                allowLocalLLMAudit: allowLocalLLMAudit,
                packageUpdateMode: packageUpdateMode
            )
            try coordinator.updateSettings(settings)
            refreshLocalState()
            issue = nil
        } catch {
            issue = error.localizedDescription
        }
    }

    func saveAuditConfiguration() {
        do {
            guard let coordinator else { return }
            guard auditEnabled else {
                try coordinator.updateAuditConfiguration(nil)
                refreshLocalState()
                issue = nil
                return
            }
            let output = try positiveInteger(auditOutputCap, label: "Audit output cap")
            guard output <= GeminiPersonalAuditAdapter.maximumAuditOutputTokens else {
                throw AppInputError.outputCapTooLarge
            }
            let perRequest = try positiveInteger(auditRequestTokenCap, label: "Per-request audit cap")
            let weekly = try positiveInteger(auditWeeklyTokenCap, label: "Weekly audit cap")
            let monthly = try positiveInteger(auditMonthlyTokenCap, label: "Monthly audit cap")
            let configuration = LocalAuditConfiguration(
                isEnabled: true,
                selectionMode: auditSelectionMode,
                provider: .init(
                    provider: auditProvider,
                    modelIdentifier: auditModelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines),
                    reasoningEffort: auditEffort,
                    maximumOutputTokens: output
                ),
                budgetLimits: .init(
                    perRequest: .init(tokenLimit: perRequest),
                    weekly: .init(tokenLimit: weekly),
                    monthly: .init(tokenLimit: monthly)
                ),
                localLearningMode: auditLocalLearning ? .localValidatedOnly : .disabled
            )
            try coordinator.updateAuditConfiguration(configuration)
            refreshLocalState()
            issue = nil
        } catch {
            issue = error.localizedDescription
        }
    }

    func queueSuggestedAudits() {
        do {
            let added = try coordinator?.enqueueSuggestedFalseAllowAudits(limit: 12) ?? []
            refreshLocalState()
            issue = added.isEmpty ? "No eligible local false-allow candidates are currently available." : nil
        } catch {
            issue = error.localizedDescription
        }
    }

    func queueCurrentAudit() {
        do {
            guard let coordinator, let latestLedgerID else {
                throw AppInputError.noCurrentDecision
            }
            _ = try coordinator.enqueueUserMarkedAudit(ledgerID: latestLedgerID)
            refreshLocalState()
            issue = nil
        } catch {
            issue = error.localizedDescription
        }
    }

    func saveGeminiAPIKey() {
        do {
            try PersonalAuditCredentialStore.saveGeminiAPIKey(auditGeminiAPIKey)
            auditGeminiAPIKey = ""
            hasStoredGeminiAPIKey = true
            issue = nil
        } catch {
            issue = error.localizedDescription
        }
    }

    func removeGeminiAPIKey() {
        do {
            try PersonalAuditCredentialStore.removeGeminiAPIKey()
            auditGeminiAPIKey = ""
            hasStoredGeminiAPIKey = false
            issue = nil
        } catch {
            issue = error.localizedDescription
        }
    }

    func isRunningAudit(_ candidate: AuditedEntry) -> Bool {
        auditRunningCandidateIDs.contains(candidate.auditID)
    }

    /// This action is intentionally user initiated. It validates all local
    /// inputs before the reservation becomes possibly sent; once HTTPS starts,
    /// a timeout is kept as an uncertain reservation rather than silently
    /// freeing a provider charge that may already exist.
    func runGeminiAudit(_ candidate: AuditedEntry) {
        do {
            guard let coordinator else { return }
            guard !auditRunningCandidateIDs.contains(candidate.auditID) else { return }
            guard let apiKey = PersonalAuditCredentialStore.loadGeminiAPIKey() else {
                throw AppInputError.missingGeminiCredential
            }
            guard let configuration = coordinator.snapshot().auditState.configuration,
                  configuration.isEnabled,
                  configuration.provider.provider == .googleGemini else {
                throw AppInputError.auditNotConfigured
            }
            let usageCeiling = try auditUsageCeiling(for: configuration)
            let prepared = try coordinator.prepareAuditRequest(auditID: candidate.auditID, usageCeiling: usageCeiling)
            let adapter = GeminiPersonalAuditAdapter()
            do {
                try adapter.validateForDispatch(prepared.request, apiKey: apiKey)
                try coordinator.markAuditRequestPossiblySent(prepared.reservation.id)
            } catch {
                try? coordinator.cancelAuditReservation(prepared.reservation.id)
                throw error
            }

            auditRunningCandidateIDs.insert(candidate.auditID)
            issue = nil
            let request = prepared.request
            let reservationID = prepared.reservation.id
            Task { [weak self] in
                do {
                    let response = try await adapter.submit(request, apiKey: apiKey)
                    guard let self, let coordinator = self.coordinator else { return }
                    _ = try coordinator.settleAuditResult(response, for: request, reservationID: reservationID)
                    self.refreshLocalState()
                    self.issue = nil
                } catch {
                    guard let self, let coordinator = self.coordinator else { return }
                    // The call was marked possibly sent immediately before
                    // dispatch, so retain an uncertain local reservation.
                    try? coordinator.markAuditRequestUncertain(reservationID)
                    self.refreshLocalState()
                    self.issue = "Gemini audit was not accepted locally: \(error.localizedDescription) The reservation remains marked uncertain so a possible provider charge is not discarded."
                }
                self?.auditRunningCandidateIDs.remove(candidate.auditID)
            }
        } catch {
            refreshLocalState()
            issue = error.localizedDescription
        }
    }

    func confirmationPolicyIDs(for result: ValidatedAuditResult) -> [String] {
        guard result.finding == .potentialFalseAllow,
              let candidate = localState?.auditState.candidates.first(where: { $0.auditID == result.auditID }) else {
            return []
        }
        let requested = Set(candidate.evidence.quotedEntry.policyIDs)
        return policies.map(\.id).filter { requested.isEmpty || requested.contains($0) }
    }

    func isAuditApplied(_ auditID: UUID) -> Bool {
        localState?.auditState.learningApplications.contains(where: { $0.auditID == auditID }) ?? false
    }

    func confirmFalseAllowAudit(_ result: ValidatedAuditResult, policyID: String) {
        do {
            try coordinator?.applyConfirmedFalseAllowAudit(auditID: result.auditID, policyID: policyID)
            refreshLocalState()
            issue = nil
        } catch {
            issue = error.localizedDescription
        }
    }

    /// This is deliberately an explicit local action. The exported diagnostic
    /// contract contains aggregate configuration and budget state only; it
    /// omits credentials, evidence, source/entry/audit identifiers, rationale,
    /// and any stable digest that could reconnect it to local browsing data.
    func copyRedactedAuditDiagnostics() {
        do {
            guard let coordinator else { return }
            let data = try coordinator.redactedAuditDiagnostics()
            guard let text = String(data: data, encoding: .utf8) else {
                throw AppInputError.diagnosticEncodingFailed
            }
            #if canImport(AppKit)
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.setString(text, forType: .string) else {
                throw AppInputError.diagnosticClipboardUnavailable
            }
            auditDiagnosticNotice = "Redacted diagnostics copied to this Mac's clipboard."
            issue = nil
            #else
            throw AppInputError.diagnosticClipboardUnavailable
            #endif
        } catch {
            auditDiagnosticNotice = nil
            issue = error.localizedDescription
        }
    }

    private func loadAuditConfiguration(from configuration: LocalAuditConfiguration?) {
        guard let configuration else { return }
        auditEnabled = configuration.isEnabled
        // The only usable personal-audit adapter in this source slice is the
        // fixed Gemini adapter. Preserve no arbitrary provider endpoint in UI.
        auditProvider = .googleGemini
        auditModelIdentifier = configuration.provider.modelIdentifier
        auditEffort = configuration.provider.reasoningEffort
        auditSelectionMode = configuration.selectionMode
        auditOutputCap = String(configuration.provider.maximumOutputTokens)
        auditRequestTokenCap = configuration.budgetLimits.perRequest.tokenLimit.map(String.init) ?? ""
        auditWeeklyTokenCap = configuration.budgetLimits.weekly.tokenLimit.map(String.init) ?? ""
        auditMonthlyTokenCap = configuration.budgetLimits.monthly.tokenLimit.map(String.init) ?? ""
        auditLocalLearning = configuration.localLearningMode == .localValidatedOnly
    }

    private func loadResourceSettings(from settings: ClassifierSettings) {
        profile = settings.resourceProfile
        resourceCacheCapacity = settings.cacheCapacity.formatted()
        allowIdleWork = settings.allowIdleWork
        allowBackgroundSync = settings.allowBackgroundSync
        allowLocalLLMAudit = settings.allowLocalLLMAudit
        packageUpdateMode = settings.packageUpdateMode
    }

    private func positiveInteger(_ raw: String, label: String) throws -> Int {
        let digits = raw.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(digits), value > 0 else { throw AppInputError.invalidNumber(label) }
        return value
    }

    private func auditUsageCeiling(for configuration: LocalAuditConfiguration) throws -> AuditUsage {
        guard let tokenLimit = configuration.budgetLimits.perRequest.tokenLimit,
              tokenLimit >= configuration.provider.maximumOutputTokens else {
            throw AppInputError.auditRequestBudgetTooSmall
        }
        // Gemini has a fixed output-token cap but may bill additional thought
        // tokens. This reserves the configured output plus the remaining local
        // request budget for input; reported thought/other tokens are retained
        // as an explicit overage if Gemini exceeds this local reservation.
        return .init(
            inputTokens: tokenLimit - configuration.provider.maximumOutputTokens,
            outputTokens: configuration.provider.maximumOutputTokens
        )
    }

    func auditBudgetTokenSummary(for scope: AuditBudgetScope) -> String {
        guard let auditState = localState?.auditState,
              let configuration = auditState.configuration,
              scope != .perRequest else {
            return "—"
        }
        let timestamp = Int64((Date().timeIntervalSince1970 * 1_000).rounded(.towardZero))
        let window = AuditBudgetWindow.containing(timestamp, scope: scope)
        let used = (try? auditState.budgetLedger.effectiveTokenCount(in: window)) ?? 0
        let limit: Int?
        switch scope {
        case .weekly: limit = configuration.budgetLimits.weekly.tokenLimit
        case .monthly: limit = configuration.budgetLimits.monthly.tokenLimit
        case .perRequest: limit = nil
        }
        let limitText = limit.map { $0.formatted() } ?? "No cap"
        return "\(used.formatted()) / \(limitText)"
    }

    private func splitTagList(_ raw: String) -> [String] {
        Array(Set(raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
    }
}

private enum AppInputError: Error, LocalizedError {
    case invalidNumber(String)
    case outputCapTooLarge
    case noCurrentDecision
    case missingGeminiCredential
    case auditNotConfigured
    case auditRequestBudgetTooSmall
    case diagnosticEncodingFailed
    case diagnosticClipboardUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidNumber(let label): return "\(label) must be a positive whole number."
        case .outputCapTooLarge: return "Gemini audit output cap must be 2,048 tokens or fewer."
        case .noCurrentDecision: return "Classify an entry before adding it to the local audit queue."
        case .missingGeminiCredential: return "Store a Gemini API key in this Mac's Keychain before explicitly running an audit."
        case .auditNotConfigured: return "Save enabled Gemini audit settings before running an audit."
        case .auditRequestBudgetTooSmall: return "The per-request token reservation must be at least the configured output-token cap."
        case .diagnosticEncodingFailed: return "The redacted audit diagnostic could not be encoded locally."
        case .diagnosticClipboardUnavailable: return "The redacted audit diagnostic could not be copied to the local clipboard."
        }
    }
}

private struct VaultClassifierRootView: View {
    @StateObject private var model = VaultClassifierViewModel()

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [VaultPalette.canvasTop, VaultPalette.canvasBottom],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 12) {
                header

                HStack(alignment: .top, spacing: 14) {
                    sidebar
                        .frame(width: 270)
                    inspector
                }
            }
            .padding(12)
        }
        .frame(minWidth: 960, minHeight: 650)
        .onAppear { model.classify() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(VaultPalette.navy)
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 2) {
                Text("Vault Classifier")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(VaultPalette.ink)
                Text("Local evidence inspector")
                    .font(.system(size: 12))
                    .foregroundStyle(VaultPalette.muted)
            }

            Text("OFFLINE")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(0.8)
                .foregroundStyle(VaultPalette.navy)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(VaultPalette.navyPale, in: Capsule())

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text("Resource profile")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(VaultPalette.muted)
                Picker("Resource profile", selection: $model.profile) {
                    ForEach(ResourceProfile.allCases, id: \.self) { profile in
                        Text(profile.rawValue.capitalized).tag(profile)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 254)
                .onChange(of: model.profile) { _ in
                    model.applyResourceProfileDefaults()
                }
            }
        }
        .padding(.horizontal, 8)
    }

    private var sidebar: some View {
        VaultPanel {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("CLASSIFIER")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(VaultPalette.muted)
                    Text("Local workspace")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(VaultPalette.ink)
                    Text("Everything below is read, scored, and retained on this Mac.")
                        .font(.system(size: 12))
                        .foregroundStyle(VaultPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 7) {
                    VaultNavigationRow(icon: "wand.and.stars", title: "Inspect entry", detail: "Current tool", isSelected: model.workspace == .inspect) { model.workspace = .inspect }
                    VaultNavigationRow(icon: "tag", title: "Named policies", detail: "\(model.policies.count) local", isSelected: model.workspace == .policies) { model.workspace = .policies }
                    VaultNavigationRow(icon: "archivebox", title: "Local activity", detail: "FIFO + corrections", isSelected: model.workspace == .activity) { model.workspace = .activity; model.refreshLocalState() }
                    VaultNavigationRow(icon: "checklist.checked", title: "Personal audit", detail: "Optional + budgeted", isSelected: model.workspace == .audit) { model.workspace = .audit; model.refreshLocalState() }
                    VaultNavigationRow(icon: "cable.connector", title: "Browser bridge", detail: "Opt-in local path", isSelected: model.workspace == .integration) { model.workspace = .integration }
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("PACKAGE")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(VaultPalette.muted)
                    VaultStatusLine(icon: "checkmark.seal.fill", title: "Seed verified", value: "SHA-256")
                    VaultStatusLine(icon: "point.3.connected.trianglepath.dotted", title: "Source prior", value: "70 / 30")
                    VaultStatusLine(icon: "lock.fill", title: "Network", value: "Not used")
                }

                Spacer(minLength: 0)

                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(VaultPalette.navy)
                    Text("Local-first development shell")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(VaultPalette.muted)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(VaultPalette.navyPale.opacity(0.7), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    private var inspector: some View {
        VaultPanel {
            ScrollView {
                switch model.workspace {
                case .inspect:
                    inspectWorkspace
                case .policies:
                    policyWorkspace
                case .activity:
                    activityWorkspace
                case .audit:
                    auditWorkspace
                case .integration:
                    integrationWorkspace
                }
            }
        }
    }

    private var inspectWorkspace: some View {
        VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Inspect an entry")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(VaultPalette.ink)
                            Text("Provide the same compact evidence a browser adapter will send. Ancestors are derived locally.")
                                .font(.system(size: 12))
                                .foregroundStyle(VaultPalette.muted)
                        }
                        Spacer()
                        Text(model.surface == .feed ? "FEED DECISION" : "PAGE DECISION")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .tracking(0.7)
                            .foregroundStyle(VaultPalette.navy)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background(VaultPalette.navyPale, in: Capsule())
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        VaultFieldLabel(title: "ENTRY TITLE", hint: "Required")
                        TextField("A video title or other local entry text", text: $model.title)
                            .textFieldStyle(.plain)
                            .vaultInput()
                    }

                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 8) {
                            VaultFieldLabel(title: "SOURCE ID", hint: "Optional")
                            TextField("youtube:channel:…", text: $model.sourceID)
                                .textFieldStyle(.plain)
                                .vaultInput()
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            VaultFieldLabel(title: "TARGET SURFACE", hint: "Feed is +5% stricter")
                            Picker("Surface", selection: $model.surface) {
                                Label("Feed", systemImage: "rectangle.grid.1x2").tag(EntrySurface.feed)
                                Label("Page", systemImage: "rectangle.on.rectangle").tag(EntrySurface.page)
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(maxWidth: .infinity)
                        }
                    }

                    HStack(spacing: 10) {
                        Button(action: model.classify) {
                            Label("Classify locally", systemImage: "sparkles")
                                .font(.system(size: 13, weight: .semibold))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white)
                        .background(VaultPalette.navy, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                        Text("No upload • no provider key • local ledger")
                            .font(.system(size: 11))
                            .foregroundStyle(VaultPalette.muted)
                    }

            if let result = model.result {
                VaultResultCard(result: result)
                if result.strongestAction != .allow {
                    HStack(spacing: 9) {
                        Text("Was this restriction incorrect?")
                            .font(.system(size: 11))
                            .foregroundStyle(VaultPalette.muted)
                        Button("Mark false dim") { model.markCurrentResult(.falseDim) }
                            .buttonStyle(.borderless)
                        Button("Mark false block") { model.markCurrentResult(.falseBlock) }
                            .buttonStyle(.borderless)
                    }
                } else {
                    HStack(spacing: 9) {
                        Text("This stayed allowed.")
                            .font(.system(size: 11))
                            .foregroundStyle(VaultPalette.muted)
                        Button("Mark false allow") { model.markCurrentResult(.falseAllow) }
                            .buttonStyle(.borderless)
                    }
                }
            }

            if let issue = model.issue {
                VaultIssueCard(issue: issue)
            }
        }
    }

    private var policyWorkspace: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Named policies")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(VaultPalette.ink)
                    Text("Policies live in Vault Classifier. The browser only asks for a policy ID and renders the returned decision.")
                        .font(.system(size: 12))
                        .foregroundStyle(VaultPalette.muted)
                }
                Spacer()
                Button("New policy") { model.startNewPolicy() }
                    .buttonStyle(.bordered)
            }

            if !model.policies.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    VaultFieldLabel(title: "SAVED POLICIES", hint: "Select to edit")
                    ForEach(model.policies) { policy in
                        Button { model.select(policy) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: policy.feedAction == .block ? "hand.raised.fill" : "eye.slash")
                                    .foregroundStyle(policy.feedAction == .block ? VaultPalette.red : VaultPalette.navy)
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(policy.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(VaultPalette.ink)
                                    Text(policy.id).font(.system(size: 10)).foregroundStyle(VaultPalette.muted)
                                }
                                Spacer()
                                Text("feed \(policy.feedAction.rawValue)")
                                    .font(.system(size: 10, weight: .medium, design: .rounded))
                                    .foregroundStyle(VaultPalette.muted)
                            }
                            .padding(10)
                            .background(model.editingPolicyID == policy.id ? VaultPalette.navyPale : .white.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 11) {
                Text(model.editingPolicyID.isEmpty ? "Create a policy" : "Edit policy")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(VaultPalette.ink)
                VaultFieldLabel(title: "POLICY ID", hint: "Letters, numbers, . _ -")
                TextField("gaming-focus", text: $model.editingPolicyID).textFieldStyle(.plain).vaultInput()
                VaultFieldLabel(title: "DISPLAY NAME", hint: "Local only")
                TextField("A concise policy name", text: $model.editingPolicyName).textFieldStyle(.plain).vaultInput()
                VaultFieldLabel(title: "INCLUDE ANY TAGS", hint: "Comma separated, exact taxonomy IDs")
                TextField("content.entities.clash-royale", text: $model.editingPolicyIncludeTag).textFieldStyle(.plain).vaultInput()
                VaultFieldLabel(title: "EXCLUDE TAGS", hint: "Optional, comma separated")
                TextField("content.formats.reaction", text: $model.editingPolicyExcludeTag).textFieldStyle(.plain).vaultInput()
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        VaultFieldLabel(title: "FEED ACTION", hint: "Default is dim")
                        Picker("Feed action", selection: $model.editingFeedAction) {
                            Text("Allow").tag(PresentationAction.allow)
                            Text("Dim").tag(PresentationAction.dim)
                            Text("Block").tag(PresentationAction.block)
                        }.labelsHidden().pickerStyle(.segmented)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        VaultFieldLabel(title: "PAGE ACTION", hint: "Page dim becomes block")
                        Picker("Page action", selection: $model.editingPageAction) {
                            Text("Allow").tag(PresentationAction.allow)
                            Text("Block").tag(PresentationAction.block)
                        }.labelsHidden().pickerStyle(.segmented)
                    }
                }
                HStack(spacing: 10) {
                    Button("Save locally") { model.savePolicy() }
                        .buttonStyle(.borderedProminent)
                    if !model.editingPolicyID.isEmpty {
                        Button("Delete", role: .destructive) { model.deleteEditingPolicy() }
                            .buttonStyle(.bordered)
                    }
                }
            }

            if let issue = model.issue { VaultIssueCard(issue: issue) }
        }
    }

    private var activityWorkspace: some View {
        let state = model.localState
        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Local activity")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(VaultPalette.ink)
                    Text("The bounded cache and decision ledger are local. Opening or watching content is never a training label.")
                        .font(.system(size: 12))
                        .foregroundStyle(VaultPalette.muted)
                }
                Spacer()
                Button("Refresh") { model.refreshLocalState() }.buttonStyle(.bordered)
            }

            HStack(spacing: 10) {
                VaultMetric(title: "CACHE", value: "\(state?.cache.count ?? 0) / \(state?.settings.cacheCapacity ?? 0)")
                VaultMetric(title: "LEDGER", value: "\(state?.ledger.count ?? 0)")
                VaultMetric(title: "CORRECTIONS", value: "\(state?.ledger.filter { $0.correction != nil }.count ?? 0)")
            }

            VStack(alignment: .leading, spacing: 10) {
                VaultFieldLabel(title: "RESOURCE CONTROLS", hint: "This Mac only")
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        VaultFieldLabel(title: "CACHE CAPACITY", hint: "Unique entries")
                        TextField("50,000", text: $model.resourceCacheCapacity)
                            .textFieldStyle(.plain)
                            .vaultInput()
                        VaultFieldLabel(title: "PACKAGE UPDATES", hint: "Local preference")
                        Picker("Package updates", selection: $model.packageUpdateMode) {
                            Text("Automatic").tag(PackageUpdateMode.automatic)
                            Text("Ask first").tag(PackageUpdateMode.downloadThenAsk)
                            Text("Manual").tag(PackageUpdateMode.manual)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Allow low-priority cache refresh work", isOn: $model.allowIdleWork)
                        Toggle("Allow daily package checks when an endpoint is configured", isOn: $model.allowBackgroundSync)
                        Toggle("Allow personal LLM audit dispatch", isOn: $model.allowLocalLLMAudit)
                    }
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                    .foregroundStyle(VaultPalette.ink)
                }
                HStack(spacing: 10) {
                    Button("Save local resource settings") { model.saveResourceSettings() }
                        .buttonStyle(.borderedProminent)
                    Text("No endpoint or automatic task is configured in this development build; this only persists your future sync preference.")
                        .font(.system(size: 10))
                        .foregroundStyle(VaultPalette.muted)
                }
            }
            .padding(12)
            .background(VaultPalette.navyPale.opacity(0.58), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            if let ledger = state?.ledger.suffix(12).reversed(), !ledger.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    VaultFieldLabel(title: "RECENT DECISIONS", hint: "Newest first")
                    ForEach(Array(ledger)) { item in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: item.correction == nil ? "checkmark.circle" : "flag.fill")
                                .foregroundStyle(item.correction == nil ? VaultPalette.navy : VaultPalette.red)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.cacheKey).font(.system(size: 11, weight: .semibold)).foregroundStyle(VaultPalette.ink).lineLimit(1)
                                Text("\(item.auditGrade.rawValue) • \(item.modelVersion)")
                                    .font(.system(size: 10)).foregroundStyle(VaultPalette.muted)
                            }
                            Spacer()
                            if item.correction != nil {
                                Button("Clear") { model.clearCorrection(item.id) }
                                    .buttonStyle(.borderless)
                                    .font(.system(size: 10))
                            }
                        }
                        .padding(10)
                        .background(.white.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
            } else {
                Text("No local decisions yet. Inspect an entry or enable the future local browser bridge after it has been installed.")
                    .font(.system(size: 12))
                    .foregroundStyle(VaultPalette.muted)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(VaultPalette.navyPale.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private var auditWorkspace: some View {
        let auditState = model.localState?.auditState
        let configuration = auditState?.configuration
        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Personal audit")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(VaultPalette.ink)
                    Text("Optional review for possible false allows. Evidence stays quoted as untrusted data; a local reservation is made before an explicit Gemini request, and provider-reported thinking usage is retained if it exceeds that reservation.")
                        .font(.system(size: 12))
                        .foregroundStyle(VaultPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Text(model.auditEnabled ? (model.allowLocalLLMAudit ? (model.hasStoredGeminiAPIKey ? "READY" : "KEY NEEDED") : "RESOURCE HOLD") : "OFF")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(0.7)
                    .foregroundStyle(model.auditEnabled && model.allowLocalLLMAudit && model.hasStoredGeminiAPIKey ? VaultPalette.navy : VaultPalette.muted)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(model.auditEnabled && model.allowLocalLLMAudit && model.hasStoredGeminiAPIKey ? VaultPalette.navyPale : .gray.opacity(0.12), in: Capsule())
            }

            Toggle("Enable personal local auditing", isOn: $model.auditEnabled)
                .toggleStyle(.switch)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(VaultPalette.ink)

            if model.auditEnabled && !model.allowLocalLLMAudit {
                Text("Resource controls currently prevent Gemini dispatch. Enable Personal LLM audit dispatch in Local activity before a queued item can spend tokens.")
                    .font(.system(size: 11))
                    .foregroundStyle(VaultPalette.muted)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(VaultPalette.navyPale.opacity(0.72), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            if model.auditEnabled {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            VaultFieldLabel(title: "APPROVED PROVIDER", hint: "Fixed adapter")
                            Text("Gemini")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(VaultPalette.ink)
                                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                                .padding(.horizontal, 9)
                                .background(.white.opacity(0.68), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            VaultFieldLabel(title: "REASONING", hint: "Per request")
                            Picker("Reasoning", selection: $model.auditEffort) {
                                ForEach(AuditReasoningEffort.allCases, id: \.self) { effort in
                                    Text(effort.rawValue.capitalized).tag(effort)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                        }
                    }
                    VaultFieldLabel(title: "MODEL IDENTIFIER", hint: "Gemini adapter validates before any request")
                    TextField("gemini-3.1-flash-lite", text: $model.auditModelIdentifier).textFieldStyle(.plain).vaultInput()
                    VStack(alignment: .leading, spacing: 6) {
                        VaultFieldLabel(title: "SELECTION", hint: "Local only")
                        Picker("Selection", selection: $model.auditSelectionMode) {
                            Text("Risk selected").tag(AuditSelectionMode.targetedFalseAllow)
                            Text("Risk + sample").tag(AuditSelectionMode.targetedWithRandomSample)
                            Text("Only marked").tag(AuditSelectionMode.userMarkedOnly)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                    }
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            VaultFieldLabel(title: "MAX OUTPUT TOKENS", hint: "Per response • 2,048 max")
                            TextField("512", text: $model.auditOutputCap).textFieldStyle(.plain).vaultInput()
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            VaultFieldLabel(title: "PER REQUEST", hint: "Local token reservation")
                            TextField("1,200", text: $model.auditRequestTokenCap).textFieldStyle(.plain).vaultInput()
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            VaultFieldLabel(title: "WEEKLY", hint: "Local accounting")
                            TextField("8,000", text: $model.auditWeeklyTokenCap).textFieldStyle(.plain).vaultInput()
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            VaultFieldLabel(title: "MONTHLY", hint: "Local accounting")
                            TextField("25,000", text: $model.auditMonthlyTokenCap).textFieldStyle(.plain).vaultInput()
                        }
                    }
                    Toggle("Use validated audit labels only to polish this Mac's personal model", isOn: $model.auditLocalLearning)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11))
                        .foregroundStyle(VaultPalette.muted)
                    VStack(alignment: .leading, spacing: 7) {
                        VaultFieldLabel(title: "GEMINI API KEY", hint: "This Mac's Keychain only")
                        HStack(spacing: 8) {
                            SecureField(model.hasStoredGeminiAPIKey ? "A key is already stored — enter a replacement" : "Paste a Gemini API key", text: $model.auditGeminiAPIKey)
                                .textFieldStyle(.plain)
                                .vaultInput()
                            Button(model.hasStoredGeminiAPIKey ? "Replace" : "Store") { model.saveGeminiAPIKey() }
                                .buttonStyle(.bordered)
                                .disabled(model.auditGeminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            if model.hasStoredGeminiAPIKey {
                                Button("Remove", role: .destructive) { model.removeGeminiAPIKey() }
                                    .buttonStyle(.bordered)
                            }
                        }
                        Text("The extension, native host, local state file, diagnostics, and Vault server never receive this credential. An entry is sent to Gemini only after you press Run Gemini below.")
                            .font(.system(size: 10))
                            .foregroundStyle(VaultPalette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                Text("Auditing is off. No provider is contacted and no audit candidate can spend a token budget.")
                    .font(.system(size: 12))
                    .foregroundStyle(VaultPalette.muted)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(VaultPalette.navyPale.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            HStack(spacing: 10) {
                Button("Save local audit settings") { model.saveAuditConfiguration() }
                    .buttonStyle(.borderedProminent)
                Button("Queue risk-selected allows") { model.queueSuggestedAudits() }
                    .buttonStyle(.bordered)
                    .disabled(!model.auditEnabled || !model.allowLocalLLMAudit)
                Button("Queue current entry for review") { model.queueCurrentAudit() }
                    .buttonStyle(.bordered)
                    .disabled(!model.auditEnabled || model.result == nil)
            }

            HStack(spacing: 10) {
                VaultMetric(title: "QUEUED", value: "\(auditState?.candidates.count ?? 0)")
                VaultMetric(title: "SETTLED", value: "\(auditState?.budgetLedger.records.filter { $0.state == .settled }.count ?? 0)")
                VaultMetric(title: "IN FLIGHT", value: "\(auditState?.budgetLedger.records.filter { $0.state == .reserved || $0.state == .possiblySent }.count ?? 0)")
                VaultMetric(title: "UNCERTAIN", value: "\(auditState?.budgetLedger.records.filter { $0.state == .uncertain }.count ?? 0)")
            }

            HStack(spacing: 10) {
                VaultMetric(title: "WEEKLY TOKENS", value: model.auditBudgetTokenSummary(for: .weekly))
                VaultMetric(title: "MONTHLY TOKENS", value: model.auditBudgetTokenSummary(for: .monthly))
                Spacer(minLength: 0)
            }
            Text("Totals use actual provider-reported tokens after settlement and retain a conservative reservation while a request is in flight or uncertain.")
                .font(.system(size: 10))
                .foregroundStyle(VaultPalette.muted)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 9) {
                Button("Copy redacted diagnostics") { model.copyRedactedAuditDiagnostics() }
                    .buttonStyle(.bordered)
                    .font(.system(size: 10))
                Text("Copies local settings and aggregate audit/budget state only — never evidence, identifiers, rationales, or credentials.")
                    .font(.system(size: 10))
                    .foregroundStyle(VaultPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            if let notice = model.auditDiagnosticNotice {
                Label(notice, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(VaultPalette.navy)
            }

            if let candidates = auditState?.candidates.suffix(6).reversed(), !candidates.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    VaultFieldLabel(title: "LOCAL AUDIT QUEUE", hint: "No evidence leaves this Mac until you explicitly run a configured adapter")
                    ForEach(Array(candidates)) { candidate in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: candidate.intent == .potentialFalseAllow ? "questionmark.circle" : "flag.fill")
                                .foregroundStyle(VaultPalette.navy)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(candidate.intent == .potentialFalseAllow ? "Potential false allow" : "User-marked decision")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(VaultPalette.ink)
                                Text("Risk \(candidate.risk.priority, format: .percent.precision(.fractionLength(0))) • \(candidate.localResult.modelVersion)")
                                    .font(.system(size: 10))
                                    .foregroundStyle(VaultPalette.muted)
                            }
                            Spacer()
                            Text(candidate.eligibility.isEligible ? "eligible" : "held")
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                .foregroundStyle(candidate.eligibility.isEligible ? VaultPalette.navy : VaultPalette.red)
                            Button(model.isRunningAudit(candidate) ? "Running…" : "Run Gemini") { model.runGeminiAudit(candidate) }
                                .buttonStyle(.bordered)
                                .font(.system(size: 10))
                                .disabled(!candidate.eligibility.isEligible || !model.auditEnabled || !model.allowLocalLLMAudit || !model.hasStoredGeminiAPIKey || model.isRunningAudit(candidate))
                        }
                        .padding(10)
                        .background(.white.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
            }

            if let results = auditState?.results.suffix(5).reversed(), !results.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    VaultFieldLabel(title: "LOCAL AUDIT RESULTS", hint: "Provider output remains a review suggestion")
                    ForEach(Array(results)) { auditResult in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Image(systemName: auditResult.finding == .potentialFalseAllow ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                                    .foregroundStyle(auditResult.finding == .potentialFalseAllow ? VaultPalette.red : VaultPalette.navy)
                                Text(auditResult.finding.rawValue)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(VaultPalette.ink)
                                Spacer()
                                Text("\((try? auditResult.usage.totalTokens()) ?? 0) tokens")
                                    .font(.system(size: 10))
                                    .foregroundStyle(VaultPalette.muted)
                            }
                            if !auditResult.leafTagIDs.isEmpty {
                                Text(auditResult.leafTagIDs.joined(separator: ", "))
                                    .font(.system(size: 10))
                                    .foregroundStyle(VaultPalette.muted)
                                    .lineLimit(2)
                            }
                            if auditResult.finding == .potentialFalseAllow && model.auditLocalLearning {
                                if model.isAuditApplied(auditResult.auditID) {
                                    Text("Confirmed locally and applied to this Mac's personal model.")
                                        .font(.system(size: 10))
                                        .foregroundStyle(VaultPalette.muted)
                                } else {
                                    HStack(spacing: 7) {
                                        Text("I confirm this false allow:")
                                            .font(.system(size: 10))
                                            .foregroundStyle(VaultPalette.muted)
                                        ForEach(model.confirmationPolicyIDs(for: auditResult), id: \.self) { policyID in
                                            Button("Polish \(policyID)") { model.confirmFalseAllowAudit(auditResult, policyID: policyID) }
                                                .buttonStyle(.bordered)
                                                .font(.system(size: 10))
                                        }
                                    }
                                }
                            }
                        }
                        .padding(10)
                        .background(.white.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
            }

            Text(configuration == nil
                ? "Provider credentials are never stored in the extension, native host, this state file, or a server."
                : "The saved configuration has no provider credential; it only controls local selection and budget reservations. Gemini returns actual input, output, and thinking/other usage for the local ledger.")
                .font(.system(size: 11))
                .foregroundStyle(VaultPalette.muted)

            if let issue = model.issue { VaultIssueCard(issue: issue) }
        }
    }

    private var integrationWorkspace: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Browser bridge")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(VaultPalette.ink)
            Text("A source-only Chrome/Edge native-messaging adapter is present, but it is deliberately not registered or enabled. This development app continues to classify locally without a browser, server, account, or provider key.")
                .font(.system(size: 12))
                .foregroundStyle(VaultPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
            VaultStatusLine(icon: "checkmark.seal.fill", title: "App classifier", value: "Ready locally")
            VaultStatusLine(icon: "lock.fill", title: "Pairing secret", value: "Keychain")
            VaultStatusLine(icon: "cable.connector", title: "Native host", value: "Not registered")
            VaultStatusLine(icon: "globe", title: "Server", value: "Not required")
            Text("A signed installer must later supply the stable extension IDs and host path. Until then, Chrome and Edge fail open rather than applying a rule.")
                .font(.system(size: 11))
                .foregroundStyle(VaultPalette.muted)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(VaultPalette.navyPale.opacity(0.7), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

private enum VaultPalette {
    static let navy = Color(red: 30 / 255, green: 58 / 255, blue: 138 / 255)
    static let navyPale = Color(red: 238 / 255, green: 242 / 255, blue: 255 / 255)
    static let canvasTop = Color(red: 248 / 255, green: 250 / 255, blue: 252 / 255)
    static let canvasBottom = Color(red: 238 / 255, green: 242 / 255, blue: 255 / 255)
    static let ink = Color(red: 31 / 255, green: 41 / 255, blue: 55 / 255)
    static let muted = Color(red: 71 / 255, green: 85 / 255, blue: 105 / 255)
    static let border = Color(red: 203 / 255, green: 213 / 255, blue: 225 / 255)
    static let red = Color(red: 153 / 255, green: 27 / 255, blue: 27 / 255)
    static let redPale = Color(red: 254 / 255, green: 242 / 255, blue: 242 / 255)
}

private struct VaultPanel<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.white.opacity(0.92), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.08), radius: 17, y: 8)
    }
}

private struct VaultNavigationRow: View {
    let icon: String
    let title: String
    let detail: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? VaultPalette.navy : VaultPalette.muted)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 12, weight: .semibold))
                    Text(detail).font(.system(size: 10)).foregroundStyle(VaultPalette.muted)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(isSelected ? VaultPalette.navyPale : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct VaultMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 9, weight: .bold))
                .tracking(0.7)
                .foregroundStyle(VaultPalette.muted)
            Text(value)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(VaultPalette.ink)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct VaultIssueCard: View {
    let issue: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(VaultPalette.red)
            Text(issue)
                .font(.system(size: 12))
                .foregroundStyle(VaultPalette.red)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VaultPalette.redPale, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct VaultStatusLine: View {
    let icon: String
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(VaultPalette.navy)
                .frame(width: 14)
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(VaultPalette.muted)
            Spacer(minLength: 0)
            Text(value)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(VaultPalette.ink)
        }
    }
}

private struct VaultFieldLabel: View {
    let title: String
    let hint: String

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .tracking(0.75)
                .foregroundStyle(VaultPalette.ink)
            Text(hint)
                .font(.system(size: 10))
                .foregroundStyle(VaultPalette.muted)
        }
    }
}

private struct VaultInput: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 13))
            .foregroundStyle(VaultPalette.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(VaultPalette.border.opacity(0.9), lineWidth: 1))
    }
}

private extension View {
    func vaultInput() -> some View { modifier(VaultInput()) }
}

private struct VaultResultCard: View {
    let result: ClassificationResult

    private var actionColor: Color {
        switch result.strongestAction {
        case .allow: return Color(red: 14 / 255, green: 116 / 255, blue: 144 / 255)
        case .dim: return Color(red: 161 / 255, green: 98 / 255, blue: 7 / 255)
        case .block: return VaultPalette.red
        }
    }

    private var actionPale: Color {
        switch result.strongestAction {
        case .allow: return Color(red: 236 / 255, green: 254 / 255, blue: 255 / 255)
        case .dim: return Color(red: 255 / 255, green: 251 / 255, blue: 235 / 255)
        case .block: return VaultPalette.redPale
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle().fill(actionPale)
                    Image(systemName: result.strongestAction == .allow ? "checkmark" : result.strongestAction == .dim ? "eye.slash" : "hand.raised.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(actionColor)
                }
                .frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text("POLICY DECISION")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(VaultPalette.muted)
                    Text(result.strongestAction.rawValue.capitalized)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(actionColor)
                }
                Spacer()
                Text("threshold \(result.threshold, format: .percent.precision(.fractionLength(0)))")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(VaultPalette.muted)
            }

            VStack(alignment: .leading, spacing: 7) {
                VaultFieldLabel(title: "PREDICTED LEAVES", hint: "Ancestors are computed")
                if result.selectedLeafTagIDs.isEmpty {
                    Text("No leaf met the local threshold.")
                        .font(.system(size: 12))
                        .foregroundStyle(VaultPalette.muted)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 158), spacing: 7)], alignment: .leading, spacing: 7) {
                        ForEach(result.selectedLeafTagIDs, id: \.self) { tagID in
                            Text(tagID.replacingOccurrences(of: "content.", with: "").replacingOccurrences(of: ".", with: " · "))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(VaultPalette.ink)
                                .lineLimit(1)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(VaultPalette.navyPale.opacity(0.75), in: Capsule())
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                VaultFieldLabel(title: "STRONGEST LOCAL SCORES", hint: "Direct + eligible source prior")
                ForEach(result.scores.prefix(4)) { score in
                    HStack(spacing: 9) {
                        Text(score.tagID.replacingOccurrences(of: "content.", with: ""))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(VaultPalette.ink)
                            .lineLimit(1)
                            .frame(width: 220, alignment: .leading)
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule().fill(VaultPalette.navyPale)
                                Capsule().fill(VaultPalette.navy).frame(width: proxy.size.width * score.finalScore)
                            }
                        }
                        .frame(height: 6)
                        Text(score.finalScore, format: .percent.precision(.fractionLength(0)))
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(VaultPalette.muted)
                            .frame(width: 36, alignment: .trailing)
                    }
                }
            }

            if !result.ancestorTagIDs.isEmpty {
                Text("Computed path: \(result.ancestorTagIDs.joined(separator: "  ›  "))")
                    .font(.system(size: 10))
                    .foregroundStyle(VaultPalette.muted)
                    .textSelection(.enabled)
            }
        }
        .padding(16)
        .background(actionPale.opacity(0.55), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(actionColor.opacity(0.2), lineWidth: 1))
    }
}
