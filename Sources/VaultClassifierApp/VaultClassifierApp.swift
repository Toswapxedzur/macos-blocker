import CryptoKit
import AppKit
import Combine
import VaultClassifierCore

@main
private enum VaultClassifierAppMain {
    static func main() {
        let application = NSApplication.shared
        let delegate = VaultClassifierAppDelegate()
        application.setActivationPolicy(.regular)
        application.delegate = delegate
        application.run()
    }
}

private final class VaultClassifierAppDelegate: NSObject, NSApplicationDelegate {
    private var model: VaultClassifierViewModel?
    private var webShell: VaultClassifierWebShell?
    private var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // SwiftPM executables otherwise behave like background tools. This
        // AppKit host keeps the window native while every visible product
        // control is rendered by the bundled local WKWebView.
        NSApp.setActivationPolicy(.regular)
        // This development shell intentionally follows Mac Vault's light
        // working surface even when the host Mac uses Dark appearance.
        NSApp.appearance = NSAppearance(named: .aqua)
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(configureWindow(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
        Task { @MainActor [weak self] in
            self?.showClassifierWindow()
        }
    }

    @MainActor
    private func showClassifierWindow() {
        let model = VaultClassifierViewModel()
        let shell = VaultClassifierWebShell(model: model)
        let webView = shell.makeWebView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_180, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Vault Classifier"
        window.minSize = NSSize(width: 980, height: 650)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.contentView = webView
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.model = model
        self.webShell = shell
        self.mainWindow = window
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func configureWindow(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        window.collectionBehavior.insert(.fullScreenPrimary)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@MainActor
final class VaultClassifierViewModel: ObservableObject {
    enum Workspace: String, CaseIterable, Identifiable, Hashable {
        case tagTree
        case localModel
        case llmAssist
        case browserBridge
        case classificationData

        var id: String { rawValue }
    }

    @Published var workspace: Workspace = .tagTree
    @Published var title = "Clash Royale deck gameplay - ranked match"
    @Published var sourceID = "youtube:channel:demo"
    @Published var surface: EntrySurface = .feed
    /// Manual inspection uses a real platform binding so it exercises the
    /// same selected classifier type as the browser bridge.
    @Published var manualPlatformID = "youtube"
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
    @Published private(set) var hasStoredGeminiAPIKey = false
    @Published private(set) var auditRunningCandidateIDs = Set<UUID>()
    @Published private(set) var auditDiagnosticNotice: String?
    @Published var profile: ResourceProfile = .balanced
    @Published var resourceCacheCapacity = "50,000"
    @Published var allowIdleWork = true
    @Published var allowBackgroundSync = true
    @Published var allowLocalLLMAudit = false
    @Published var packageUpdateMode: PackageUpdateMode = .automatic
    @Published var trainingPositiveTags = ""
    @Published var trainingNegativeTags = ""
    @Published var trainingEpochs = "3"
    @Published private(set) var trainingNotice: String?
    @Published var backupOwnerCode = ""
    @Published var backupDirectory = ""
    @Published var backupEnabled = false
    @Published private(set) var hasBackupOwnerCode = false
    @Published private(set) var backupUnlocked = false
    @Published private(set) var backupNotice: String?
    /// Web actions normally receive a synchronous state refresh. Native sheets
    /// complete later, so they explicitly use this bounded local callback.
    var onWebStateChange: (() -> Void)?

    private var coordinator: LocalClassifierCoordinator?
    private var sharedHubClient: SharedHubClient?
    private var collectionDiagnostics: CollectionDiagnosticsStore?
    private(set) var creatorAvatarCache: CreatorAvatarCache?
    private var latestLedgerID: UUID?
    private var testingProviderProfileIDs = Set<String>()
    private var successfulProviderTestProfileIDs = Set<String>()
    private let vaultServiceEndpoint: VaultServiceEndpoint
    /// Model names are fetched from the selected provider on demand and remain
    /// in memory only. They are not part of a credential connection or the
    /// workspace catalog.
    private var providerModelCatalogs = [String: [String]]()
    private var providerModelCatalogErrors = [String: String]()
    private var loadingProviderModelProfileIDs = Set<String>()
    @Published private(set) var providerClassificationRunning = false
    @Published private(set) var creatorAvatarBackfillRunning = false
    @Published private(set) var creatorAvatarBackfillFoundCount: Int?

    init() {
        do {
            self.vaultServiceEndpoint = VaultServiceEndpoint.current()
            let package = try SeedPackageLoader.bundled()
            let appSupport = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let vaultDirectory = appSupport.appendingPathComponent("VaultClassifier", isDirectory: true)
            let collectionDiagnostics = CollectionDiagnosticsStore(fileURL: vaultDirectory.appendingPathComponent("collection-diagnostics.json"))
            self.collectionDiagnostics = collectionDiagnostics
            self.creatorAvatarCache = CreatorAvatarCache(directory: vaultDirectory.appendingPathComponent("creator-avatars", isDirectory: true))
            collectionDiagnostics.record(event: "app-started", outcome: "ready")
            let coordinator = try LocalClassifierCoordinator(verifiedPackage: package, stateFile: LocalStateFile(url: vaultDirectory.appendingPathComponent("state.json")), defaultPolicies: [StarterPolicies.clashRoyale])
            self.coordinator = coordinator
            self.policies = coordinator.policies()
            self.localState = coordinator.snapshot()
            try migrateLegacyProviderCredentials()
            self.manualPlatformID = self.localState?.workspaceCatalog.bindings.first?.id ?? "manual"
            loadResourceSettings(from: coordinator.snapshot().settings)
            loadAuditConfiguration(from: coordinator.snapshot().auditState.configuration)
            loadBackupConfiguration(from: coordinator.snapshot().backupConfiguration)
            self.hasStoredGeminiAPIKey = PersonalAuditCredentialStore.hasGeminiAPIKey()
            self.hasBackupOwnerCode = LocalBackupOwnerCodeStore.hasOwnerCode
            let sharedHubClient = SharedHubClient()
            self.sharedHubClient = sharedHubClient
            sharedHubClient.onRequest = { [weak self] request in
                self?.handleSharedHubRequest(request) ?? .failure("classifier-unavailable")
            }
            sharedHubClient.onStateChange = { [weak self, weak sharedHubClient] in
                guard let self else { return }
                let hubError = sharedHubClient?.error ?? ""
                self.collectionDiagnostics?.record(
                    event: "hub-state",
                    detail: hubError.isEmpty ? nil : hubError,
                    outcome: sharedHubClient?.state.rawValue ?? "off"
                )
                self.onWebStateChange?()
            }
            LocalClassifierHub.shared.onStateChange = { [weak self] in
                Task { @MainActor in self?.onWebStateChange?() }
            }
            sharedHubClient.connect()
            loadFixedProviderModelCatalogsAtLaunch()
            startActiveLLMClassification()
        } catch {
            issue = error.localizedDescription
        }
    }

    /// Provider Keychain storage is retired. Consume any previous local record
    /// once, move a valid credential into the local workspace profile, then
    /// remove the former Keychain item so no compatibility path remains.
    private func migrateLegacyProviderCredentials() throws {
        guard var catalog = localState?.workspaceCatalog else {
            LegacyProviderCredentialMigration.purgeRemaining()
            return
        }
        defer { LegacyProviderCredentialMigration.purgeRemaining() }
        var changed = false
        for index in catalog.providerProfiles.indices {
            let profileID = catalog.providerProfiles[index].id
            let legacy = LegacyProviderCredentialMigration.consume(profileID: profileID)
            guard catalog.providerProfiles[index].credential == nil,
                  let legacy else { continue }
            let descriptor = ProviderProtocolRegistry.descriptor(for: catalog.providerProfiles[index].type)
            guard (try? legacy.validate(for: descriptor)) != nil else { continue }
            catalog.providerProfiles[index].credential = legacy
            catalog.providerProfiles[index].updatedAtMilliseconds = WorkspaceCatalog.now()
            changed = true
        }
        guard changed else { return }
        try coordinator?.updateWorkspaceCatalog(catalog)
        localState = coordinator?.snapshot()
    }

    private func handleSharedHubRequest(_ request: SharedHubClient.Request) -> SharedHubClient.Reply {
        do {
            guard let coordinator else { return .failure("classifier-unavailable") }
            switch request.operation {
            case .bridgeInfo:
                _ = try JSONDecoder().decode(NativeBridgeInfoRequest.self, from: request.bodyData)
                let response = NativeBridgeInfoResponse(policies: coordinator.policies().prefix(64).map {
                    NativeBridgePolicy(id: $0.id, name: $0.name)
                })
                return try sharedHubReply(response)
            case .collectionInfo:
                _ = try JSONDecoder().decode(NativeCollectionInfoRequest.self, from: request.bodyData)
                let response = NativeCollectionInfoResponse(enabledPlatformIDs: coordinator.enabledCollectionPlatformIDs())
                collectionDiagnostics?.record(event: "collection-info-served", outcome: response.enabledPlatformIDs.isEmpty ? "disabled" : "enabled")
                return try sharedHubReply(response)
            case .diagnostic:
                let diagnostic = try JSONDecoder().decode(NativeCollectionDiagnosticRequest.self, from: request.bodyData)
                try diagnostic.validate()
                collectionDiagnostics?.record(
                    platformID: diagnostic.platformID,
                    event: diagnostic.event.rawValue,
                    detail: diagnostic.detail?.rawValue,
                    outcome: "received"
                )
                onWebStateChange?()
                return try sharedHubReply(NativeCollectionDiagnosticResponse(accepted: true))
            case .collect:
                let request = try JSONDecoder().decode(NativeCollectionRequest.self, from: request.bodyData)
                collectionDiagnostics?.record(platformID: request.entry.platform, event: "collection-received", outcome: "received")
                let inserted = try coordinator.collectPlatformEntry(request.entry)
                cacheCreatorAvatar(from: request.entry)
                collectionDiagnostics?.record(platformID: request.entry.platform, event: "collection-stored", outcome: inserted ? "inserted" : "duplicate")
                // Browser collection bypasses WebKit actions, so publish the
                // freshly persisted catalog to the already-open app now.
                refreshLocalState()
                onWebStateChange?()
                startActiveLLMClassification(platformID: request.entry.platform)
                return try sharedHubReply(NativeCollectionResponse(accepted: true, inserted: inserted))
            case .classify:
                let classification = try JSONDecoder().decode(NativeClassificationRequest.self, from: request.bodyData)
                let output = try coordinator.classifyWithLedger(classification.entry)
                return try sharedHubReply(NativeClassificationResponse(result: output.result, ledgerID: output.ledgerID))
            case .correct:
                let correction = try JSONDecoder().decode(NativeCorrectionRequest.self, from: request.bodyData)
                try coordinator.setCorrection(ledgerID: correction.ledgerID, correction: correction.correction)
                return try sharedHubReply(NativeCorrectionResponse(accepted: true))
            }
        } catch {
            collectionDiagnostics?.record(event: "request-rejected", outcome: "rejected")
            onWebStateChange?()
            return .failure(error.localizedDescription)
        }
    }

    private func cacheCreatorAvatar(from entry: EntryEvidence) {
        guard case .string(let avatarURL)? = entry.evidence.metadata["creatorAvatarURL"],
              CreatorAvatarURLPolicy.isAccepted(platformID: entry.platform, value: avatarURL) else {
            return
        }
        cacheCreatorAvatar(remoteURL: avatarURL)
    }

    private func cacheCreatorAvatar(remoteURL: String) {
        creatorAvatarCache?.cache(remoteURL: remoteURL) { [weak self] in
            Task { @MainActor in self?.onWebStateChange?() }
        }
    }

    private func sharedHubReply<Body: Encodable>(_ body: Body) throws -> SharedHubClient.Reply {
        let encoded = try JSONEncoder().encode(body)
        guard let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any],
              SharedBrowserBridgeProtocol.isValidBody(object) else {
            return .failure("classifier-response-invalid")
        }
        return .success(object)
    }

    func connectSharedHub() {
        sharedHubClient?.connect()
        issue = nil
    }

    func disconnectSharedHub() {
        sharedHubClient?.disconnect()
        issue = nil
    }

    func classify() {
        do {
            guard let coordinator else { return }
            let entry = currentManualEntry()
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
        if let bindings = localState?.workspaceCatalog.bindings,
           !bindings.contains(where: { $0.id == manualPlatformID }) {
            manualPlatformID = bindings.first?.id ?? "manual"
        }
    }

    func createProviderProfile(typeRaw: String) {
        do {
            guard let type = APIKeyProviderType(rawValue: typeRaw),
                  var catalog = localState?.workspaceCatalog else {
                throw WebBridgeInputError.invalidChoice("provider type")
            }
            catalog.providerProfiles.append(.init(type: type))
            try coordinator?.updateWorkspaceCatalog(catalog)
            refreshLocalState()
            issue = nil
        } catch { issue = error.localizedDescription }
    }

    /// A provider test is always an explicit user action. It sends either the
    /// fixed harmless language-model prompt or a bounded provider-specific
    /// platform health request, never browser evidence or catalog data, and
    /// records no credential or headers.
    func testProviderProfile(
        profileID: String,
        rawCredential: String? = nil,
        clearCredential: Bool = false,
        customEndpoint: String? = nil,
        testModelIdentifier: String? = nil,
        protocolConfiguration: [String: String]? = nil
    ) {
        guard !testingProviderProfileIDs.contains(profileID) else { return }
        successfulProviderTestProfileIDs.remove(profileID)
        let profile: APIKeyProviderProfile
        do {
            profile = try applyProviderConnection(
                profileID: profileID,
                rawCredential: rawCredential,
                clearCredential: clearCredential,
                customEndpoint: customEndpoint,
                testModelIdentifier: testModelIdentifier,
                protocolConfiguration: protocolConfiguration
            )
        } catch {
            issue = error.localizedDescription
            return
        }
        testingProviderProfileIDs.insert(profileID)
        issue = nil
        Task { [weak self] in
            guard let self else { return }
            let startedAt = Date()
            var prepared: ProviderTestPreparedRequest?
            do {
                let credential = try self.providerCredential(for: profileID)
                let request = try ProviderTestProtocol.prepare(profile: profile)
                prepared = request
                var urlRequest = URLRequest(url: request.plan.url)
                urlRequest.httpMethod = request.plan.method
                urlRequest.httpBody = request.body.isEmpty ? nil : request.body
                urlRequest.timeoutInterval = 30
                request.plan.headers.forEach { urlRequest.setValue($0.value, forHTTPHeaderField: $0.key) }
                try self.apply(credential: credential, to: &urlRequest, plan: request.plan)
                let (data, response) = try await URLSession.shared.data(for: urlRequest)
                let duration = max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
                guard let http = response as? HTTPURLResponse else { throw ProviderTestProtocolError.invalidResponse }
                guard (200..<300).contains(http.statusCode) else { throw ProviderTestHTTPError.status(http.statusCode) }
                let parsed = try ProviderTestProtocol.parseResponse(data, format: request.plan.bodyFormat, operation: request.operation)
                try self.appendProviderTestRecord(.init(
                    profileID: profile.id,
                    provider: profile.type.rawValue,
                    model: ProviderTestProtocol.modelIdentifier(for: profile),
                    operation: request.operation.rawValue,
                    endpoint: ProviderTestProtocol.safeEndpoint(request.plan.url),
                    method: request.plan.method,
                    statusCode: http.statusCode,
                    durationMilliseconds: duration,
                    inputTokens: parsed.usage.inputTokens,
                    outputTokens: parsed.usage.outputTokens,
                    outcome: "succeeded"
                ))
                self.successfulProviderTestProfileIDs.insert(profileID)
                self.issue = nil
            } catch {
                let duration = max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
                if let prepared {
                    try? self.appendProviderTestRecord(.init(
                        profileID: profile.id,
                        provider: profile.type.rawValue,
                        model: ProviderTestProtocol.modelIdentifier(for: profile),
                        operation: prepared.operation.rawValue,
                        endpoint: ProviderTestProtocol.safeEndpoint(prepared.plan.url),
                        method: prepared.plan.method,
                        statusCode: nil,
                        durationMilliseconds: duration,
                        inputTokens: nil,
                        outputTokens: nil,
                        outcome: "failed"
                    ))
                }
                self.successfulProviderTestProfileIDs.remove(profileID)
                self.issue = error.localizedDescription
            }
            self.testingProviderProfileIDs.remove(profileID)
            self.onWebStateChange?()
        }
    }

    /// Fixed provider types are loaded once at launch. Custom endpoints keep
    /// one explicit fetch because their operator controls the model service.
    /// Results remain transient; a classifier type persists only its chosen
    /// identifier.
    private func fetchProviderModelCatalog(profileID: String, reportFailure: Bool) {
        guard !loadingProviderModelProfileIDs.contains(profileID) else { return }
        do {
            guard let profile = localState?.workspaceCatalog.providerProfiles.first(where: { $0.id == profileID }) else {
                throw WebBridgeInputError.invalidChoice("provider profile")
            }
            let plan = try ProviderModelCatalogProtocol.prepare(profile: profile, vaultService: vaultServiceEndpoint)
            loadingProviderModelProfileIDs.insert(profileID)
            providerModelCatalogErrors.removeValue(forKey: profileID)
            issue = nil
            Task { [weak self] in
                guard let self else { return }
                do {
                    let credential = plan.requiredCredentialFields.isEmpty
                        ? .init(values: [:])
                        : try self.providerCredential(for: profileID)
                    let response = try await self.performProviderRequest(plan: plan, body: nil, credential: credential, timeout: 30)
                    self.providerModelCatalogs[profileID] = try ProviderModelCatalogProtocol.parse(response.data, providerType: profile.type)
                    self.issue = nil
                } catch {
                    self.providerModelCatalogs.removeValue(forKey: profileID)
                    self.providerModelCatalogErrors[profileID] = error.localizedDescription
                    if reportFailure { self.issue = error.localizedDescription }
                }
                self.loadingProviderModelProfileIDs.remove(profileID)
                self.onWebStateChange?()
            }
        } catch {
            providerModelCatalogErrors[profileID] = error.localizedDescription
            if reportFailure { issue = error.localizedDescription }
            onWebStateChange?()
        }
    }

    func fetchCustomProviderModelCatalog(profileID: String) {
        guard let profile = localState?.workspaceCatalog.providerProfiles.first(where: { $0.id == profileID }),
              !ProviderModelCatalogProtocol.usesVaultCatalog(profile.type) else {
            issue = WebBridgeInputError.invalidChoice("custom or compatible provider profile").localizedDescription
            return
        }
        fetchProviderModelCatalog(profileID: profileID, reportFailure: true)
    }

    private func loadFixedProviderModelCatalogsAtLaunch() {
        guard let catalog = localState?.workspaceCatalog else { return }
        for profile in catalog.providerProfiles where
            profile.type.supportsLLMConfiguration && ProviderModelCatalogProtocol.usesVaultCatalog(profile.type) {
            fetchProviderModelCatalog(profileID: profile.id, reportFailure: false)
        }
    }

    private func llmAllowedTagIDs(
        taxonomy: Taxonomy,
        configuration: LLMAssistConfiguration
    ) -> Set<String> {
        if configuration.restrictToLeafTags {
            return taxonomy.predictableLeafIDs
        }
        return Set(taxonomy.nodes.values.filter(\.predictable).map(\.id))
    }

    private func outputTokensUsedToday(
        in catalog: WorkspaceCatalog,
        classifierTypeID: String,
        now: Date = Date()
    ) -> Int {
        let start = Calendar.current.startOfDay(for: now)
        let startMilliseconds = Int64(start.timeIntervalSince1970 * 1_000)
        return catalog.providerRequestRecords.reduce(into: 0) { total, record in
            guard record.classifierTypeID == classifierTypeID,
                  record.outcome == "succeeded",
                  record.createdAtMilliseconds >= startMilliseconds else {
                return
            }
            total += max(0, record.outputTokens ?? 0)
        }
    }

    private func remainingLLMOutputTokens(
        in catalog: WorkspaceCatalog,
        classifierTypeID: String,
        configuration: LLMAssistConfiguration
    ) throws -> Int {
        let remaining = configuration.dailyOutputTokenLimit - outputTokensUsedToday(
            in: catalog,
            classifierTypeID: classifierTypeID
        )
        guard remaining > 0 else {
            throw WebBridgeInputError.invalidChoice("daily output token budget")
        }
        return min(ProviderClassificationProtocol.maximumOutputTokens, remaining)
    }

    /// Generic provider classification is intentionally available only from
    /// this manual inspector action. Shared-hub/browser requests always call
    /// the coordinator's local dispatch and can never enter this method.
    func classifyCurrentEntryWithLLM() {
        guard !providerClassificationRunning else { return }
        do {
            guard let catalog = localState?.workspaceCatalog,
                  let binding = catalog.bindings.first(where: { $0.id == manualPlatformID }),
                  CollectionPlatformRegistry.definition(for: binding.id)?.supportsLLMAssist == true,
                  let classifierTypeID = binding.activeClassifierTypeID,
                  let classifierType = catalog.classifierTypes.first(where: { $0.id == classifierTypeID }),
                  let llmAssist = classifierType.llmAssistConfiguration,
                  let profile = catalog.providerProfiles.first(where: { $0.id == llmAssist.providerProfileID }),
                  let tree = catalog.trees.first(where: { $0.id == binding.treeID }) else {
                throw WebBridgeInputError.invalidChoice("manual LLM classifier type")
            }
            let taxonomy = try tree.inferenceTaxonomy()
            let allowedTagIDs = llmAllowedTagIDs(taxonomy: taxonomy, configuration: llmAssist)
            let outputTokenLimit = try remainingLLMOutputTokens(
                in: catalog,
                classifierTypeID: classifierType.id,
                configuration: llmAssist
            )
            let entry = currentManualEntry()
            let recordPlan = try ProviderClassificationProtocol.prepare(
                profile: profile,
                configuration: llmAssist,
                entry: entry,
                allowedTagIDs: allowedTagIDs,
                maximumOutputTokens: outputTokenLimit
            )
            providerClassificationRunning = true
            issue = nil
            Task { [weak self] in
                guard let self else { return }
                let startedAt = Date()
                do {
                    let run = try await self.runProviderClassification(
                        profile: profile,
                        configuration: llmAssist,
                        entry: entry,
                        allowedTagIDs: allowedTagIDs,
                        catalog: catalog,
                        maximumOutputTokens: outputTokenLimit
                    )
                    let duration = max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
                    let labelIDs = try ProviderClassificationProtocol.parseLabelIDs(
                        run.content,
                        allowedTagIDs: allowedTagIDs,
                        maximumTagCount: llmAssist.maximumTagCount
                    )
                    self.result = ProviderClassificationProtocol.result(
                        entry: entry,
                        classifierType: classifierType,
                        profile: profile,
                        configuration: llmAssist,
                        taxonomy: taxonomy,
                        policies: self.policies,
                        labelIDs: labelIDs
                    )
                    self.latestLedgerID = nil
                    // Individual-entry provider output is an inspection result
                    // only. Durable dataset labels are creator classifications:
                    // the user labels a retained creator explicitly, or starts
                    // the creator-specific LLM action below. Do not create an
                    // unreviewable entry row that can drift from that source of
                    // truth.
                    try self.appendProviderTestRecord(.init(
                        profileID: profile.id,
                        provider: profile.type.rawValue,
                        model: llmAssist.modelIdentifier,
                        operation: "classify",
                        endpoint: ProviderTestProtocol.safeEndpoint(recordPlan.plan.url),
                        method: recordPlan.plan.method,
                        statusCode: run.statusCode,
                        durationMilliseconds: duration,
                        inputTokens: run.usage.inputTokens,
                        outputTokens: run.usage.outputTokens ?? outputTokenLimit,
                        classifierTypeID: classifierType.id,
                        outcome: "succeeded"
                    ))
                    self.issue = nil
                } catch {
                    let duration = max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
                    try? self.appendProviderTestRecord(.init(
                        profileID: profile.id,
                        provider: profile.type.rawValue,
                        model: llmAssist.modelIdentifier,
                        operation: "classify",
                        endpoint: ProviderTestProtocol.safeEndpoint(recordPlan.plan.url),
                        method: recordPlan.plan.method,
                        statusCode: nil,
                        durationMilliseconds: duration,
                        inputTokens: nil,
                        outputTokens: nil,
                        classifierTypeID: classifierType.id,
                        outcome: "failed"
                    ))
                    self.issue = error.localizedDescription
                }
                self.providerClassificationRunning = false
                self.onWebStateChange?()
            }
        } catch {
            issue = error.localizedDescription
        }
    }

    private func providerCredential(for profileID: String) throws -> ProviderCredentialRecord {
        if let profile = localState?.workspaceCatalog.providerProfiles.first(where: { $0.id == profileID }),
           let credential = profile.credential {
            return credential
        }
        if let profile = localState?.workspaceCatalog.providerProfiles.first(where: { $0.id == profileID }),
           ProviderProtocolRegistry.descriptor(for: profile.type).credentialFields.isEmpty {
            return .init(values: [:])
        }
        throw ProviderTestProtocolError.missingCredential
    }

    private struct ProviderClassificationRun {
        var prompt: String
        var content: String
        var usage: ProviderTestUsage
        var statusCode: Int
    }

    /// Runs an explicit classification through the selected LLM. The one
    /// platform profile selected by this classifier type is an optional,
    /// bounded local tool; without a ready selected tool this remains direct.
    private func runProviderClassification(
        profile: APIKeyProviderProfile,
        configuration: LLMAssistConfiguration,
        entry: EntryEvidence,
        allowedTagIDs: Set<String>,
        catalog: WorkspaceCatalog,
        maximumOutputTokens: Int
    ) async throws -> ProviderClassificationRun {
        let mainCredential = try providerCredential(for: profile.id)
        let expectedToolType = CollectionPlatformRegistry.definition(for: entry.platform)?.apiProviderType
        let selectedTools: [APIKeyProviderProfile]
        if configuration.externalToolEnabled, let expectedToolType {
            selectedTools = catalog.providerProfiles
                .filter { $0.type == expectedToolType }
                .sorted { lhs, rhs in
                    if lhs.updatedAtMilliseconds == rhs.updatedAtMilliseconds { return lhs.id < rhs.id }
                    return lhs.updatedAtMilliseconds > rhs.updatedAtMilliseconds
                }
                .prefix(1)
                .map { $0 }
        } else {
            selectedTools = []
        }
        let readyTools = selectedTools.first { toolProfile in
            let descriptor = ProviderProtocolRegistry.descriptor(for: toolProfile.type)
            guard !descriptor.supportsLLMConfiguration,
                  (try? toolProfile.validateForDispatch()) != nil else { return false }
            return descriptor.credentialFields.isEmpty || (try? providerCredential(for: toolProfile.id)) != nil
        }.map { [$0] } ?? []

        guard !readyTools.isEmpty else {
            let request = try ProviderClassificationProtocol.prepare(
                profile: profile,
                configuration: configuration,
                entry: entry,
                allowedTagIDs: allowedTagIDs,
                maximumOutputTokens: maximumOutputTokens
            )
            let response = try await performProviderRequest(plan: request.plan, body: request.body, credential: mainCredential, timeout: 30)
            let parsed = try ProviderTestProtocol.parseResponse(response.data, format: request.plan.bodyFormat, operation: request.operation)
            return .init(prompt: request.prompt, content: parsed.content, usage: parsed.usage, statusCode: response.response.statusCode)
        }

        var request = try ProviderToolCallingProtocol.prepare(
            profile: profile,
            configuration: configuration,
            entry: entry,
            allowedTagIDs: allowedTagIDs,
            toolProfiles: readyTools,
            maximumOutputTokens: maximumOutputTokens
        )
        var totalInputTokens: Int?
        var totalOutputTokens: Int?
        var totalToolCalls = 0
        var remainingOutputTokens = maximumOutputTokens
        for _ in 0..<3 {
            let response = try await performProviderRequest(plan: request.plan, body: request.body, credential: mainCredential, timeout: 30)
            let turn = try ProviderToolCallingProtocol.parseResponse(response.data, format: request.plan.bodyFormat)
            totalInputTokens = addingTokenUsage(totalInputTokens, turn.usage.inputTokens)
            totalOutputTokens = addingTokenUsage(totalOutputTokens, turn.usage.outputTokens)
            remainingOutputTokens -= turn.usage.outputTokens ?? request.maximumOutputTokens
            guard !turn.toolCalls.isEmpty else {
                return .init(
                    prompt: request.prompt,
                    content: turn.content,
                    usage: .init(inputTokens: totalInputTokens, outputTokens: totalOutputTokens),
                    statusCode: response.response.statusCode
                )
            }
            guard remainingOutputTokens > 0 else {
                throw WebBridgeInputError.invalidChoice("remaining daily output token budget")
            }
            guard totalToolCalls + turn.toolCalls.count <= 4 else {
                throw ProviderToolCallingProtocolError.invalidToolContinuation
            }
            totalToolCalls += turn.toolCalls.count
            var results: [ProviderToolCallingResult] = []
            for call in turn.toolCalls {
                results.append(await executeExternalToolCall(call, definitions: request.toolDefinitions, profiles: readyTools, entry: entry))
            }
            request = try ProviderToolCallingProtocol.continueRequest(
                prepared: request,
                profile: profile,
                configuration: configuration,
                turn: turn,
                results: results,
                maximumOutputTokens: min(ProviderToolCallingProtocol.maximumOutputTokens, remainingOutputTokens)
            )
        }
        throw ProviderToolCallingProtocolError.invalidToolContinuation
    }

    private func addingTokenUsage(_ current: Int?, _ additional: Int?) -> Int? {
        guard let additional else { return current }
        return (current ?? 0) + additional
    }

    /// Chooses the one newest usable API connection for this platform. The
    /// selection is local and deterministic; the UI never exposes profile
    /// selection for a classifier type.
    private func readyPlatformAPIProfile(
        in catalog: WorkspaceCatalog,
        platformID: String
    ) -> APIKeyProviderProfile? {
        guard let expectedType = CollectionPlatformRegistry.definition(for: platformID)?.apiProviderType else {
            return nil
        }
        return catalog.providerProfiles
            .filter { $0.type == expectedType }
            .sorted { lhs, rhs in
                if lhs.updatedAtMilliseconds == rhs.updatedAtMilliseconds { return lhs.id < rhs.id }
                return lhs.updatedAtMilliseconds > rhs.updatedAtMilliseconds
            }
            .first { profile in
                let descriptor = ProviderProtocolRegistry.descriptor(for: profile.type)
                guard !descriptor.supportsLLMConfiguration,
                      (try? profile.validateForDispatch()) != nil else {
                    return false
                }
                return descriptor.credentialFields.isEmpty || (try? providerCredential(for: profile.id)) != nil
            }
    }

    private func performProviderRequest(
        plan: ProviderRequestPlan,
        body: Data?,
        credential: ProviderCredentialRecord,
        timeout: TimeInterval
    ) async throws -> (data: Data, response: HTTPURLResponse) {
        var request = URLRequest(url: plan.url)
        request.httpMethod = plan.method
        request.httpBody = body
        request.timeoutInterval = timeout
        plan.headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        try apply(credential: credential, to: &request, plan: plan)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderTestProtocolError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw ProviderTestHTTPError.status(http.statusCode) }
        return (data, http)
    }

    private func executeExternalToolCall(
        _ call: ExternalPlatformToolCall,
        definitions: [ExternalPlatformToolDefinition],
        profiles: [APIKeyProviderProfile],
        entry: EntryEvidence
    ) async -> ProviderToolCallingResult {
        guard let definition = definitions.first(where: { $0.name == call.name }),
              let profile = profiles.first(where: { $0.id == definition.profileID }) else {
            return .init(id: call.id, name: call.name, content: "{\"ok\":false,\"error\":\"Unknown external-data tool.\"}")
        }
        let startedAt = Date()
        var prepared: ExternalPlatformPreparedRequest?
        do {
            let request = try ExternalPlatformToolProtocol.prepare(profile: profile, entry: entry, call: call)
            prepared = request
            let credential = try providerCredential(for: profile.id)
            var urlRequest = URLRequest(url: request.plan.url)
            urlRequest.httpMethod = request.plan.method
            urlRequest.httpBody = request.body
            urlRequest.timeoutInterval = 20
            request.plan.headers.forEach { urlRequest.setValue($0.value, forHTTPHeaderField: $0.key) }
            try apply(credential: credential, to: &urlRequest, plan: request.plan)
            let (data, response) = try await URLSession.shared.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else { throw ProviderTestProtocolError.invalidResponse }
            recordPlatformAPIRequest(
                profile: profile,
                plan: request.plan,
                statusCode: http.statusCode,
                durationMilliseconds: max(0, Int(Date().timeIntervalSince(startedAt) * 1_000)),
                outcome: (200..<300).contains(http.statusCode) ? "succeeded" : "failed"
            )
            return .init(
                id: call.id,
                name: call.name,
                content: ExternalPlatformToolProtocol.result(
                    data: data,
                    statusCode: http.statusCode,
                    providerType: request.providerType,
                    target: request.target
                )
            )
        } catch {
            if let prepared {
                recordPlatformAPIRequest(
                    profile: profile,
                    plan: prepared.plan,
                    statusCode: nil,
                    durationMilliseconds: max(0, Int(Date().timeIntervalSince(startedAt) * 1_000)),
                    outcome: "failed"
                )
            }
            return .init(
                id: call.id,
                name: call.name,
                content: ExternalPlatformToolProtocol.failureResult(
                    providerType: profile.type,
                    target: .entry,
                    message: error.localizedDescription
                )
            )
        }
    }

    /// Uses a platform credential only after public creator-page discovery has
    /// produced no image URL. The API response is bounded and its image URL is
    /// checked against the same platform-owned-host policy before persistence.
    private func fetchCreatorAvatarURLUsingPlatformAPI(
        candidate: CreatorAvatarBackfill.Candidate,
        profile: APIKeyProviderProfile
    ) async -> String? {
        let startedAt = Date()
        var prepared: ExternalPlatformPreparedRequest?
        do {
            let call = ExternalPlatformToolCall(
                id: UUID().uuidString,
                name: ExternalPlatformToolProtocol.toolName(for: profile),
                arguments: #"{"target":"creator"}"#
            )
            let request = try ExternalPlatformToolProtocol.prepare(profile: profile, entry: .init(
                platform: candidate.platformID,
                sourceID: candidate.creatorID,
                surface: .page,
                evidence: .init(title: "Creator profile")
            ), call: call)
            prepared = request
            let credential = try providerCredential(for: profile.id)
            var urlRequest = URLRequest(url: request.plan.url)
            urlRequest.httpMethod = request.plan.method
            urlRequest.httpBody = request.body
            urlRequest.timeoutInterval = 20
            request.plan.headers.forEach { urlRequest.setValue($0.value, forHTTPHeaderField: $0.key) }
            try apply(credential: credential, to: &urlRequest, plan: request.plan)
            let (data, response) = try await URLSession.shared.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else { throw ProviderTestProtocolError.invalidResponse }
            recordPlatformAPIRequest(
                profile: profile,
                plan: request.plan,
                statusCode: http.statusCode,
                durationMilliseconds: max(0, Int(Date().timeIntervalSince(startedAt) * 1_000)),
                outcome: (200..<300).contains(http.statusCode) ? "succeeded" : "failed"
            )
            guard (200..<300).contains(http.statusCode),
                  let avatarURL = ExternalPlatformToolProtocol.creatorAvatarURL(
                      data: data,
                      providerType: request.providerType
                  ),
                  CreatorAvatarURLPolicy.isAccepted(platformID: candidate.platformID, value: avatarURL) else {
                return nil
            }
            return avatarURL
        } catch {
            if let prepared {
                recordPlatformAPIRequest(
                    profile: profile,
                    plan: prepared.plan,
                    statusCode: nil,
                    durationMilliseconds: max(0, Int(Date().timeIntervalSince(startedAt) * 1_000)),
                    outcome: "failed"
                )
            }
            return nil
        }
    }

    private func apply(credential: ProviderCredentialRecord, to request: inout URLRequest, plan: ProviderRequestPlan) throws {
        func value(_ preferred: ProviderCredentialField) throws -> String {
            guard let value = credential.values[preferred] ?? credential.values[.apiKey] ?? credential.values[.bearerToken] else {
                throw ProviderTestProtocolError.missingCredential
            }
            return value
        }
        switch plan.authentication {
        case .none:
            return
        case .bearerToken, .bearerTokenAndClientID:
            request.setValue("Bearer \(try value(.bearerToken))", forHTTPHeaderField: plan.authenticationHeader ?? "Authorization")
        case .apiKeyHeader:
            request.setValue(try value(.apiKey), forHTTPHeaderField: plan.authenticationHeader ?? "X-API-Key")
        case .apiKeyQuery:
            guard var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false) else { throw ProviderTestProtocolError.invalidResponse }
            components.queryItems = (components.queryItems ?? []) + [.init(name: plan.authenticationHeader ?? "key", value: try value(.apiKey))]
            request.url = components.url
        case .awsSignatureV4:
            throw ProviderTestProtocolError.unsupportedProvider
        }
    }

    private func appendProviderTestRecord(_ record: ProviderRequestRecord) throws {
        guard var catalog = localState?.workspaceCatalog else { return }
        catalog.providerRequestRecords.insert(record, at: 0)
        // The daily LLM allowance is calculated from successful records. Keep
        // every current-day classified output while trimming unrelated history;
        // otherwise a long day could discard its own accounting and bypass the
        // configured budget.
        let todayStartMilliseconds = Int64(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 * 1_000)
        let budgetRecords = catalog.providerRequestRecords.filter {
            $0.classifierTypeID != nil &&
                $0.outcome == "succeeded" &&
                $0.createdAtMilliseconds >= todayStartMilliseconds
        }
        let budgetRecordIDs = Set(budgetRecords.map(\.id))
        let otherRecords = catalog.providerRequestRecords.filter { !budgetRecordIDs.contains($0.id) }
        catalog.providerRequestRecords = budgetRecords + Array(otherRecords.prefix(100))
        let isLanguageModel = APIKeyProviderType(rawValue: record.provider)
            .map { ProviderProtocolRegistry.descriptor(for: $0).supportsLLMConfiguration } ?? false
        if record.outcome == "succeeded", isLanguageModel {
            catalog.tokenUsage.insert(.init(
                provider: record.provider,
                model: record.model,
                inputTokens: record.inputTokens ?? 0,
                outputTokens: record.outputTokens ?? 0,
                status: record.outcome
            ), at: 0)
            catalog.tokenUsage = Array(catalog.tokenUsage.prefix(200))
        }
        try coordinator?.updateWorkspaceCatalog(catalog)
        refreshLocalState()
    }

    /// Platform connections use request counts, not language-model tokens.
    /// Store only bounded transport metadata so the compact profile panel can
    /// show local API-call usage without retaining request or response bodies.
    private func recordPlatformAPIRequest(
        profile: APIKeyProviderProfile,
        plan: ProviderRequestPlan,
        statusCode: Int?,
        durationMilliseconds: Int,
        outcome: String
    ) {
        try? appendProviderTestRecord(.init(
            profileID: profile.id,
            provider: profile.type.rawValue,
            model: "",
            operation: ProviderOperation.readPublicContent.rawValue,
            endpoint: ProviderTestProtocol.safeEndpoint(plan.url),
            method: plan.method,
            statusCode: statusCode,
            durationMilliseconds: durationMilliseconds,
            inputTokens: nil,
            outputTokens: nil,
            outcome: outcome
        ))
    }

    /// Stores the compact panel's local connection inputs. The WebView never
    /// receives the secret: its fixed dots mean preserve, a non-empty value
    /// replaces, and an explicit clear removes the saved local credential.
    private func applyProviderConnection(
        profileID: String,
        rawCredential: String?,
        clearCredential: Bool,
        customEndpoint: String?,
        testModelIdentifier: String?,
        protocolConfiguration: [String: String]?,
        refreshState: Bool = true
    ) throws -> APIKeyProviderProfile {
        guard var catalog = localState?.workspaceCatalog,
              let index = catalog.providerProfiles.firstIndex(where: { $0.id == profileID }) else {
            throw WebBridgeInputError.invalidChoice("provider profile")
        }
        var profile = catalog.providerProfiles[index]
        if let customEndpoint {
            let cleaned = customEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            profile.customEndpoint = cleaned.isEmpty ? nil : cleaned
        }
        if let testModelIdentifier {
            let cleaned = testModelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            profile.testModelIdentifier = cleaned.isEmpty ? nil : cleaned
        }
        if let protocolConfiguration {
            profile.protocolConfiguration = protocolConfiguration
        }
        let value = rawCredential?.trimmingCharacters(in: .whitespacesAndNewlines)
        let descriptor = ProviderProtocolRegistry.descriptor(for: profile.type)
        if clearCredential {
            guard value?.isEmpty != false else {
                throw WebBridgeInputError.invalidChoice("provider credential")
            }
            profile.credential = nil
        } else if let value, !value.isEmpty {
            guard descriptor.credentialFields.count == 1,
                  let field = descriptor.credentialFields.first else {
                throw WebBridgeInputError.invalidChoice("provider credential")
            }
            let credential = ProviderCredentialRecord(values: [field: value])
            try credential.validate(for: descriptor)
            profile.credential = credential
        }
        try profile.validate()
        profile.updatedAtMilliseconds = WorkspaceCatalog.now()
        catalog.providerProfiles[index] = profile
        try coordinator?.updateWorkspaceCatalog(catalog)
        if refreshState {
            refreshLocalState()
        } else {
            // Keep native state current for the next keystroke without making
            // WebKit rebuild the focused credential field.
            localState = coordinator?.snapshot()
        }
        return profile
    }

    /// Saves an edited credential as soon as its input changes. This action
    /// intentionally returns without publishing a WebView snapshot: input
    /// state must never be replaced while the user is typing.
    func saveProviderCredential(profileID: String, rawCredential: String, clearCredential: Bool) -> Bool {
        successfulProviderTestProfileIDs.remove(profileID)
        do {
            _ = try applyProviderConnection(
                profileID: profileID,
                rawCredential: rawCredential,
                clearCredential: clearCredential,
                customEndpoint: nil,
                testModelIdentifier: nil,
                protocolConfiguration: nil,
                refreshState: false
            )
            issue = nil
            return true
        } catch {
            issue = error.localizedDescription
            return false
        }
    }

    func updateProviderConnection(
        profileID: String,
        rawCredential: String? = nil,
        clearCredential: Bool = false,
        customEndpoint: String?,
        testModelIdentifier: String?,
        protocolConfiguration: [String: String]?
    ) {
        successfulProviderTestProfileIDs.remove(profileID)
        do {
            _ = try applyProviderConnection(
                profileID: profileID,
                rawCredential: rawCredential,
                clearCredential: clearCredential,
                customEndpoint: customEndpoint,
                testModelIdentifier: testModelIdentifier,
                protocolConfiguration: protocolConfiguration
            )
            issue = nil
        } catch {
            issue = error.localizedDescription
        }
    }

    func deleteProviderProfile(profileID: String) {
        do {
            guard var catalog = localState?.workspaceCatalog,
                  catalog.providerProfiles.contains(where: { $0.id == profileID }) else {
                throw WebBridgeInputError.invalidChoice("provider profile")
            }
            catalog.providerProfiles.removeAll(where: { $0.id == profileID })
            for index in catalog.classifierTypes.indices {
                guard let llmAssist = catalog.classifierTypes[index].llmAssistConfiguration else { continue }
                if llmAssist.providerProfileID == profileID {
                    catalog.classifierTypes[index].llmAssistConfiguration = nil
                }
            }
            catalog.providerRequestRecords.removeAll(where: { $0.profileID == profileID })
            successfulProviderTestProfileIDs.remove(profileID)
            try coordinator?.updateWorkspaceCatalog(catalog)
            refreshLocalState()
            issue = nil
        } catch { issue = error.localizedDescription }
    }

    func confirmProviderProfileDeletion(profileID: String) {
        guard localState?.workspaceCatalog.providerProfiles.contains(where: { $0.id == profileID }) == true else {
            issue = WebBridgeInputError.invalidChoice("provider profile").localizedDescription
            return
        }
        presentNativeConfirmation(
            title: "Delete provider profile?",
            message: "This removes the local API key or token and token-usage records. It cannot be undone.",
            confirmTitle: "Delete profile"
        ) { [weak self] in
            self?.deleteProviderProfile(profileID: profileID)
        }
    }

    func createTree(name: String) {
        do {
            let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { throw WebBridgeInputError.invalidChoice("tree name") }
            guard var catalog = localState?.workspaceCatalog else { return }
            catalog.trees.append(.init(name: cleaned, nodes: []))
            try coordinator?.updateWorkspaceCatalog(catalog)
            refreshLocalState()
        } catch { issue = error.localizedDescription }
    }

    func addCollectionPlatform(platformID: String) {
        do {
            guard let definition = CollectionPlatformRegistry.definition(for: platformID),
                  var catalog = localState?.workspaceCatalog else {
                throw WebBridgeInputError.invalidChoice("collection platform")
            }
            guard !catalog.bindings.contains(where: { $0.id == definition.id }) else {
                throw WebBridgeInputError.invalidChoice("collection platform already exists")
            }
            _ = try catalog.ensurePlatformBinding(definition.id)
            try coordinator?.updateWorkspaceCatalog(catalog)
            refreshLocalState()
            issue = nil
        } catch { issue = error.localizedDescription }
    }

    func deleteCollectionPlatform(platformID: String) {
        do {
            guard var catalog = localState?.workspaceCatalog,
                  catalog.removePlatformBinding(platformID) else {
                throw WebBridgeInputError.invalidChoice("collection platform")
            }
            try coordinator?.updateWorkspaceCatalog(catalog)
            refreshLocalState()
            issue = nil
        } catch { issue = error.localizedDescription }
    }

    func confirmCollectionPlatformDeletion(platformID: String) {
        guard let catalog = localState?.workspaceCatalog,
              let binding = catalog.bindings.first(where: { $0.id == platformID }) else {
            issue = WebBridgeInputError.invalidChoice("collection platform").localizedDescription
            return
        }
        let dataset = catalog.datasets.first(where: { $0.id == binding.datasetID })
        let entries = dataset?.collectedEntries.filter { $0.platformID == platformID }.count ?? 0
        let classifications = dataset?.creatorClassifications.filter { $0.platformID == platformID }.count ?? 0
        presentNativeConfirmation(
            title: "Delete \(binding.name)?",
            message: "This stops collection and removes \(entries) retained entries and \(classifications) creator classifications for this platform. Shared trees and classification data remain; models using this source are reset or removed.",
            confirmTitle: "Delete platform"
        ) { [weak self] in
            self?.deleteCollectionPlatform(platformID: platformID)
        }
    }

    func setCollectionEnabled(platformID: String, enabled: Bool) {
        do {
            guard var catalog = localState?.workspaceCatalog,
                  let bindingIndex = catalog.bindings.firstIndex(where: { $0.id == platformID }) else {
                throw WebBridgeInputError.invalidChoice("collection platform")
            }
            catalog.bindings[bindingIndex].collectionEnabled = enabled
            try coordinator?.updateWorkspaceCatalog(catalog)
            refreshLocalState()
            issue = nil
        } catch { issue = error.localizedDescription }
    }

    func clearCollectionDiagnostics() {
        collectionDiagnostics?.clear()
        onWebStateChange?()
    }

    func createLocalModel(name: String) {
        do {
            let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { throw WebBridgeInputError.invalidChoice("local model name") }
            guard var catalog = localState?.workspaceCatalog,
                  let binding = catalog.bindings.first(where: {
                      CollectionPlatformRegistry.definition(for: $0.id)?.supportsLocalModel == true
                  }),
                  let tree = catalog.trees.first(where: { $0.id == binding.treeID }),
                  let dataset = catalog.datasets.first(where: { $0.id == binding.datasetID }) else {
                throw WebBridgeInputError.invalidChoice("workspace assets")
            }
            catalog.models.append(.init(
                name: cleaned,
                treeID: tree.id,
                treeRevision: tree.revision,
                datasetID: dataset.id,
                datasetRevision: dataset.revision,
                trainingPlatformID: binding.id,
                trainingPlatformIDs: [binding.id]
            ))
            try coordinator?.updateWorkspaceCatalog(catalog)
            refreshLocalState()
            issue = nil
        } catch { issue = error.localizedDescription }
    }

    func renameLocalModel(modelID: String, name: String) {
        do {
            let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty,
                  var catalog = localState?.workspaceCatalog,
                  let modelIndex = catalog.models.firstIndex(where: { $0.id == modelID }) else {
                throw WebBridgeInputError.invalidChoice("local model")
            }
            catalog.models[modelIndex].name = cleaned
            try coordinator?.updateWorkspaceCatalog(catalog)
            refreshLocalState()
            issue = nil
        } catch { issue = error.localizedDescription }
    }

    func deleteLocalModel(modelID: String) {
        do {
            guard var catalog = localState?.workspaceCatalog,
                  let modelIndex = catalog.models.firstIndex(where: { $0.id == modelID }) else {
                throw WebBridgeInputError.invalidChoice("local model")
            }
            catalog.models.remove(at: modelIndex)
            for bindingIndex in catalog.bindings.indices where catalog.bindings[bindingIndex].activeModelID == modelID {
                catalog.bindings[bindingIndex].activeModelID = nil
                catalog.bindings[bindingIndex].activeClassifierTypeID = nil
            }
            try coordinator?.updateWorkspaceCatalog(catalog)
            refreshLocalState()
            issue = nil
        } catch { issue = error.localizedDescription }
    }

    func confirmLocalModelDeletion(modelID: String) {
        guard localState?.workspaceCatalog.models.contains(where: { $0.id == modelID }) == true else {
            issue = WebBridgeInputError.invalidChoice("local model").localizedDescription
            return
        }
        presentNativeConfirmation(
            title: "Delete local model?",
            message: "This removes the local model and clears any active platform binding. It cannot be undone.",
            confirmTitle: "Delete model"
        ) { [weak self] in
            self?.deleteLocalModel(modelID: modelID)
        }
    }

    func createClassifierType(name: String) {
        do {
            let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty,
                  cleaned.count <= ClassifierTypeAsset.maximumNameLength,
                  var catalog = localState?.workspaceCatalog,
                  let tree = catalog.trees.first,
                  let dataset = catalog.datasets.first else {
                throw WebBridgeInputError.invalidChoice("classifier type")
            }
            catalog.classifierTypes.append(.init(
                name: cleaned,
                treeID: tree.id,
                treeRevision: tree.revision,
                datasetID: dataset.id,
                datasetRevision: dataset.revision
            ))
            try coordinator?.updateWorkspaceCatalog(catalog)
            refreshLocalState()
            issue = nil
        } catch { issue = error.localizedDescription }
    }

    func configureClassifierType(
        typeID: String,
        name: String,
        applicablePlatformID: String,
        localModelID: String?,
        llmProviderProfileID: String?,
        llmModelIdentifier: String?,
        llmDailyOutputTokenLimit: String?,
        llmBatchSize: String?,
        llmMaximumTagCount: String?,
        llmRestrictToLeafTags: Bool,
        llmWebSearchEnabled: Bool,
        llmExternalToolEnabled: Bool,
        llmUsePlatformAPIKeyFallback: Bool,
        priority: [ClassifierDecisionSource]
    ) {
        do {
            let cleanedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanedName.isEmpty,
                  cleanedName.count <= ClassifierTypeAsset.maximumNameLength,
                  priority.count == ClassifierDecisionSource.allCases.count,
                  Set(priority) == Set(ClassifierDecisionSource.allCases),
                  var catalog = localState?.workspaceCatalog,
                  let typeIndex = catalog.classifierTypes.firstIndex(where: { $0.id == typeID }),
                  CollectionPlatformRegistry.definition(for: applicablePlatformID) != nil else {
                throw WebBridgeInputError.invalidChoice("classifier type")
            }
            let existingLLMAssist = catalog.classifierTypes[typeIndex].llmAssistConfiguration
            let selectedBinding = try catalog.ensurePlatformBinding(applicablePlatformID)
            guard
                  let tree = catalog.trees.first(where: { $0.id == selectedBinding.treeID }),
                  let dataset = catalog.datasets.first(where: { $0.id == selectedBinding.datasetID }),
                  let selectedDefinition = CollectionPlatformRegistry.definition(for: selectedBinding.id) else {
                throw WebBridgeInputError.invalidChoice("classifier type")
            }
            let supportsLocalModel = selectedDefinition.supportsLocalModel
            let supportsLLMAssist = selectedDefinition.supportsLLMAssist
            let selectedLLMAssist: LLMAssistConfiguration?
            let cleanedLLMProviderID = llmProviderProfileID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if supportsLLMAssist, !cleanedLLMProviderID.isEmpty {
                guard catalog.providerProfiles.contains(where: {
                    $0.id == cleanedLLMProviderID && $0.type.supportsLLMConfiguration
                }), let profile = catalog.providerProfiles.first(where: { $0.id == cleanedLLMProviderID }),
                  let llmModelIdentifier, let llmDailyOutputTokenLimit,
                  let llmBatchSize, let llmMaximumTagCount else {
                    throw WebBridgeInputError.invalidChoice("LLM assist")
                }
                let cleanedLLMModelIdentifier = llmModelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleanedLLMModelIdentifier.isEmpty else {
                    throw WebBridgeInputError.invalidChoice("LLM model")
                }
                let retainsSavedModel = existingLLMAssist?.providerProfileID == cleanedLLMProviderID &&
                    existingLLMAssist?.modelIdentifier == cleanedLLMModelIdentifier
                guard providerModelCatalogs[profile.id]?.contains(cleanedLLMModelIdentifier) == true || retainsSavedModel else {
                    throw WebBridgeInputError.invalidChoice("a model fetched from this provider")
                }
                let configuration = LLMAssistConfiguration(
                    providerProfileID: cleanedLLMProviderID,
                    modelIdentifier: cleanedLLMModelIdentifier,
                    dailyOutputTokenLimit: try providerPositiveInteger(
                        llmDailyOutputTokenLimit,
                        maximum: LLMAssistConfiguration.maximumDailyOutputTokenLimit,
                        label: "LLM daily output token limit"
                    ),
                    batchSize: try providerPositiveInteger(
                        llmBatchSize,
                        maximum: LLMAssistConfiguration.maximumBatchSize,
                        label: "LLM batch size"
                    ),
                    maximumTagCount: try providerPositiveInteger(
                        llmMaximumTagCount,
                        maximum: EntryEvidenceValidator.tagLimit,
                        label: "LLM maximum tag count"
                    ),
                    restrictToLeafTags: llmRestrictToLeafTags,
                    webSearchEnabled: profile.type == .openAI && llmWebSearchEnabled,
                    externalToolEnabled: selectedDefinition.apiProviderType != nil && llmExternalToolEnabled,
                    usePlatformAPIKeyFallback: selectedDefinition.supportsCreatorAvatarAPIFallback && llmUsePlatformAPIKeyFallback,
                    // Editing the limits or prompt options must not silently
                    // switch off a model the user deliberately activated.
                    // Changing the provider or model does require another
                    // explicit activation before any request is sent.
                    isActive: retainsSavedModel ? existingLLMAssist?.isActive ?? false : false
                )
                try configuration.validate()
                selectedLLMAssist = configuration
            } else {
                selectedLLMAssist = nil
            }
            let normalizedModelID = localModelID?.trimmingCharacters(in: .whitespacesAndNewlines)
            let compatibleModelID: String?
            if supportsLocalModel,
               let normalizedModelID, !normalizedModelID.isEmpty,
               catalog.models.contains(where: { model in
                   model.id == normalizedModelID && model.isReady && model.embeddedNeuralModel != nil &&
                   model.treeID == tree.id && model.treeRevision == tree.revision &&
                   model.datasetID == dataset.id && model.datasetRevision == dataset.revision &&
                   model.effectiveTrainingPlatformIDs == [selectedBinding.id]
               }) {
                compatibleModelID = normalizedModelID
            } else {
                compatibleModelID = nil
            }

            catalog.classifierTypes[typeIndex] = .init(
                id: catalog.classifierTypes[typeIndex].id,
                name: cleanedName,
                treeID: tree.id,
                treeRevision: tree.revision,
                datasetID: dataset.id,
                datasetRevision: dataset.revision,
                applicablePlatformID: selectedBinding.id,
                localModelID: compatibleModelID,
                llmAssistConfiguration: selectedLLMAssist,
                decisionPriority: priority
            )
            try coordinator?.updateWorkspaceCatalog(catalog)
            refreshLocalState()
            issue = nil
            if selectedLLMAssist?.isActive == true {
                startActiveLLMClassification()
            }
        } catch { issue = error.localizedDescription }
    }

    func setActiveClassifierType(platformID: String, classifierTypeID: String?) {
        do {
            guard var catalog = localState?.workspaceCatalog,
                  let bindingIndex = catalog.bindings.firstIndex(where: { $0.id == platformID }),
                  let tree = catalog.trees.first(where: { $0.id == catalog.bindings[bindingIndex].treeID }),
                  let dataset = catalog.datasets.first(where: { $0.id == catalog.bindings[bindingIndex].datasetID }) else {
                throw WebBridgeInputError.invalidChoice("classifier type")
            }
            let normalizedTypeID = classifierTypeID?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let normalizedTypeID, !normalizedTypeID.isEmpty else {
                catalog.bindings[bindingIndex].activeClassifierTypeID = nil
                catalog.bindings[bindingIndex].activeModelID = nil
                try coordinator?.updateWorkspaceCatalog(catalog)
                refreshLocalState()
                issue = nil
                return
            }
            guard let classifierType = catalog.classifierTypes.first(where: { $0.id == normalizedTypeID }),
                  classifierType.treeID == tree.id,
                  classifierType.treeRevision == tree.revision,
                  classifierType.datasetID == dataset.id,
                  classifierType.datasetRevision == dataset.revision,
                  classifierType.applicablePlatformID == platformID else {
                throw WebBridgeInputError.invalidChoice("classifier type")
            }
            guard let platform = CollectionPlatformRegistry.definition(for: platformID) else {
                throw WebBridgeInputError.invalidChoice("collection platform")
            }
            guard (platform.supportsLocalModel ||
                   classifierType.localModelID == nil),
                  (platform.supportsLLMAssist ||
                   classifierType.llmAssistConfiguration == nil) else {
                throw WebBridgeInputError.invalidChoice("manual-only platform classifier type")
            }
            if let modelID = classifierType.localModelID {
                guard
                      catalog.models.contains(where: { model in
                          model.id == modelID && model.isReady && model.embeddedNeuralModel != nil &&
                          model.treeID == tree.id && model.treeRevision == tree.revision &&
                          model.datasetID == dataset.id && model.datasetRevision == dataset.revision
                      }) else {
                    throw WebBridgeInputError.invalidChoice("ready local neural model")
                }
                catalog.bindings[bindingIndex].activeModelID = modelID
            } else {
                catalog.bindings[bindingIndex].activeModelID = nil
            }
            catalog.bindings[bindingIndex].activeClassifierTypeID = normalizedTypeID
            try coordinator?.updateWorkspaceCatalog(catalog)
            refreshLocalState()
            issue = nil
        } catch { issue = error.localizedDescription }
    }

    func deleteClassifierType(typeID: String) {
        do {
            guard var catalog = localState?.workspaceCatalog,
                  catalog.classifierTypes.contains(where: { $0.id == typeID }) else {
                throw WebBridgeInputError.invalidChoice("classifier type")
            }
            catalog.classifierTypes.removeAll(where: { $0.id == typeID })
            for datasetIndex in catalog.datasets.indices {
                let priorCount = catalog.datasets[datasetIndex].creatorClassifications.count
                catalog.datasets[datasetIndex].creatorClassifications.removeAll(where: { $0.classifierTypeID == typeID })
                if catalog.datasets[datasetIndex].creatorClassifications.count != priorCount {
                    catalog.datasets[datasetIndex].revision += 1
                }
            }
            for index in catalog.bindings.indices where catalog.bindings[index].activeClassifierTypeID == typeID {
                catalog.bindings[index].activeClassifierTypeID = nil
                catalog.bindings[index].activeModelID = nil
            }
            try coordinator?.updateWorkspaceCatalog(catalog)
            refreshLocalState()
            issue = nil
        } catch { issue = error.localizedDescription }
    }

    func confirmClassifierTypeDeletion(typeID: String) {
        guard localState?.workspaceCatalog.classifierTypes.contains(where: { $0.id == typeID }) == true else {
            issue = WebBridgeInputError.invalidChoice("classifier type").localizedDescription
            return
        }
        presentNativeConfirmation(
            title: "Delete classifier type?",
            message: "This removes this local decision configuration and its creator classifications. Trees, models, other data, and provider profiles are retained.",
            confirmTitle: "Delete classifier type"
        ) { [weak self] in
            self?.deleteClassifierType(typeID: typeID)
        }
    }

    private func presentNativeConfirmation(
        title: String,
        message: String,
        confirmTitle: String,
        action: @escaping () -> Void
    ) {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) else {
            issue = WebBridgeInputError.invalidChoice("application window").localizedDescription
            return
        }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        alert.beginSheetModal(for: window) { [weak self] response in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard response == .alertFirstButtonReturn else { return }
                action()
                self.onWebStateChange?()
            }
        }
    }

    func configureLocalModel(modelID: String, treeID: String, platformIDs: [String], baseEmbeddingID: String?) {
        do {
            guard var catalog = localState?.workspaceCatalog else { return }
            try configureLocalModel(
                in: &catalog,
                modelID: modelID,
                treeID: treeID,
                platformIDs: platformIDs,
                baseEmbeddingID: baseEmbeddingID
            )
            try coordinator?.updateWorkspaceCatalog(catalog)
            refreshLocalState()
            issue = nil
        } catch { issue = error.localizedDescription }
    }

    func trainLocalModel(modelID: String, treeID: String, platformIDs: [String], baseEmbeddingID: String?) {
        do {
            guard var catalog = localState?.workspaceCatalog else { return }
            try configureLocalModel(
                in: &catalog,
                modelID: modelID,
                treeID: treeID,
                platformIDs: platformIDs,
                baseEmbeddingID: baseEmbeddingID
            )
            guard let modelIndex = catalog.models.firstIndex(where: { $0.id == modelID }),
                  let tree = catalog.trees.first(where: { $0.id == catalog.models[modelIndex].treeID }),
                  let dataset = catalog.datasets.first(where: { $0.id == catalog.models[modelIndex].datasetID }) else {
                throw WebBridgeInputError.invalidChoice("local model")
            }
            catalog.models[modelIndex] = try LocalModelTrainer.train(catalog.models[modelIndex], tree: tree, dataset: dataset)
            try coordinator?.updateWorkspaceCatalog(catalog)
            refreshLocalState()
            issue = nil
        } catch { issue = error.localizedDescription }
    }

    private func configureLocalModel(
        in catalog: inout WorkspaceCatalog,
        modelID: String,
        treeID: String,
        platformIDs: [String],
        baseEmbeddingID: String?
    ) throws {
        guard let modelIndex = catalog.models.firstIndex(where: { $0.id == modelID }),
              let tree = catalog.trees.first(where: { $0.id == treeID }) else {
            throw WebBridgeInputError.invalidChoice("local model setup")
        }
        let selectedPlatformIDs = Array(Set(platformIDs)).sorted()
        guard !selectedPlatformIDs.isEmpty,
              selectedPlatformIDs.count <= LocalModelAsset.maximumTrainingPlatforms,
              selectedPlatformIDs.allSatisfy({
                  CollectionPlatformRegistry.definition(for: $0)?.supportsLocalModel == true
              }) else {
            throw WebBridgeInputError.invalidChoice("local model data sources")
        }
        let bindings = selectedPlatformIDs.compactMap { platformID in
            catalog.bindings.first(where: { $0.id == platformID })
        }
        guard bindings.count == selectedPlatformIDs.count,
              bindings.allSatisfy({ $0.treeID == tree.id }),
              let datasetID = bindings.first?.datasetID,
              bindings.allSatisfy({ $0.datasetID == datasetID }),
              let dataset = catalog.datasets.first(where: { $0.id == datasetID }) else {
            throw WebBridgeInputError.invalidChoice("local model data sources")
        }
        let normalizedBaseEmbeddingID = baseEmbeddingID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseEmbedding = normalizedBaseEmbeddingID?.isEmpty == false
            ? LocalBaseEmbedding(rawValue: normalizedBaseEmbeddingID!)
            : nil
        if normalizedBaseEmbeddingID?.isEmpty == false, baseEmbedding == nil {
            throw WebBridgeInputError.invalidChoice("base embedding")
        }

        let prior = catalog.models[modelIndex]
        let changed = prior.treeID != tree.id ||
            prior.treeRevision != tree.revision ||
            prior.datasetID != dataset.id ||
            prior.datasetRevision != dataset.revision ||
            prior.effectiveTrainingPlatformIDs != selectedPlatformIDs ||
            prior.baseEmbeddingID != baseEmbedding
        catalog.models[modelIndex].treeID = tree.id
        catalog.models[modelIndex].treeRevision = tree.revision
        catalog.models[modelIndex].datasetID = dataset.id
        catalog.models[modelIndex].datasetRevision = dataset.revision
        catalog.models[modelIndex].trainingPlatformID = selectedPlatformIDs.first
        catalog.models[modelIndex].trainingPlatformIDs = selectedPlatformIDs
        catalog.models[modelIndex].baseEmbeddingID = baseEmbedding
        if changed {
            catalog.models[modelIndex].isReady = false
            catalog.models[modelIndex].embeddedNeuralModel = nil
            catalog.models[modelIndex].embeddedTrainingReport = nil
            catalog.models[modelIndex].trainedAtMilliseconds = nil
            for bindingIndex in catalog.bindings.indices where catalog.bindings[bindingIndex].activeModelID == modelID {
                catalog.bindings[bindingIndex].activeModelID = nil
                catalog.bindings[bindingIndex].activeClassifierTypeID = nil
            }
        }
    }

    func renameTree(treeID: String, name: String, refreshState: Bool = true) {
        do {
            guard var catalog = localState?.workspaceCatalog,
                  let treeIndex = catalog.trees.firstIndex(where: { $0.id == treeID }) else {
                throw WebBridgeInputError.invalidChoice("tag tree")
            }
            let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { throw WebBridgeInputError.invalidChoice("tree name") }
            catalog.trees[treeIndex].name = cleaned
            catalog.trees[treeIndex].updatedAtMilliseconds = WorkspaceCatalog.now()
            try coordinator?.updateWorkspaceCatalog(catalog)
            if refreshState { refreshLocalState() }
        } catch { issue = error.localizedDescription }
    }

    func deleteTree(treeID: String) {
        do {
            guard var catalog = localState?.workspaceCatalog,
                  let treeIndex = catalog.trees.firstIndex(where: { $0.id == treeID }) else {
                throw WebBridgeInputError.invalidChoice("tag tree")
            }
            catalog.trees.remove(at: treeIndex)
            catalog.models.removeAll(where: { $0.treeID == treeID })
            catalog.bindings.removeAll(where: { $0.treeID == treeID })
            try coordinator?.updateWorkspaceCatalog(catalog)
            refreshLocalState()
        } catch { issue = error.localizedDescription }
    }

    func rearrangeTree(treeID: String) {
        do {
            guard var catalog = localState?.workspaceCatalog,
                  let treeIndex = catalog.trees.firstIndex(where: { $0.id == treeID }) else {
                throw WebBridgeInputError.invalidChoice("tag tree")
            }
            let nodes = catalog.trees[treeIndex].nodes
            let nodeIDs = Set(nodes.map(\.id))
            var childrenByParentID: [String: [TagTreeNode]] = [:]
            for node in nodes {
                guard let parentID = node.parentID, nodeIDs.contains(parentID) else { continue }
                childrenByParentID[parentID, default: []].append(node)
            }
            let roots = nodes.filter { node in
                guard let parentID = node.parentID else { return true }
                return !nodeIDs.contains(parentID)
            }
            var positions: [String: (x: Double, y: Double)] = [:]
            var nextLeafX = 48.0

            func place(_ nodeID: String, depth: Int, visited: inout Set<String>) -> Double {
                guard visited.insert(nodeID).inserted else { return positions[nodeID]?.x ?? nextLeafX }
                let childPositions = (childrenByParentID[nodeID] ?? []).compactMap { child -> Double? in
                    guard !visited.contains(child.id) else { return nil }
                    return place(child.id, depth: depth + 1, visited: &visited)
                }
                let x: Double
                if let first = childPositions.first, let last = childPositions.last {
                    x = (first + last) / 2
                } else {
                    x = nextLeafX
                    nextLeafX += 154
                }
                positions[nodeID] = (x: x, y: 56 + Double(depth) * 64)
                return x
            }

            var visited: Set<String> = []
            for root in roots { _ = place(root.id, depth: 0, visited: &visited) }
            for node in nodes where !visited.contains(node.id) { _ = place(node.id, depth: 0, visited: &visited) }
            for index in catalog.trees[treeIndex].nodes.indices {
                let nodeID = catalog.trees[treeIndex].nodes[index].id
                guard let position = positions[nodeID] else { continue }
                catalog.trees[treeIndex].nodes[index].positionX = position.x
                catalog.trees[treeIndex].nodes[index].positionY = position.y
            }
            catalog.trees[treeIndex].updatedAtMilliseconds = WorkspaceCatalog.now()
            try coordinator?.updateWorkspaceCatalog(catalog)
            refreshLocalState()
        } catch { issue = error.localizedDescription }
    }

    func addTag(treeID: String, name: String, parentID: String?, positionX: Double, positionY: Double) {
        do {
            guard var catalog = localState?.workspaceCatalog,
                  let treeIndex = catalog.trees.firstIndex(where: { $0.id == treeID }) else {
                throw WebBridgeInputError.invalidChoice("tag tree")
            }
            let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { throw WebBridgeInputError.invalidChoice("tag name") }
            let normalizedParentID = parentID?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let normalizedParentID, !normalizedParentID.isEmpty,
               !catalog.trees[treeIndex].nodes.contains(where: { $0.id == normalizedParentID }) {
                throw WebBridgeInputError.invalidChoice("tag parent")
            }
            catalog.trees[treeIndex].nodes.append(.init(name: cleaned, parentID: normalizedParentID?.isEmpty == false ? normalizedParentID : nil, positionX: positionX, positionY: positionY))
            advanceTreeRevision(in: &catalog, treeIndex: treeIndex)
            try coordinator?.updateWorkspaceCatalog(catalog)
            refreshLocalState()
        } catch { issue = error.localizedDescription }
    }

    func moveTag(treeID: String, nodeID: String, positionX: Double, positionY: Double) {
        do {
            guard var catalog = localState?.workspaceCatalog,
                  let treeIndex = catalog.trees.firstIndex(where: { $0.id == treeID }),
                  let nodeIndex = catalog.trees[treeIndex].nodes.firstIndex(where: { $0.id == nodeID }) else {
                throw WebBridgeInputError.invalidChoice("tag node")
            }
            guard positionX.isFinite, positionY.isFinite, positionX >= 0, positionY >= 0 else {
                throw WebBridgeInputError.invalidChoice("tag position")
            }
            let tree = catalog.trees[treeIndex]
            let sourcePosition = tree.nodes[nodeIndex].resolvedCanvasPosition(index: nodeIndex)
            let deltaX = positionX - sourcePosition.x
            let deltaY = positionY - sourcePosition.y
            let movedNodeIDs = tree.subtreeNodeIDs(rootID: nodeID)

            for index in catalog.trees[treeIndex].nodes.indices where movedNodeIDs.contains(catalog.trees[treeIndex].nodes[index].id) {
                let currentPosition = catalog.trees[treeIndex].nodes[index].resolvedCanvasPosition(index: index)
                let nextX = currentPosition.x + deltaX
                let nextY = currentPosition.y + deltaY
                guard nextX.isFinite, nextY.isFinite, nextX >= 0, nextY >= 0, nextX <= 20_000, nextY <= 20_000 else {
                    throw WebBridgeInputError.invalidChoice("tag position")
                }
                catalog.trees[treeIndex].nodes[index].positionX = nextX
                catalog.trees[treeIndex].nodes[index].positionY = nextY
            }
            catalog.trees[treeIndex].updatedAtMilliseconds = WorkspaceCatalog.now()
            try coordinator?.updateWorkspaceCatalog(catalog)
            refreshLocalState()
        } catch { issue = error.localizedDescription }
    }

    func renameTag(treeID: String, nodeID: String, name: String, refreshState: Bool = true) {
        do {
            guard var catalog = localState?.workspaceCatalog,
                  let treeIndex = catalog.trees.firstIndex(where: { $0.id == treeID }),
                  let nodeIndex = catalog.trees[treeIndex].nodes.firstIndex(where: { $0.id == nodeID }) else {
                throw WebBridgeInputError.invalidChoice("tag node")
            }
            let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { throw WebBridgeInputError.invalidChoice("tag name") }
            catalog.trees[treeIndex].nodes[nodeIndex].name = cleaned
            advanceTreeRevision(in: &catalog, treeIndex: treeIndex)
            try coordinator?.updateWorkspaceCatalog(catalog)
            // Live typing deliberately avoids a full WebKit re-render, but
            // later tree actions must still start from the renamed catalog.
            if refreshState {
                refreshLocalState()
            } else {
                localState = coordinator?.snapshot()
            }
        } catch { issue = error.localizedDescription }
    }

    func connectTag(treeID: String, nodeID: String, parentID: String) {
        do {
            guard var catalog = localState?.workspaceCatalog,
                  let treeIndex = catalog.trees.firstIndex(where: { $0.id == treeID }),
                  let nodeIndex = catalog.trees[treeIndex].nodes.firstIndex(where: { $0.id == nodeID }),
                  catalog.trees[treeIndex].nodes.contains(where: { $0.id == parentID }),
                  nodeID != parentID,
                  !catalog.trees[treeIndex].subtreeNodeIDs(rootID: nodeID).contains(parentID) else {
                throw WebBridgeInputError.invalidChoice("tag parent")
            }
            catalog.trees[treeIndex].nodes[nodeIndex].parentID = parentID
            advanceTreeRevision(in: &catalog, treeIndex: treeIndex)
            try coordinator?.updateWorkspaceCatalog(catalog)
            refreshLocalState()
        } catch { issue = error.localizedDescription }
    }

    func disconnectTag(treeID: String, nodeID: String) {
        do {
            guard var catalog = localState?.workspaceCatalog,
                  let treeIndex = catalog.trees.firstIndex(where: { $0.id == treeID }),
                  let nodeIndex = catalog.trees[treeIndex].nodes.firstIndex(where: { $0.id == nodeID }) else {
                throw WebBridgeInputError.invalidChoice("tag node")
            }
            guard catalog.trees[treeIndex].nodes[nodeIndex].parentID != nil else { return }
            catalog.trees[treeIndex].nodes[nodeIndex].parentID = nil
            advanceTreeRevision(in: &catalog, treeIndex: treeIndex)
            try coordinator?.updateWorkspaceCatalog(catalog)
            refreshLocalState()
        } catch { issue = error.localizedDescription }
    }

    func deleteTag(treeID: String, nodeID: String) {
        do {
            guard var catalog = localState?.workspaceCatalog,
                  let treeIndex = catalog.trees.firstIndex(where: { $0.id == treeID }),
                  let nodeIndex = catalog.trees[treeIndex].nodes.firstIndex(where: { $0.id == nodeID }) else {
                throw WebBridgeInputError.invalidChoice("tag node")
            }
            let replacementParentID = catalog.trees[treeIndex].nodes[nodeIndex].parentID
            catalog.trees[treeIndex].nodes.remove(at: nodeIndex)
            for index in catalog.trees[treeIndex].nodes.indices where catalog.trees[treeIndex].nodes[index].parentID == nodeID {
                catalog.trees[treeIndex].nodes[index].parentID = replacementParentID
            }
            advanceTreeRevision(in: &catalog, treeIndex: treeIndex)
            try coordinator?.updateWorkspaceCatalog(catalog)
            refreshLocalState()
        } catch { issue = error.localizedDescription }
    }

    private func advanceTreeRevision(in catalog: inout WorkspaceCatalog, treeIndex: Int) {
        catalog.trees[treeIndex].revision += 1
        catalog.trees[treeIndex].updatedAtMilliseconds = WorkspaceCatalog.now()
        let treeID = catalog.trees[treeIndex].id
        for bindingIndex in catalog.bindings.indices where catalog.bindings[bindingIndex].treeID == treeID {
            catalog.bindings[bindingIndex].activeModelID = nil
            catalog.bindings[bindingIndex].activeClassifierTypeID = nil
        }
    }

    /// Saves the current creator-level source of truth for a classifier type.
    /// The dataset revision advances because approved creator decisions are
    /// explicit local-model training material through their collected entries.
    func recordCreatorClassification(
        typeID: String,
        creatorKey: String,
        tagIDs: [String],
        negativeTagIDs: [String]
    ) {
        do {
            guard var catalog = localState?.workspaceCatalog,
                  let typeIndex = catalog.classifierTypes.firstIndex(where: { $0.id == typeID }) else {
                throw WebBridgeInputError.invalidChoice("classifier type")
            }
            let classifierType = catalog.classifierTypes[typeIndex]
            guard let tree = catalog.trees.first(where: { $0.id == classifierType.treeID }),
                  let datasetIndex = catalog.datasets.firstIndex(where: { $0.id == classifierType.datasetID }) else {
                throw WebBridgeInputError.invalidChoice("creator decision")
            }
            let keyParts = creatorKey.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            guard keyParts.count == 2,
                  !keyParts[0].isEmpty,
                  !keyParts[1].isEmpty else {
                throw WebBridgeInputError.invalidChoice("creator")
            }
            let platformID = String(keyParts[0])
            let creatorID = String(keyParts[1])
            guard classifierType.applicablePlatformID == platformID,
                  CollectionPlatformRegistry.definition(for: platformID) != nil else {
                throw WebBridgeInputError.invalidChoice("creator data source")
            }
            guard let creatorEntry = catalog.datasets[datasetIndex].collectedEntries.first(where: {
                $0.platformID == platformID && $0.creatorID == creatorID
            }) else {
                throw WebBridgeInputError.invalidChoice("creator")
            }
            if tagIDs.isEmpty && negativeTagIDs.isEmpty {
                if catalog.datasets[datasetIndex].removeCreatorClassification(
                    classifierTypeID: classifierType.id,
                    platformID: platformID,
                    creatorID: creatorID,
                    origin: .manual
                ) {
                    catalog.datasets[datasetIndex].revision += 1
                    try coordinator?.updateWorkspaceCatalog(catalog)
                }
                refreshLocalState()
                issue = nil
                return
            }
            try storeCreatorClassification(
                in: &catalog,
                classifierType: classifierType,
                tree: tree,
                creatorID: creatorEntry.creatorID,
                creatorName: creatorEntry.creatorName,
                platformID: creatorEntry.platformID,
                tagIDs: tagIDs,
                negativeTagIDs: negativeTagIDs,
                origin: .manual
            )
            try coordinator?.updateWorkspaceCatalog(catalog)
            refreshLocalState()
            issue = nil
        } catch { issue = error.localizedDescription }
    }

    /// Revisits only public creator pages the user already collected and only
    /// after an explicit WebView action. Discovered images must pass the same
    /// platform allowlist as browser-collected avatar URLs before they are
    /// persisted and cached for the local WebView.
    func backfillCreatorAvatars(typeID: String) {
        guard !creatorAvatarBackfillRunning else { return }
        do {
            guard let catalog = localState?.workspaceCatalog,
                  let classifierType = catalog.classifierTypes.first(where: { $0.id == typeID }),
                  let dataset = catalog.datasets.first(where: { $0.id == classifierType.datasetID }) else {
                throw WebBridgeInputError.invalidChoice("creator avatar backfill")
            }
            let usePlatformAPIKeyFallback = classifierType.llmAssistConfiguration?.usePlatformAPIKeyFallback == true
            let candidates = CreatorAvatarBackfill.candidates(
                entries: dataset.collectedEntries,
                allowedPlatformIDs: Set(classifierType.applicablePlatformID.map { [$0] } ?? []),
                includeUnavailableCreatorPages: usePlatformAPIKeyFallback
            )
            creatorAvatarBackfillFoundCount = nil
            guard !candidates.isEmpty else {
                creatorAvatarBackfillFoundCount = 0
                issue = nil
                onWebStateChange?()
                return
            }
            creatorAvatarBackfillRunning = true
            issue = nil
            onWebStateChange?()
            Task { @MainActor [weak self] in
                var foundCount = 0
                for candidate in candidates {
                    guard let self else { return }
                    var avatarURL = await CreatorAvatarBackfill.resolveAvatarURL(for: candidate)
                    if avatarURL == nil,
                       usePlatformAPIKeyFallback,
                       let profile = self.readyPlatformAPIProfile(in: catalog, platformID: candidate.platformID) {
                        avatarURL = await self.fetchCreatorAvatarURLUsingPlatformAPI(candidate: candidate, profile: profile)
                    }
                    guard let avatarURL else { continue }
                    do {
                        try self.storeCreatorAvatarURL(
                            avatarURL,
                            datasetID: classifierType.datasetID,
                            platformID: candidate.platformID,
                            creatorID: candidate.creatorID
                        )
                        self.cacheCreatorAvatar(remoteURL: avatarURL)
                        foundCount += 1
                    } catch {
                        self.issue = error.localizedDescription
                    }
                }
                guard let self else { return }
                self.creatorAvatarBackfillRunning = false
                self.creatorAvatarBackfillFoundCount = foundCount
                self.refreshLocalState()
                self.onWebStateChange?()
            }
        } catch {
            issue = error.localizedDescription
        }
    }

    private func storeCreatorAvatarURL(
        _ avatarURL: String,
        datasetID: String,
        platformID: String,
        creatorID: String
    ) throws {
        guard CreatorAvatarURLPolicy.isAccepted(platformID: platformID, value: avatarURL),
              var catalog = localState?.workspaceCatalog,
              let datasetIndex = catalog.datasets.firstIndex(where: { $0.id == datasetID }) else {
            throw WebBridgeInputError.invalidChoice("creator avatar")
        }
        var changed = false
        for entryIndex in catalog.datasets[datasetIndex].collectedEntries.indices {
            guard catalog.datasets[datasetIndex].collectedEntries[entryIndex].platformID == platformID,
                  catalog.datasets[datasetIndex].collectedEntries[entryIndex].creatorID == creatorID else {
                continue
            }
            let existing = catalog.datasets[datasetIndex].collectedEntries[entryIndex].attributes["creatorAvatarURL"]
            guard existing != avatarURL,
                  existing != nil || catalog.datasets[datasetIndex].collectedEntries[entryIndex].attributes.count < CollectedPlatformEntry.maximumAttributes else {
                continue
            }
            catalog.datasets[datasetIndex].collectedEntries[entryIndex].attributes["creatorAvatarURL"] = avatarURL
            changed = true
        }
        guard changed else { return }
        try coordinator?.updateWorkspaceCatalog(catalog)
        refreshLocalState()
    }

    private struct LLMCreatorWorkItem {
        let representative: CollectedPlatformEntry
        let entry: EntryEvidence
    }

    /// An active model never receives a partial creator record. The prompt
    /// contains only the creator identity and collected titles, so those are
    /// the required fields for every retained entry for that creator.
    private func llmCreatorWorkItem(
        platformID: String,
        creatorID: String,
        entries: [CollectedPlatformEntry]
    ) -> LLMCreatorWorkItem? {
        let creatorEntries = entries.filter {
            $0.platformID == platformID && $0.creatorID == creatorID
        }
        guard !creatorEntries.isEmpty,
              creatorEntries.allSatisfy({ entry in
                  !entry.entryID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                  !entry.creatorID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                  !entry.creatorName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                  !entry.entryType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                  !entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              }),
              let representative = creatorEntries.max(by: { lhs, rhs in
                  if lhs.lastObservedAtMilliseconds == rhs.lastObservedAtMilliseconds { return lhs.id < rhs.id }
                  return lhs.lastObservedAtMilliseconds < rhs.lastObservedAtMilliseconds
              }) else {
            return nil
        }
        let titles = creatorEntries
            .sorted { lhs, rhs in
                if lhs.lastObservedAtMilliseconds == rhs.lastObservedAtMilliseconds { return lhs.id < rhs.id }
                return lhs.lastObservedAtMilliseconds > rhs.lastObservedAtMilliseconds
            }
            .prefix(25)
            .map(\.title)
            .joined(separator: "\n")
        guard !titles.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return .init(
            representative: representative,
            entry: .init(
                platform: platformID,
                sourceID: creatorID,
                surface: .page,
                evidence: .init(
                    title: String("Creator: \(representative.creatorName)".prefix(EntryEvidenceValidator.titleLimit)),
                    text: String(titles.prefix(EntryEvidenceValidator.textLimit))
                )
            )
        )
    }

    private func unclassifiedLLMCreatorWorkItems(
        dataset: ClassificationDataset,
        classifierType: ClassifierTypeAsset,
        platformID: String
    ) -> [LLMCreatorWorkItem] {
        let classifiedCreatorIDs = Set(dataset.creatorClassifications.compactMap { record -> String? in
            guard record.classifierTypeID == classifierType.id,
                  record.platformID == platformID,
                  record.origin == .llmAssist else { return nil }
            return record.creatorID
        })
        let creatorIDs = Set(dataset.collectedEntries.compactMap { entry -> String? in
            guard entry.platformID == platformID,
                  !entry.creatorID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !classifiedCreatorIDs.contains(entry.creatorID) else {
                return nil
            }
            return entry.creatorID
        })
        return creatorIDs.compactMap {
            llmCreatorWorkItem(platformID: platformID, creatorID: $0, entries: dataset.collectedEntries)
        }.sorted { lhs, rhs in
            let comparison = lhs.representative.creatorName.localizedCaseInsensitiveCompare(rhs.representative.creatorName)
            return comparison == .orderedSame
                ? lhs.representative.creatorID < rhs.representative.creatorID
                : comparison == .orderedAscending
        }
    }

    private func isLLMAssistActive(typeID: String) -> Bool {
        localState?.workspaceCatalog.classifierTypes.first(where: { $0.id == typeID })?.llmAssistConfiguration?.isActive == true
    }

    func setLLMAssistActive(typeID: String, isActive: Bool) {
        do {
            guard var catalog = localState?.workspaceCatalog,
                  let typeIndex = catalog.classifierTypes.firstIndex(where: { $0.id == typeID }),
                  var configuration = catalog.classifierTypes[typeIndex].llmAssistConfiguration,
                  let profile = catalog.providerProfiles.first(where: { $0.id == configuration.providerProfileID }),
                  catalog.classifierTypes[typeIndex].applicablePlatformID.flatMap(CollectionPlatformRegistry.definition(for:))?.supportsLLMAssist == true else {
                throw WebBridgeInputError.invalidChoice("active LLM classifier type")
            }
            guard !configuration.modelIdentifier.isEmpty else {
                throw WebBridgeInputError.invalidChoice("LLM model")
            }
            if isActive { _ = try providerCredential(for: profile.id) }
            configuration.isActive = isActive
            catalog.classifierTypes[typeIndex].llmAssistConfiguration = configuration
            try coordinator?.updateWorkspaceCatalog(catalog)
            refreshLocalState()
            issue = nil
            if isActive { startActiveLLMClassification() }
        } catch {
            issue = error.localizedDescription
        }
    }

    private func startActiveLLMClassification(platformID: String? = nil) {
        guard !providerClassificationRunning,
              let catalog = localState?.workspaceCatalog else { return }
        let activeTypes = catalog.classifierTypes
            .filter {
                $0.llmAssistConfiguration?.isActive == true &&
                (platformID == nil || $0.applicablePlatformID == platformID)
            }
            .sorted { $0.id < $1.id }
        for classifierType in activeTypes {
            guard let dataset = catalog.datasets.first(where: { $0.id == classifierType.datasetID }),
                  let activePlatformID = classifierType.applicablePlatformID,
                  !unclassifiedLLMCreatorWorkItems(
                      dataset: dataset,
                      classifierType: classifierType,
                      platformID: activePlatformID
                  ).isEmpty else {
                continue
            }
            classifyCreatorBatchWithLLM(typeID: classifierType.id, activatedRun: true)
            return
        }
    }

    /// A valid answer remains alongside a human decision for the same creator
    /// and is approved by this deliberate action, making its collected titles
    /// available to a compatible local-model retraining run.
    func classifyCreatorWithLLM(typeID: String, creatorKey: String) {
        guard !providerClassificationRunning else { return }
        do {
            guard let catalog = localState?.workspaceCatalog,
                  let classifierType = catalog.classifierTypes.first(where: { $0.id == typeID }),
                  let llmAssist = classifierType.llmAssistConfiguration,
                  let profile = catalog.providerProfiles.first(where: { $0.id == llmAssist.providerProfileID }),
                  let tree = catalog.trees.first(where: { $0.id == classifierType.treeID }),
                  let dataset = catalog.datasets.first(where: { $0.id == classifierType.datasetID }) else {
                throw WebBridgeInputError.invalidChoice("creator LLM classifier type")
            }
            let keyParts = creatorKey.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            guard keyParts.count == 2,
                  !keyParts[0].isEmpty,
                  !keyParts[1].isEmpty else {
                throw WebBridgeInputError.invalidChoice("creator")
            }
            let platformID = String(keyParts[0])
            let creatorID = String(keyParts[1])
            guard classifierType.applicablePlatformID == platformID else {
                throw WebBridgeInputError.invalidChoice("creator data source")
            }
            guard let workItem = llmCreatorWorkItem(
                platformID: platformID,
                creatorID: creatorID,
                entries: dataset.collectedEntries
            ) else {
                throw WebBridgeInputError.invalidChoice("complete creator evidence")
            }
            let representative = workItem.representative
            let entry = workItem.entry
            let taxonomy = try tree.inferenceTaxonomy()
            let allowedTagIDs = llmAllowedTagIDs(taxonomy: taxonomy, configuration: llmAssist)
            let outputTokenLimit = try remainingLLMOutputTokens(
                in: catalog,
                classifierTypeID: classifierType.id,
                configuration: llmAssist
            )
            let recordPlan = try ProviderClassificationProtocol.prepare(
                profile: profile,
                configuration: llmAssist,
                entry: entry,
                allowedTagIDs: allowedTagIDs,
                maximumOutputTokens: outputTokenLimit
            )
            providerClassificationRunning = true
            issue = nil
            Task { [weak self] in
                guard let self else { return }
                let startedAt = Date()
                do {
                    let run = try await self.runProviderClassification(
                        profile: profile,
                        configuration: llmAssist,
                        entry: entry,
                        allowedTagIDs: allowedTagIDs,
                        catalog: catalog,
                        maximumOutputTokens: outputTokenLimit
                    )
                    let duration = max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
                    let labelIDs = try ProviderClassificationProtocol.parseLabelIDs(
                        run.content,
                        allowedTagIDs: allowedTagIDs,
                        maximumTagCount: llmAssist.maximumTagCount
                    )
                    try self.recordLLMCreatorClassification(
                        typeID: classifierType.id,
                        creatorID: representative.creatorID,
                        platformID: representative.platformID,
                        creatorName: representative.creatorName,
                        labelIDs: labelIDs
                    )
                    try self.appendProviderTestRecord(.init(
                        profileID: profile.id,
                        provider: profile.type.rawValue,
                        model: llmAssist.modelIdentifier,
                        operation: "classify-creator",
                        endpoint: ProviderTestProtocol.safeEndpoint(recordPlan.plan.url),
                        method: recordPlan.plan.method,
                        statusCode: run.statusCode,
                        durationMilliseconds: duration,
                        inputTokens: run.usage.inputTokens,
                        outputTokens: run.usage.outputTokens ?? outputTokenLimit,
                        classifierTypeID: classifierType.id,
                        outcome: "succeeded"
                    ))
                    self.issue = nil
                } catch {
                    let duration = max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
                    try? self.appendProviderTestRecord(.init(
                        profileID: profile.id,
                        provider: profile.type.rawValue,
                        model: llmAssist.modelIdentifier,
                        operation: "classify-creator",
                        endpoint: ProviderTestProtocol.safeEndpoint(recordPlan.plan.url),
                        method: recordPlan.plan.method,
                        statusCode: nil,
                        durationMilliseconds: duration,
                        inputTokens: nil,
                        outputTokens: nil,
                        classifierTypeID: classifierType.id,
                        outcome: "failed"
                    ))
                    self.issue = error.localizedDescription
                }
                self.providerClassificationRunning = false
                self.onWebStateChange?()
            }
        } catch {
            issue = error.localizedDescription
        }
    }

    /// Runs eligible creators one at a time. An activated model processes the
    /// full current queue, while the manual control keeps its configured batch
    /// limit. A provider response without usage metadata consumes its
    /// requested cap so the persisted daily budget stays safe and visible.
    func classifyCreatorBatchWithLLM(typeID: String, activatedRun: Bool = false) {
        guard !providerClassificationRunning else { return }
        do {
            guard let catalog = localState?.workspaceCatalog,
                  let classifierType = catalog.classifierTypes.first(where: { $0.id == typeID }),
                  let configuration = classifierType.llmAssistConfiguration,
                  let profile = catalog.providerProfiles.first(where: { $0.id == configuration.providerProfileID }),
                  let tree = catalog.trees.first(where: { $0.id == classifierType.treeID }),
                  let dataset = catalog.datasets.first(where: { $0.id == classifierType.datasetID }),
                  let platformID = classifierType.applicablePlatformID else {
                throw WebBridgeInputError.invalidChoice("creator LLM classifier type")
            }
            let workItems = unclassifiedLLMCreatorWorkItems(
                dataset: dataset,
                classifierType: classifierType,
                platformID: platformID
            )
            let queuedWorkItems = activatedRun ? workItems : Array(workItems.prefix(configuration.batchSize))
            guard !queuedWorkItems.isEmpty else {
                if activatedRun { return }
                throw WebBridgeInputError.invalidChoice("unclassified creators")
            }
            let taxonomy = try tree.inferenceTaxonomy()
            let allowedTagIDs = llmAllowedTagIDs(taxonomy: taxonomy, configuration: configuration)
            var remainingOutputTokens = configuration.dailyOutputTokenLimit - outputTokensUsedToday(
                in: catalog,
                classifierTypeID: classifierType.id
            )
            guard remainingOutputTokens > 0 else {
                throw WebBridgeInputError.invalidChoice("daily output token budget")
            }
            providerClassificationRunning = true
            issue = nil
            Task { [weak self] in
                guard let self else { return }
                var successCount = 0
                var firstFailure: Error?
                for workItem in queuedWorkItems {
                    if activatedRun && !self.isLLMAssistActive(typeID: typeID) { break }
                    guard remainingOutputTokens > 0 else { break }
                    let representative = workItem.representative
                    let entry = workItem.entry
                    let outputTokenLimit = min(ProviderClassificationProtocol.maximumOutputTokens, remainingOutputTokens)
                    let startedAt = Date()
                    var recordPlan: ProviderTestPreparedRequest?
                    do {
                        recordPlan = try ProviderClassificationProtocol.prepare(
                            profile: profile,
                            configuration: configuration,
                            entry: entry,
                            allowedTagIDs: allowedTagIDs,
                            maximumOutputTokens: outputTokenLimit
                        )
                        let run = try await self.runProviderClassification(
                            profile: profile,
                            configuration: configuration,
                            entry: entry,
                            allowedTagIDs: allowedTagIDs,
                            catalog: catalog,
                            maximumOutputTokens: outputTokenLimit
                        )
                        let labelIDs = try ProviderClassificationProtocol.parseLabelIDs(
                            run.content,
                            allowedTagIDs: allowedTagIDs,
                            maximumTagCount: configuration.maximumTagCount
                        )
                        try self.recordLLMCreatorClassification(
                            typeID: classifierType.id,
                            creatorID: representative.creatorID,
                            platformID: platformID,
                            creatorName: representative.creatorName,
                            labelIDs: labelIDs
                        )
                        let recordedOutputTokens = run.usage.outputTokens ?? outputTokenLimit
                        remainingOutputTokens -= max(0, recordedOutputTokens)
                        try self.appendProviderTestRecord(.init(
                            profileID: profile.id,
                            provider: profile.type.rawValue,
                            model: configuration.modelIdentifier,
                            operation: activatedRun ? "classify-creator-active" : "classify-creator-batch",
                            endpoint: ProviderTestProtocol.safeEndpoint(recordPlan!.plan.url),
                            method: recordPlan!.plan.method,
                            statusCode: run.statusCode,
                            durationMilliseconds: max(0, Int(Date().timeIntervalSince(startedAt) * 1_000)),
                            inputTokens: run.usage.inputTokens,
                            outputTokens: recordedOutputTokens,
                            classifierTypeID: classifierType.id,
                            outcome: "succeeded"
                        ))
                        successCount += 1
                    } catch {
                        firstFailure = firstFailure ?? error
                        if let recordPlan {
                            try? self.appendProviderTestRecord(.init(
                                profileID: profile.id,
                                provider: profile.type.rawValue,
                                model: configuration.modelIdentifier,
                                operation: activatedRun ? "classify-creator-active" : "classify-creator-batch",
                                endpoint: ProviderTestProtocol.safeEndpoint(recordPlan.plan.url),
                                method: recordPlan.plan.method,
                                statusCode: nil,
                                durationMilliseconds: max(0, Int(Date().timeIntervalSince(startedAt) * 1_000)),
                                inputTokens: nil,
                                outputTokens: nil,
                                classifierTypeID: classifierType.id,
                                outcome: "failed"
                            ))
                        }
                        if activatedRun { break }
                    }
                }
                self.providerClassificationRunning = false
                self.issue = successCount == 0 ? firstFailure?.localizedDescription : nil
                self.onWebStateChange?()
                if activatedRun, firstFailure == nil, remainingOutputTokens > 0 {
                    self.startActiveLLMClassification()
                }
            }
        } catch {
            issue = error.localizedDescription
        }
    }

    private func recordLLMCreatorClassification(
        typeID: String,
        creatorID: String,
        platformID: String,
        creatorName: String,
        labelIDs: [String]
    ) throws {
        guard var catalog = localState?.workspaceCatalog,
              let classifierType = catalog.classifierTypes.first(where: { $0.id == typeID }),
              CollectionPlatformRegistry.definition(for: platformID)?.supportsLLMAssist == true,
              let tree = catalog.trees.first(where: { $0.id == classifierType.treeID }) else {
            throw WebBridgeInputError.invalidChoice("creator LLM classifier type")
        }
        try storeCreatorClassification(
            in: &catalog,
            classifierType: classifierType,
            tree: tree,
            creatorID: creatorID,
            creatorName: creatorName,
            platformID: platformID,
            tagIDs: labelIDs,
            origin: .llmAssist
        )
        try coordinator?.updateWorkspaceCatalog(catalog)
        refreshLocalState()
    }

    /// Manual and LLM-assisted labels share this one creator-level persistence
    /// path. Individual entry inspection results are intentionally transient;
    /// retaining a label always identifies the creator whose collected entries
    /// may later be used for a local training run.
    private func storeCreatorClassification(
        in catalog: inout WorkspaceCatalog,
        classifierType: ClassifierTypeAsset,
        tree: TagTreeAsset,
        creatorID: String,
        creatorName: String,
        platformID: String,
        tagIDs: [String],
        negativeTagIDs: [String] = [],
        origin: ClassificationRecordOrigin
    ) throws {
        guard classifierType.applicablePlatformID == platformID,
              classifierType.treeID == tree.id,
              classifierType.treeRevision == tree.revision,
              let datasetIndex = catalog.datasets.firstIndex(where: { $0.id == classifierType.datasetID }) else {
            throw WebBridgeInputError.invalidChoice("creator classification")
        }
        let cleanedCreatorID = creatorID.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedCreatorName = creatorName.trimmingCharacters(in: .whitespacesAndNewlines)
        let positiveLabels = Array(Set(tagIDs)).sorted()
        let negativeLabels = Array(Set(negativeTagIDs)).sorted()
        let taxonomy = try tree.inferenceTaxonomy()
        let availableTagIDs: Set<String>
        if origin == .llmAssist,
           classifierType.llmAssistConfiguration?.restrictToLeafTags == false {
            availableTagIDs = Set(taxonomy.nodes.values.filter(\.predictable).map(\.id))
        } else {
            availableTagIDs = taxonomy.predictableLeafIDs
        }
        let maximumTagCount = origin == .llmAssist
            ? classifierType.llmAssistConfiguration?.maximumTagCount ?? CreatorClassificationRecord.maximumTagIDs
            : CreatorClassificationRecord.maximumTagIDs
        guard !cleanedCreatorID.isEmpty,
              !cleanedCreatorName.isEmpty,
              !positiveLabels.isEmpty || !negativeLabels.isEmpty,
              positiveLabels.count + negativeLabels.count <= maximumTagCount,
              Set(positiveLabels).isDisjoint(with: negativeLabels),
              positiveLabels.allSatisfy(availableTagIDs.contains),
              negativeLabels.allSatisfy(availableTagIDs.contains) else {
            throw WebBridgeInputError.invalidChoice("creator tag IDs")
        }
        _ = catalog.datasets[datasetIndex].upsertCreatorClassification(.init(
            classifierTypeID: classifierType.id,
            creatorID: cleanedCreatorID,
            creatorName: cleanedCreatorName,
            platformID: platformID,
            treeID: tree.id,
            treeRevision: tree.revision,
            tagIDs: positiveLabels,
            negativeTagIDs: negativeLabels,
            origin: origin,
            review: .approved
        ))
        catalog.datasets[datasetIndex].revision += 1
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

    func presentGeminiCredentialEntry() {
        do {
            let alert = NSAlert()
            alert.messageText = "Store Gemini API key"
            alert.informativeText = "This value is entered directly into this Mac’s Keychain. It is not sent through the web workspace."
            alert.addButton(withTitle: "Store in Keychain")
            alert.addButton(withTitle: "Cancel")
            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
            alert.accessoryView = field
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            try PersonalAuditCredentialStore.saveGeminiAPIKey(field.stringValue)
            hasStoredGeminiAPIKey = true
            issue = nil
        } catch {
            issue = error.localizedDescription
        }
    }

    func removeGeminiAPIKey() {
        do {
            try PersonalAuditCredentialStore.removeGeminiAPIKey()
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

    func storeCurrentTrainingExample() {
        do {
            guard let coordinator, result != nil else { throw AppInputError.noCurrentDecision }
            let entry = currentManualEntry()
            _ = try coordinator.recordLocalTrainingExample(
                evidence: entry,
                positiveLeafTagIDs: splitTagList(trainingPositiveTags),
                negativeLeafTagIDs: splitTagList(trainingNegativeTags)
            )
            refreshLocalState()
            trainingNotice = "Local label stored. Retrain when you are ready to apply the retained corpus."
            issue = nil
        } catch {
            trainingNotice = nil
            issue = error.localizedDescription
        }
    }

    func retrainLocalModel() {
        do {
            guard let coordinator else { return }
            let epochs = try positiveInteger(trainingEpochs, label: "Training epochs")
            let run = try coordinator.retrainLocalModel(epochs: epochs)
            refreshLocalState()
            trainingNotice = "Rebuilt the legacy correction layer from \(run.exampleCount) explicit label\(run.exampleCount == 1 ? "" : "s") in \(run.epochs) pass\(run.epochs == 1 ? "" : "es"). Train a workspace local model to update an active classifier type."
            issue = nil
        } catch {
            trainingNotice = nil
            issue = error.localizedDescription
        }
    }

    func localTrainingFeatureCount() -> Int {
        localState?.personalModel.state.values.reduce(0) { $0 + $1.count } ?? 0
    }

    func setBackupOwnerCode() {
        do {
            try LocalBackupOwnerCodeStore.setOwnerCode(backupOwnerCode)
            backupOwnerCode = ""
            hasBackupOwnerCode = true
            backupUnlocked = true
            backupNotice = "Backup controls are unlocked for this app session."
            issue = nil
        } catch {
            backupNotice = nil
            issue = error.localizedDescription
        }
    }

    func unlockBackupMode() {
        guard LocalBackupOwnerCodeStore.verifyOwnerCode(backupOwnerCode) else {
            backupUnlocked = false
            backupNotice = nil
            issue = "The local backup owner code did not match."
            return
        }
        backupOwnerCode = ""
        backupUnlocked = true
        backupNotice = "Backup controls are unlocked for this app session."
        issue = nil
    }

    func saveBackupConfiguration() {
        do {
            guard backupUnlocked else { throw AppInputError.backupLocked }
            let configuration = LocalBackupConfiguration(
                isEnabled: backupEnabled,
                directoryPath: backupDirectory
            )
            try coordinator?.updateLocalBackupConfiguration(configuration)
            refreshLocalState()
            backupNotice = backupEnabled
                ? "Private local snapshots will be written after each successful model rebuild."
                : "Automatic local backups are off. Existing snapshots were left untouched."
            issue = nil
        } catch {
            backupNotice = nil
            issue = error.localizedDescription
        }
    }

    func backupLocalModelNow() {
        do {
            guard backupUnlocked else { throw AppInputError.backupLocked }
            let destination = try coordinator?.backupLocalModelNow()
            backupNotice = destination.map { "Local model snapshot created in \($0.lastPathComponent)." }
            issue = nil
        } catch {
            backupNotice = nil
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

    private func currentManualEntry() -> EntryEvidence {
        let source = sourceID.trimmingCharacters(in: .whitespacesAndNewlines)
        let material = "\(source)\u{1F}\(surface.rawValue)\u{1F}\(title)"
        let digest = SHA256.hash(data: Data(material.utf8))
            .prefix(16)
            .map { String(format: "%02x", $0) }
            .joined()
        return .init(
            platform: manualPlatformID,
            entryID: "manual-\(digest)",
            sourceID: source.isEmpty ? nil : source,
            surface: surface,
            evidence: .init(title: title),
            policyIDs: policies.map(\.id)
        )
    }

    private func loadBackupConfiguration(from configuration: LocalBackupConfiguration?) {
        let defaultDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Vault Classifier Backups", isDirectory: true)
            .path
        backupDirectory = configuration?.directoryPath ?? defaultDirectory
        backupEnabled = configuration?.isEnabled ?? false
    }

    private func positiveInteger(_ raw: String, label: String) throws -> Int {
        let digits = raw.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(digits), value > 0 else { throw AppInputError.invalidNumber(label) }
        return value
    }

    private func providerPositiveInteger(_ raw: String, maximum: Int, label: String) throws -> Int {
        let value = try positiveInteger(raw, label: label)
        guard value <= maximum else { throw WebBridgeInputError.invalidChoice(label) }
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

    /// The WKWebView receives only the bounded local state necessary to render
    /// this development shell. Browser evidence, API keys, pairing material,
    /// audit rationales, and stable identifiers stay in native storage.
    func webSnapshot() -> [String: Any] {
        let state = localState ?? coordinator?.snapshot()
        let auditState = state?.auditState
        let budgetRecords = auditState?.budgetLedger.records ?? []
        let training = state?.trainingCorpus
        let backup = state?.backupConfiguration
        let notices: [String: Any] = [
            "training": trainingNotice ?? NSNull(),
            "backup": backupNotice ?? NSNull(),
            "auditDiagnostic": auditDiagnosticNotice ?? NSNull(),
        ]
        let inspectCatalog = state?.workspaceCatalog ?? .starter()
        let manualBinding = inspectCatalog.bindings.first(where: { $0.id == manualPlatformID })
        let manualClassifierType = manualBinding.flatMap { binding in
            binding.activeClassifierTypeID.flatMap { typeID in
                inspectCatalog.classifierTypes.first(where: { $0.id == typeID })
            }
        }
        let manualLLMAvailable = CollectionPlatformRegistry.definition(for: manualPlatformID)?.supportsLLMAssist == true &&
            manualClassifierType?.llmAssistConfiguration.flatMap { configuration in
                inspectCatalog.providerProfiles.contains(where: { $0.id == configuration.providerProfileID })
            } == true
        let inspect: [String: Any] = [
            "title": title,
            "sourceID": sourceID,
            "surface": surface.rawValue,
            "platformID": manualPlatformID,
            "llmAvailable": manualLLMAvailable,
            "llmRunning": providerClassificationRunning,
            "result": result.map(webResult) ?? NSNull(),
        ]
        let creatorAvatarBackfill: [String: Any] = [
            "running": creatorAvatarBackfillRunning,
            "foundCount": creatorAvatarBackfillFoundCount ?? NSNull(),
        ]
        let policyItems: [[String: Any]] = policies.map { policy in
            [
                "id": policy.id,
                "name": policy.name,
                "includeAny": policy.includeAnyTagIDs,
                "exclude": policy.excludeTagIDs,
                "feedAction": policy.feedAction.rawValue,
                "pageAction": policy.pageAction.rawValue,
            ]
        }
        let policiesPayload: [String: Any] = [
            "items": policyItems,
            "editor": [
                "id": editingPolicyID,
                "name": editingPolicyName,
                "includeAny": editingPolicyIncludeTag,
                "exclude": editingPolicyExcludeTag,
                "feedAction": editingFeedAction.rawValue,
                "pageAction": editingPageAction.rawValue,
            ] as [String: Any],
        ]
        let recentLedgerEntries = state.map { Array($0.ledger.suffix(12).reversed()) } ?? []
        let ledger: [[String: Any]] = recentLedgerEntries.map { entry in
            [
                "id": entry.id.uuidString,
                "cacheKey": entry.cacheKey,
                "grade": entry.auditGrade.rawValue,
                "modelVersion": entry.modelVersion,
                "hasCorrection": entry.correction != nil,
            ]
        }
        let activity: [String: Any] = [
            "cacheCount": state?.cache.count ?? 0,
            "cacheCapacity": state?.settings.cacheCapacity ?? 0,
            "ledgerCount": state?.ledger.count ?? 0,
            "correctionCount": state?.ledger.filter { $0.correction != nil }.count ?? 0,
            "settings": [
                "profile": profile.rawValue,
                "cacheCapacity": resourceCacheCapacity,
                "allowIdleWork": allowIdleWork,
                "allowBackgroundSync": allowBackgroundSync,
                "allowLocalLLMAudit": allowLocalLLMAudit,
                "packageUpdateMode": packageUpdateMode.rawValue,
            ] as [String: Any],
            "ledger": ledger,
        ]
        let lastRun: Any
        if let run = training?.lastRun {
            lastRun = [
                "exampleCount": run.exampleCount,
                "labelUpdateCount": run.labelUpdateCount,
                "epochs": run.epochs,
                "taxonomyVersion": run.taxonomyVersion,
            ] as [String: Any]
        } else {
            lastRun = NSNull()
        }
        let trainingPayload: [String: Any] = [
            "labelCount": training?.examples.count ?? 0,
            "capacity": state?.settings.cacheCapacity ?? 0,
            "featureCount": localTrainingFeatureCount(),
            "positiveTags": trainingPositiveTags,
            "negativeTags": trainingNegativeTags,
            "epochs": trainingEpochs,
            "lastRun": lastRun,
        ]
        let backupPayload: [String: Any] = [
            "hasOwnerCode": hasBackupOwnerCode,
            "unlocked": backupUnlocked,
            "enabled": backupEnabled,
            "directory": backupDirectory,
            "savedEnabled": backup?.isEnabled ?? false,
        ]
        let recentCandidates = auditState.map { Array($0.candidates.suffix(6).reversed()) } ?? []
        let candidates: [[String: Any]] = recentCandidates.map { candidate in
            [
                "id": candidate.auditID.uuidString,
                "intent": candidate.intent.rawValue,
                "priority": candidate.risk.priority,
                "modelVersion": candidate.localResult.modelVersion,
                "eligible": candidate.eligibility.isEligible,
                "running": auditRunningCandidateIDs.contains(candidate.auditID),
            ]
        }
        let recentResults = auditState.map { Array($0.results.suffix(5).reversed()) } ?? []
        let auditResults: [[String: Any]] = recentResults.map { auditResult in
            [
                "id": auditResult.auditID.uuidString,
                "finding": auditResult.finding.rawValue,
                "leafTags": auditResult.leafTagIDs,
                "confidence": auditResult.confidence ?? NSNull(),
                "tokens": (try? auditResult.usage.totalTokens()) ?? 0,
                "canApply": auditResult.finding == .potentialFalseAllow && auditLocalLearning && !isAuditApplied(auditResult.auditID),
                "policyIDs": confirmationPolicyIDs(for: auditResult),
            ]
        }
        let audit: [String: Any] = [
            "enabled": auditEnabled,
            "modelIdentifier": auditModelIdentifier,
            "effort": auditEffort.rawValue,
            "selectionMode": auditSelectionMode.rawValue,
            "outputCap": auditOutputCap,
            "requestCap": auditRequestTokenCap,
            "weeklyCap": auditWeeklyTokenCap,
            "monthlyCap": auditMonthlyTokenCap,
            "localLearning": auditLocalLearning,
            "hasStoredKey": hasStoredGeminiAPIKey,
            "dispatchAllowed": allowLocalLLMAudit,
            "candidateCount": auditState?.candidates.count ?? 0,
            "settledCount": budgetRecords.filter { $0.state == .settled }.count,
            "inFlightCount": budgetRecords.filter { $0.state == .reserved || $0.state == .possiblySent }.count,
            "uncertainCount": budgetRecords.filter { $0.state == .uncertain }.count,
            "weeklyTokens": auditBudgetTokenSummary(for: .weekly),
            "monthlyTokens": auditBudgetTokenSummary(for: .monthly),
            "candidates": candidates,
            "results": auditResults,
        ]
        let catalog = inspectCatalog
        var assets = [String: Any]()
        assets["trees"] = catalog.trees.map { tree in
                ["id": tree.id, "name": tree.name, "revision": tree.revision, "nodes": tree.nodes.enumerated().map { index, node -> [String: Any] in
                    let position = node.resolvedCanvasPosition(index: index)
                    return ["id": node.id, "name": node.name, "parentID": node.parentID ?? NSNull(), "retired": node.isRetired, "positionX": position.x, "positionY": position.y]
                }] as [String: Any]
            }
        assets["datasets"] = catalog.datasets.map { dataset in
                [
                    "id": dataset.id,
                    "name": dataset.name,
                    "revision": dataset.revision,
                    "creatorClassifications": dataset.creatorClassifications.map { classification -> [String: Any] in
                        [
                            "id": classification.id,
                            "classifierTypeID": classification.classifierTypeID,
                            "creatorID": classification.creatorID,
                            "creatorName": classification.creatorName,
                            "platformID": classification.platformID,
                            "treeID": classification.treeID,
                            "treeRevision": classification.treeRevision,
                            "tags": classification.tagIDs,
                            "negativeTags": classification.negativeTagIDs,
                            "origin": classification.origin.rawValue,
                            "review": classification.review.rawValue,
                            "updatedAtMilliseconds": classification.updatedAtMilliseconds,
                        ] as [String: Any]
                    },
                    "collectedEntries": dataset.collectedEntries.map { entry -> [String: Any] in
                        [
                            "id": entry.id,
                            "platformID": entry.platformID,
                            "entryID": entry.entryID,
                            "creatorID": entry.creatorID,
                            "creatorName": entry.creatorName,
                            "entryType": entry.entryType,
                            "title": entry.title,
                            "canonicalURL": entry.canonicalURL ?? NSNull(),
                            "attributes": entry.attributes,
                            "cachedCreatorAvatarURL": entry.attributes["creatorAvatarURL"].flatMap {
                                creatorAvatarCache?.cachedURL(for: $0)?.absoluteString
                            } ?? NSNull(),
                            "firstObservedAtMilliseconds": entry.firstObservedAtMilliseconds,
                            "lastObservedAtMilliseconds": entry.lastObservedAtMilliseconds,
                            "observationCount": entry.observationCount,
                        ] as [String: Any]
                    },
                ] as [String: Any]
            }
        assets["models"] = catalog.models.map { model in
                [
                    "id": model.id,
                    "name": model.name,
                    "treeID": model.treeID,
                    "treeRevision": model.treeRevision,
                    "datasetID": model.datasetID,
                    "datasetRevision": model.datasetRevision,
                    "platformID": model.trainingPlatformID ?? NSNull(),
                    "platformIDs": model.effectiveTrainingPlatformIDs,
                    "baseEmbeddingID": model.baseEmbeddingID?.rawValue ?? NSNull(),
                    "version": model.version,
                    "ready": model.isReady,
                    "training": model.embeddedTrainingReport.map { report in
                        [
                            "examples": report.exampleCount,
                            "updates": report.labelUpdateCount,
                            "epochs": report.epochs,
                            "loss": report.meanBinaryCrossEntropy,
                        ] as [String: Any]
                    } ?? NSNull(),
                ] as [String: Any]
            }
        assets["classifierTypes"] = catalog.classifierTypes.map { classifierType in
                [
                    "id": classifierType.id,
                    "name": classifierType.name,
                    "treeID": classifierType.treeID,
                    "treeRevision": classifierType.treeRevision,
                    "datasetID": classifierType.datasetID,
                    "datasetRevision": classifierType.datasetRevision,
                    "applicablePlatformID": classifierType.applicablePlatformID ?? NSNull(),
                    "localModelID": classifierType.localModelID ?? NSNull(),
                    "llmAssistConfiguration": classifierType.llmAssistConfiguration.map { configuration in
                        [
                            "providerProfileID": configuration.providerProfileID,
                            "modelIdentifier": configuration.modelIdentifier,
                            "dailyOutputTokenLimit": configuration.dailyOutputTokenLimit,
                            "dailyOutputTokensUsed": outputTokensUsedToday(in: catalog, classifierTypeID: classifierType.id),
                            "batchSize": configuration.batchSize,
                            "maximumTagCount": configuration.maximumTagCount,
                            "restrictToLeafTags": configuration.restrictToLeafTags,
                            "webSearchEnabled": configuration.webSearchEnabled,
                            "externalToolEnabled": configuration.externalToolEnabled,
                            "usePlatformAPIKeyFallback": configuration.usePlatformAPIKeyFallback,
                            "isActive": configuration.isActive,
                        ] as [String: Any]
                    } ?? NSNull(),
                    "decisionPriority": classifierType.decisionPriority.map(\.rawValue),
                ] as [String: Any]
            }
        assets["baseEmbeddings"] = LocalBaseEmbedding.allCases.map(\.rawValue)
        assets["providerProfiles"] = catalog.providerProfiles.map { profile in
                [
                    "id": profile.id,
                    "name": profile.name,
                    "type": profile.type.rawValue,
                    "defaultModelIdentifier": profile.type.defaultModelIdentifier,
                    "customEndpoint": profile.customEndpoint ?? NSNull(),
                    "protocolConfiguration": profile.protocolConfiguration,
                    "testModelIdentifier": profile.testModelIdentifier ?? NSNull(),
                    "hasCredential": profile.credential != nil,
                    "testing": testingProviderProfileIDs.contains(profile.id),
                    "testSucceeded": successfulProviderTestProfileIDs.contains(profile.id),
                ] as [String: Any]
            }
        assets["providerRequestRecords"] = catalog.providerRequestRecords.map { record in
                [
                    "id": record.id,
                    "profileID": record.profileID,
                    "provider": record.provider,
                    "model": record.model,
                    "operation": record.operation,
                    "endpoint": record.endpoint,
                    "method": record.method,
                    "statusCode": record.statusCode ?? NSNull(),
                    "durationMilliseconds": record.durationMilliseconds,
                    "inputTokens": record.inputTokens ?? NSNull(),
                    "outputTokens": record.outputTokens ?? NSNull(),
                    "classifierTypeID": record.classifierTypeID ?? NSNull(),
                    "outcome": record.outcome,
                    "createdAtMilliseconds": record.createdAtMilliseconds,
                ] as [String: Any]
            }
        assets["providerProtocols"] = Dictionary(uniqueKeysWithValues: APIKeyProviderType.allCases
                .map { type -> (String, [String: Any]) in
                    let descriptor = ProviderProtocolRegistry.descriptor(for: type)
                    return (type.rawValue, [
                        "identifier": descriptor.identifier,
                        "revision": descriptor.revision,
                        "family": descriptor.family.rawValue,
                        "supportsLLMConfiguration": descriptor.supportsLLMConfiguration,
                        "supportsPlatformData": descriptor.requestFormats.contains(where: { $0.operation == .readPublicContent }),
                        "supportsWebSearch": type == .openAI,
                        "allowsEndpointOverride": descriptor.allowsEndpointOverride,
                        "credentialRequired": !descriptor.credentialFields.isEmpty,
                        "credentialFields": descriptor.credentialFields.map(\.rawValue),
                        "configurationRequirements": descriptor.configurationRequirements.map { requirement in
                            [
                                "field": requirement.field.rawValue,
                                "defaultValue": requirement.defaultValue ?? NSNull(),
                                "requiredForDispatch": requirement.isRequiredForDispatch,
                            ] as [String: Any]
                        },
                    ])
                })
        assets["bindings"] = catalog.bindings.map { binding in
                let definition = CollectionPlatformRegistry.definition(for: binding.id)
                return ["id": binding.id, "name": binding.name, "browser": binding.browser, "treeID": binding.treeID, "datasetID": binding.datasetID, "activeClassifierTypeID": binding.activeClassifierTypeID ?? NSNull(), "activeModelID": binding.activeModelID ?? NSNull(), "policyID": binding.policyID ?? NSNull(), "collectionEnabled": binding.collectionEnabled, "sourceKind": definition?.sourceKind.rawValue ?? CollectionSourceKind.creator.rawValue, "supportsLocalModel": definition?.supportsLocalModel ?? false, "supportsLLMAssist": definition?.supportsLLMAssist ?? false, "supportsCreatorAvatarAPIFallback": definition?.supportsCreatorAvatarAPIFallback ?? false] as [String: Any]
            }
        assets["collectionPlatforms"] = CollectionPlatformRegistry.definitions.map { definition in
                ["id": definition.id, "name": definition.name, "browser": definition.browser, "sourceKind": definition.sourceKind.rawValue, "collectorAvailable": definition.collectorAvailable, "supportsLocalModel": definition.supportsLocalModel, "supportsLLMAssist": definition.supportsLLMAssist, "apiProviderType": definition.apiProviderType?.rawValue ?? NSNull(), "supportsCreatorAvatarAPIFallback": definition.supportsCreatorAvatarAPIFallback] as [String: Any]
            }
        assets["tokenUsage"] = budgetRecords.suffix(12).reversed().map { record -> [String: Any] in
                let usage = record.settledUsage ?? record.usageCeiling
                return [
                    "id": record.id.uuidString,
                    "provider": auditProvider.rawValue,
                    "model": auditModelIdentifier,
                    "input": usage.inputTokens,
                    "output": usage.outputTokens,
                    "other": usage.otherBilledTokens,
                    "status": record.state.rawValue,
                ]
            }
        assets["providerModelCatalogs"] = providerModelCatalogs
        assets["providerModelCatalogErrors"] = providerModelCatalogErrors
        assets["loadingProviderModelProfileIDs"] = Array(loadingProviderModelProfileIDs).sorted()
        let localHub = LocalClassifierHub.shared
        let hubClient = sharedHubClient
        let hostProgram = hubClient?.hubProgram ?? ""
        let bridgeState: String
        if localHub.isHosting {
            bridgeState = "hosting"
        } else if hubClient?.state == .connected, hostProgram == "macapp" {
            bridgeState = "joined-macapp"
        } else if hubClient?.state == .connected, hostProgram == "classifier" {
            bridgeState = "joined-classifier"
        } else {
            bridgeState = hubClient?.state.rawValue ?? "off"
        }
        let sharedHub: [String: Any] = [
            "address": SharedBrowserBridgeProtocol.address,
            "state": bridgeState,
            "error": hubClient?.error ?? localHub.lastError,
            "peers": localHub.isHosting ? localHub.peerSnapshot() : (hubClient?.peers ?? []),
            "hostProgram": localHub.isHosting ? "classifier" : hostProgram,
        ]
        let collectionDiagnosticsPayload: [[String: Any]] = (collectionDiagnostics?.records ?? []).suffix(80).reversed().map { record in
            [
                "id": record.id.uuidString,
                "recordedAtMilliseconds": record.recordedAtMilliseconds,
                "platformID": record.platformID ?? NSNull(),
                "event": record.event,
                "detail": record.detail ?? NSNull(),
                "outcome": record.outcome,
            ]
        }
        return [
            "workspace": workspace.rawValue,
            "issue": issue ?? NSNull(),
            "notices": notices,
            "inspect": inspect,
            "policies": policiesPayload,
            "activity": activity,
            "training": trainingPayload,
            "backup": backupPayload,
            "audit": audit,
            "assets": assets,
            "creatorAvatarBackfill": creatorAvatarBackfill,
            "bridge": sharedHub,
            "collectionDiagnostics": collectionDiagnosticsPayload,
        ]
    }

    /// The web renderer is a bundled local asset, but its messages are still
    /// treated as untrusted UI input. Keep the surface small and bounded so it
    /// cannot become another native IPC or provider-control path.
    /// Returns whether the web shell should publish a new snapshot. Credential
    /// keystrokes are persisted locally but deliberately keep the current DOM.
    func performWebAction(_ action: String, data: [String: Any]) -> Bool {
        do {
            switch action {
            case "state":
                refreshLocalState()
            case "workspace":
                let selected = try webString(data, key: "workspace", limit: 32)
                guard let value = Workspace(rawValue: selected) else { throw WebBridgeInputError.invalidChoice("workspace") }
                workspace = value
                if value == .localModel || value == .llmAssist || value == .browserBridge || value == .classificationData {
                    refreshLocalState()
                }
            case "connectSharedHub":
                connectSharedHub()
            case "disconnectSharedHub":
                disconnectSharedHub()
            case "createTree":
                createTree(name: try webString(data, key: "name", limit: 128))
            case "addCollectionPlatform":
                addCollectionPlatform(platformID: try webString(data, key: "platformID", limit: 64))
            case "confirmDeleteCollectionPlatform":
                confirmCollectionPlatformDeletion(platformID: try webString(data, key: "platformID", limit: 64))
            case "setCollectionEnabled":
                setCollectionEnabled(
                    platformID: try webString(data, key: "platformID", limit: 64),
                    enabled: try webBool(data, key: "enabled")
                )
            case "clearCollectionDiagnostics":
                clearCollectionDiagnostics()
            case "setActiveClassifierType":
                setActiveClassifierType(
                    platformID: try webString(data, key: "platformID", limit: 64),
                    classifierTypeID: try webOptionalString(data, key: "classifierTypeID", limit: 256)
                )
            case "createLocalModel":
                createLocalModel(name: try webString(data, key: "name", limit: 128))
            case "createClassifierType":
                createClassifierType(name: try webString(data, key: "name", limit: ClassifierTypeAsset.maximumNameLength))
            case "configureClassifierType":
                let priorityRaw = [
                    try webString(data, key: "priorityFirst", limit: 32),
                    try webString(data, key: "prioritySecond", limit: 32),
                    try webString(data, key: "priorityThird", limit: 32),
                ]
                let priority = try priorityRaw.map { raw -> ClassifierDecisionSource in
                    guard let source = ClassifierDecisionSource(rawValue: raw) else {
                        throw WebBridgeInputError.invalidChoice("decision priority")
                    }
                    return source
                }
                configureClassifierType(
                    typeID: try webString(data, key: "typeID", limit: 256),
                    name: try webString(data, key: "name", limit: ClassifierTypeAsset.maximumNameLength),
                    applicablePlatformID: try webString(data, key: "applicablePlatformID", limit: 64),
                    localModelID: try webOptionalString(data, key: "localModelID", limit: 256),
                    llmProviderProfileID: try webOptionalString(data, key: "llmProviderProfileID", limit: 128),
                    llmModelIdentifier: try webOptionalString(data, key: "llmModelIdentifier", limit: LLMAssistConfiguration.maximumModelIdentifierLength),
                    llmDailyOutputTokenLimit: try webOptionalString(data, key: "llmDailyOutputTokenLimit", limit: 16),
                    llmBatchSize: try webOptionalString(data, key: "llmBatchSize", limit: 4),
                    llmMaximumTagCount: try webOptionalString(data, key: "llmMaximumTagCount", limit: 4),
                    llmRestrictToLeafTags: data["llmRestrictToLeafTags"] as? Bool ?? false,
                    llmWebSearchEnabled: data["llmWebSearchEnabled"] as? Bool ?? false,
                    llmExternalToolEnabled: data["llmExternalToolEnabled"] as? Bool ?? false,
                    llmUsePlatformAPIKeyFallback: data["llmUsePlatformAPIKeyFallback"] as? Bool ?? false,
                    priority: priority
                )
            case "confirmDeleteClassifierType":
                confirmClassifierTypeDeletion(typeID: try webString(data, key: "typeID", limit: 256))
            case "createProviderProfile":
                createProviderProfile(typeRaw: try webString(data, key: "type", limit: 32))
            case "testProviderProfile":
                testProviderProfile(
                    profileID: try webString(data, key: "profileID", limit: 128),
                    rawCredential: try webOptionalString(data, key: "credential", limit: ProviderCredentialRecord.maximumCharacters),
                    clearCredential: data["clearCredential"] as? Bool ?? false,
                    customEndpoint: try webOptionalString(data, key: "customEndpoint", limit: APIKeyProviderProfile.maximumEndpointLength),
                    testModelIdentifier: try webOptionalString(data, key: "testModelIdentifier", limit: APIKeyProviderProfile.maximumTestModelIdentifierLength),
                    protocolConfiguration: try webProviderConfiguration(data)
                )
            case "updateProviderConnection":
                updateProviderConnection(
                    profileID: try webString(data, key: "profileID", limit: 128),
                    rawCredential: try webOptionalString(data, key: "credential", limit: ProviderCredentialRecord.maximumCharacters),
                    clearCredential: data["clearCredential"] as? Bool ?? false,
                    customEndpoint: try webOptionalString(data, key: "customEndpoint", limit: APIKeyProviderProfile.maximumEndpointLength),
                    testModelIdentifier: try webOptionalString(data, key: "testModelIdentifier", limit: APIKeyProviderProfile.maximumTestModelIdentifierLength),
                    protocolConfiguration: try webProviderConfiguration(data)
                )
            case "saveProviderCredential":
                let saved = saveProviderCredential(
                    profileID: try webString(data, key: "profileID", limit: 128),
                    rawCredential: try webString(data, key: "credential", limit: ProviderCredentialRecord.maximumCharacters),
                    clearCredential: data["clearCredential"] as? Bool ?? false
                )
                return !saved
            case "fetchCustomProviderModelCatalog":
                fetchCustomProviderModelCatalog(profileID: try webString(data, key: "profileID", limit: 128))
            case "setLLMAssistActive":
                setLLMAssistActive(
                    typeID: try webString(data, key: "typeID", limit: 256),
                    isActive: data["isActive"] as? Bool ?? false
                )
            case "classifyCreatorBatchWithLLM":
                classifyCreatorBatchWithLLM(typeID: try webString(data, key: "typeID", limit: 256))
            case "confirmDeleteProviderProfile":
                confirmProviderProfileDeletion(profileID: try webString(data, key: "profileID", limit: 128))
            case "renameLocalModel":
                renameLocalModel(modelID: try webString(data, key: "modelID", limit: 256), name: try webString(data, key: "name", limit: 128))
            case "confirmDeleteLocalModel":
                confirmLocalModelDeletion(modelID: try webString(data, key: "modelID", limit: 256))
            case "configureLocalModel":
                configureLocalModel(
                    modelID: try webString(data, key: "modelID", limit: 256),
                    treeID: try webString(data, key: "treeID", limit: 256),
                    platformIDs: try webStringArray(data, key: "platformIDs", limit: LocalModelAsset.maximumTrainingPlatforms, elementLimit: 64),
                    baseEmbeddingID: try webOptionalString(data, key: "baseEmbeddingID", limit: 128)
                )
            case "trainLocalModel":
                trainLocalModel(
                    modelID: try webString(data, key: "modelID", limit: 256),
                    treeID: try webString(data, key: "treeID", limit: 256),
                    platformIDs: try webStringArray(data, key: "platformIDs", limit: LocalModelAsset.maximumTrainingPlatforms, elementLimit: 64),
                    baseEmbeddingID: try webOptionalString(data, key: "baseEmbeddingID", limit: 128)
                )
            case "renameTree":
                renameTree(treeID: try webString(data, key: "treeID", limit: 256), name: try webString(data, key: "name", limit: 128))
            case "deleteTree":
                deleteTree(treeID: try webString(data, key: "treeID", limit: 256))
            case "rearrangeTree":
                rearrangeTree(treeID: try webString(data, key: "treeID", limit: 256))
            case "addTag":
                addTag(treeID: try webString(data, key: "treeID", limit: 256), name: try webString(data, key: "name", limit: 128), parentID: try webOptionalString(data, key: "parentID", limit: 256), positionX: try webCanvasCoordinate(data, key: "positionX"), positionY: try webCanvasCoordinate(data, key: "positionY"))
            case "moveTag":
                moveTag(treeID: try webString(data, key: "treeID", limit: 256), nodeID: try webString(data, key: "nodeID", limit: 256), positionX: try webCanvasCoordinate(data, key: "positionX"), positionY: try webCanvasCoordinate(data, key: "positionY"))
            case "renameTag":
                renameTag(treeID: try webString(data, key: "treeID", limit: 256), nodeID: try webString(data, key: "nodeID", limit: 256), name: try webString(data, key: "name", limit: 128), refreshState: false)
            case "connectTag":
                connectTag(treeID: try webString(data, key: "treeID", limit: 256), nodeID: try webString(data, key: "nodeID", limit: 256), parentID: try webString(data, key: "parentID", limit: 256))
            case "disconnectTag":
                disconnectTag(treeID: try webString(data, key: "treeID", limit: 256), nodeID: try webString(data, key: "nodeID", limit: 256))
            case "deleteTag":
                deleteTag(treeID: try webString(data, key: "treeID", limit: 256), nodeID: try webString(data, key: "nodeID", limit: 256))
            case "recordCreatorClassification":
                recordCreatorClassification(
                    typeID: try webString(data, key: "typeID", limit: 256),
                    creatorKey: try webString(data, key: "creatorKey", limit: 768),
                    tagIDs: try webStringArray(data, key: "tagIDs", limit: CreatorClassificationRecord.maximumTagIDs, elementLimit: 256),
                    negativeTagIDs: try webStringArray(data, key: "negativeTagIDs", limit: CreatorClassificationRecord.maximumTagIDs, elementLimit: 256)
                )
            case "backfillCreatorAvatars":
                backfillCreatorAvatars(typeID: try webString(data, key: "typeID", limit: 256))
            case "classifyCreatorWithLLM":
                classifyCreatorWithLLM(
                    typeID: try webString(data, key: "typeID", limit: 256),
                    creatorKey: try webString(data, key: "creatorKey", limit: 768)
                )
            case "classify":
                title = try webString(data, key: "title", limit: 4_096)
                sourceID = try webString(data, key: "sourceID", limit: 1_024)
                let platformID = try webString(data, key: "platformID", limit: 64)
                guard localState?.workspaceCatalog.bindings.contains(where: { $0.id == platformID }) == true else {
                    throw WebBridgeInputError.invalidChoice("classification platform")
                }
                manualPlatformID = platformID
                let surfaceValue = try webString(data, key: "surface", limit: 16)
                guard let value = EntrySurface(rawValue: surfaceValue) else { throw WebBridgeInputError.invalidChoice("surface") }
                surface = value
                classify()
            case "classifyWithLLM":
                title = try webString(data, key: "title", limit: 4_096)
                sourceID = try webString(data, key: "sourceID", limit: 1_024)
                let platformID = try webString(data, key: "platformID", limit: 64)
                guard localState?.workspaceCatalog.bindings.contains(where: { $0.id == platformID }) == true else {
                    throw WebBridgeInputError.invalidChoice("classification platform")
                }
                manualPlatformID = platformID
                let surfaceValue = try webString(data, key: "surface", limit: 16)
                guard let value = EntrySurface(rawValue: surfaceValue) else { throw WebBridgeInputError.invalidChoice("surface") }
                surface = value
                classifyCurrentEntryWithLLM()
            case "markCorrection":
                let raw = try webString(data, key: "correction", limit: 32)
                guard let correction = UserCorrection(rawValue: raw) else { throw WebBridgeInputError.invalidChoice("correction") }
                markCurrentResult(correction)
            case "newPolicy":
                startNewPolicy()
            case "selectPolicy":
                let identifier = try webString(data, key: "id", limit: 256)
                guard let policy = policies.first(where: { $0.id == identifier }) else { throw WebBridgeInputError.invalidChoice("policy") }
                select(policy)
            case "savePolicy":
                editingPolicyID = try webString(data, key: "id", limit: 256)
                editingPolicyName = try webString(data, key: "name", limit: 256)
                editingPolicyIncludeTag = try webString(data, key: "includeAny", limit: 4_096)
                editingPolicyExcludeTag = try webString(data, key: "exclude", limit: 4_096)
                let feed = try webString(data, key: "feedAction", limit: 16)
                let page = try webString(data, key: "pageAction", limit: 16)
                guard let feedAction = PresentationAction(rawValue: feed), let pageAction = PresentationAction(rawValue: page) else {
                    throw WebBridgeInputError.invalidChoice("policy action")
                }
                editingFeedAction = feedAction
                editingPageAction = pageAction
                savePolicy()
            case "deletePolicy":
                deleteEditingPolicy()
            case "clearCorrection":
                let raw = try webString(data, key: "id", limit: 64)
                guard let identifier = UUID(uuidString: raw) else { throw WebBridgeInputError.invalidChoice("decision") }
                clearCorrection(identifier)
            case "saveResourceSettings":
                let rawProfile = try webString(data, key: "profile", limit: 32)
                let rawMode = try webString(data, key: "packageUpdateMode", limit: 32)
                guard let selectedProfile = ResourceProfile(rawValue: rawProfile), let updateMode = PackageUpdateMode(rawValue: rawMode) else {
                    throw WebBridgeInputError.invalidChoice("resource setting")
                }
                profile = selectedProfile
                resourceCacheCapacity = try webString(data, key: "cacheCapacity", limit: 16)
                allowIdleWork = try webBool(data, key: "allowIdleWork")
                allowBackgroundSync = try webBool(data, key: "allowBackgroundSync")
                allowLocalLLMAudit = try webBool(data, key: "allowLocalLLMAudit")
                packageUpdateMode = updateMode
                saveResourceSettings()
            case "storeTraining":
                trainingPositiveTags = try webString(data, key: "positiveTags", limit: 4_096)
                trainingNegativeTags = try webString(data, key: "negativeTags", limit: 4_096)
                storeCurrentTrainingExample()
            case "retrain":
                trainingEpochs = try webString(data, key: "epochs", limit: 16)
                retrainLocalModel()
            case "setBackupOwnerCode":
                backupOwnerCode = try webString(data, key: "ownerCode", limit: 512)
                setBackupOwnerCode()
            case "unlockBackup":
                backupOwnerCode = try webString(data, key: "ownerCode", limit: 512)
                unlockBackupMode()
            case "saveBackup":
                backupDirectory = try webString(data, key: "directory", limit: 2_048)
                backupEnabled = try webBool(data, key: "enabled")
                saveBackupConfiguration()
            case "backupNow":
                backupLocalModelNow()
            case "saveAudit":
                auditEnabled = try webBool(data, key: "enabled")
                auditModelIdentifier = try webString(data, key: "modelIdentifier", limit: 128)
                let rawEffort = try webString(data, key: "effort", limit: 16)
                let rawSelection = try webString(data, key: "selectionMode", limit: 64)
                guard let effort = AuditReasoningEffort(rawValue: rawEffort), let selection = AuditSelectionMode(rawValue: rawSelection) else {
                    throw WebBridgeInputError.invalidChoice("audit setting")
                }
                auditEffort = effort
                auditSelectionMode = selection
                auditOutputCap = try webString(data, key: "outputCap", limit: 16)
                auditRequestTokenCap = try webString(data, key: "requestCap", limit: 16)
                auditWeeklyTokenCap = try webString(data, key: "weeklyCap", limit: 16)
                auditMonthlyTokenCap = try webString(data, key: "monthlyCap", limit: 16)
                auditLocalLearning = try webBool(data, key: "localLearning")
                saveAuditConfiguration()
            case "presentGeminiCredentialEntry":
                presentGeminiCredentialEntry()
            case "removeGeminiKey":
                removeGeminiAPIKey()
            case "queueSuggestedAudits":
                queueSuggestedAudits()
            case "queueCurrentAudit":
                queueCurrentAudit()
            case "runAudit":
                let raw = try webString(data, key: "id", limit: 64)
                guard let identifier = UUID(uuidString: raw), let candidate = localState?.auditState.candidates.first(where: { $0.auditID == identifier }) else {
                    throw WebBridgeInputError.invalidChoice("audit candidate")
                }
                runGeminiAudit(candidate)
            case "confirmAudit":
                let raw = try webString(data, key: "id", limit: 64)
                let policyID = try webString(data, key: "policyID", limit: 256)
                guard let identifier = UUID(uuidString: raw), let auditResult = localState?.auditState.results.first(where: { $0.auditID == identifier }) else {
                    throw WebBridgeInputError.invalidChoice("audit result")
                }
                confirmFalseAllowAudit(auditResult, policyID: policyID)
            case "copyDiagnostics":
                copyRedactedAuditDiagnostics()
            default:
                throw WebBridgeInputError.invalidChoice("action")
            }
        } catch {
            issue = error.localizedDescription
        }
        return true
    }

    private func webResult(_ value: ClassificationResult) -> [String: Any] {
        [
            "strongestAction": value.strongestAction.rawValue,
            "threshold": value.threshold,
            "leafTags": value.selectedLeafTagIDs,
            "ancestorTags": value.ancestorTagIDs,
            "scores": Array(value.scores.prefix(4).map { score in
                ["tag": score.tagID, "score": score.finalScore] as [String: Any]
            }),
            "decisions": value.decisions.map { decision in
                [
                    "policyID": decision.policyID,
                    "action": decision.action.rawValue,
                    "explanation": decision.explanation,
                ] as [String: Any]
            },
        ]
    }

    private func webString(_ data: [String: Any], key: String, limit: Int) throws -> String {
        guard let value = data[key] as? String else { throw WebBridgeInputError.missingValue(key) }
        guard value.count <= limit else { throw WebBridgeInputError.exceedsLimit(key, limit) }
        return value
    }

    private func webOptionalString(_ data: [String: Any], key: String, limit: Int) throws -> String? {
        guard let value = data[key] as? String else { return nil }
        guard value.count <= limit else { throw WebBridgeInputError.exceedsLimit(key, limit) }
        return value
    }

    private func webStringArray(_ data: [String: Any], key: String, limit: Int, elementLimit: Int) throws -> [String] {
        guard let raw = data[key] as? [Any] else { throw WebBridgeInputError.missingValue(key) }
        guard raw.count <= limit else { throw WebBridgeInputError.exceedsLimit(key, limit) }
        let values = try raw.map { value -> String in
            guard let string = value as? String, !string.isEmpty, string.count <= elementLimit else {
                throw WebBridgeInputError.invalidChoice(key)
            }
            return string
        }
        guard Set(values).count == values.count else { throw WebBridgeInputError.invalidChoice(key) }
        return values
    }

    private func webProviderConfiguration(_ data: [String: Any]) throws -> [String: String]? {
        guard let raw = data["protocolConfiguration"] as? [String: Any] else { return nil }
        guard raw.count <= ProviderConfigurationField.allCases.count else {
            throw WebBridgeInputError.exceedsLimit("protocol configuration", ProviderConfigurationField.allCases.count)
        }
        return try Dictionary(uniqueKeysWithValues: raw.map { key, value in
            guard ProviderConfigurationField(rawValue: key) != nil,
                  let string = value as? String,
                  string.count <= 512 else {
                throw WebBridgeInputError.invalidChoice("protocol configuration")
            }
            return (key, string)
        })
    }

    private func webCanvasCoordinate(_ data: [String: Any], key: String) throws -> Double {
        guard let value = data[key] as? NSNumber else { throw WebBridgeInputError.missingValue(key) }
        let coordinate = value.doubleValue
        guard coordinate.isFinite, (0...20_000).contains(coordinate) else {
            throw WebBridgeInputError.invalidChoice("canvas coordinate")
        }
        return coordinate
    }

    private func webBool(_ data: [String: Any], key: String) throws -> Bool {
        guard let value = data[key] as? Bool else { throw WebBridgeInputError.missingValue(key) }
        return value
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
    case backupLocked

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
        case .backupLocked: return "Enter the local backup owner code before changing backup mode."
        }
    }
}

private enum ProviderTestHTTPError: Error, LocalizedError {
    case status(Int)

    var errorDescription: String? {
        switch self {
        case .status(let status): return "The provider test returned HTTP \(status)."
        }
    }
}

private enum WebBridgeInputError: Error, LocalizedError {
    case missingValue(String)
    case exceedsLimit(String, Int)
    case invalidChoice(String)

    var errorDescription: String? {
        switch self {
        case .missingValue(let field): return "The web UI did not supply a valid \(field) value."
        case .exceedsLimit(let field, let limit): return "\(field) must contain at most \(limit) characters."
        case .invalidChoice(let field): return "The web UI supplied an unsupported \(field)."
        }
    }
}

#if false
// Retained temporarily as an implementation reference while the current
// development shell is wholly AppKit + WKWebView. It is not compiled or used.
private struct VaultClassifierRootView: View {
    @StateObject private var model = VaultClassifierViewModel()

    var body: some View {
        NavigationSplitView {
            List(selection: workspaceSelection) {
                Section("WORK") {
                    workspaceRow(.inspect, title: "Inspect entry", icon: "wand.and.stars")
                    workspaceRow(.policies, title: "Named policies", icon: "tag")
                    workspaceRow(.activity, title: "Local activity", icon: "archivebox")
                    workspaceRow(.training, title: "Local training", icon: "brain.head.profile")
                }

                Section("CONTROL") {
                    workspaceRow(.backup, title: "Local backup", icon: "externaldrive.badge.checkmark")
                    workspaceRow(.audit, title: "Personal audit", icon: "checklist.checked")
                    workspaceRow(.integration, title: "Browser bridge", icon: "cable.connector")
                }

                Section("LOCAL STATUS") {
                    Label("Seed package verified", systemImage: "checkmark.seal.fill")
                    Label("Offline on this Mac", systemImage: "lock.fill")
                }
                .font(.caption)
                .foregroundStyle(VaultPalette.muted)
            }
            .listStyle(.sidebar)
            .navigationTitle("Vault Classifier")
            .frame(minWidth: 225)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    workspaceContent
                }
                .frame(maxWidth: 920, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.vertical, 28)
            }
            .background(VaultPalette.canvas)
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Picker("Resource profile", selection: $model.profile) {
                        ForEach(ResourceProfile.allCases, id: \.self) { profile in
                            Text(profile.rawValue.capitalized).tag(profile)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 230)
                    .onChange(of: model.profile) { _ in
                        model.applyResourceProfileDefaults()
                    }
                }
                ToolbarItem(placement: .automatic) {
                    Label("Offline", systemImage: "lock.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(VaultPalette.muted)
                }
            }
        }
        .frame(minWidth: 980, minHeight: 650)
        .tint(VaultPalette.navy)
        .onAppear { model.classify() }
    }

    private var workspaceSelection: Binding<VaultClassifierViewModel.Workspace?> {
        Binding(
            get: { model.workspace },
            set: { selected in
                guard let selected else { return }
                model.workspace = selected
                if selected == .activity || selected == .training || selected == .backup || selected == .audit {
                    model.refreshLocalState()
                }
            }
        )
    }

    @ViewBuilder
    private func workspaceRow(_ workspace: VaultClassifierViewModel.Workspace, title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .tag(workspace)
    }

    @ViewBuilder
    private var workspaceContent: some View {
        switch model.workspace {
        case .inspect:
            inspectWorkspace
        case .policies:
            policyWorkspace
        case .activity:
            activityWorkspace
        case .training:
            trainingWorkspace
        case .backup:
            backupWorkspace
        case .audit:
            auditWorkspace
        case .integration:
            integrationWorkspace
        }
    }

    private var inspectWorkspace: some View {
        VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Inspect an entry")
                                .font(.title2.weight(.semibold))
                                .foregroundStyle(VaultPalette.ink)
                            Text("Provide the same compact evidence a browser adapter will send. Ancestors are derived locally.")
                                .font(.system(size: 12))
                                .foregroundStyle(VaultPalette.muted)
                        }
                        Spacer()
                        Text(model.surface == .feed ? "FEED DECISION" : "PAGE DECISION")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .tracking(0.7)
                            .foregroundStyle(VaultPalette.cyan)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background(VaultPalette.cyanPale, in: Capsule())
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
                        }
                        .buttonStyle(VaultPrimaryActionStyle())

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
                        .font(.title2.weight(.semibold))
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
                            .background(model.editingPolicyID == policy.id ? VaultPalette.navyPale : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
                        .font(.title2.weight(.semibold))
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
                        .background(VaultPalette.inset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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

    private var trainingWorkspace: some View {
        let corpus = model.localState?.trainingCorpus
        let labelCount = corpus?.examples.count ?? 0
        let featureCount = model.localTrainingFeatureCount()
        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Local training")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(VaultPalette.ink)
                    Text("Build a bounded correction layer only from labels you explicitly store. Viewing, clicking, a raw correction, and provider output alone are never training data.")
                        .font(.system(size: 12))
                        .foregroundStyle(VaultPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Text(labelCount == 0 ? "NO LABELS" : "LOCAL ONLY")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(0.7)
                    .foregroundStyle(labelCount == 0 ? VaultPalette.muted : VaultPalette.navy)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(labelCount == 0 ? .gray.opacity(0.12) : VaultPalette.navyPale, in: Capsule())
            }

            HStack(spacing: 10) {
                VaultMetric(title: "EXPLICIT LABELS", value: "\(labelCount) / \(model.localState?.settings.cacheCapacity ?? 0)")
                VaultMetric(title: "MODEL FEATURES", value: featureCount.formatted())
                VaultMetric(title: "LAST REBUILD", value: corpus?.lastRun.map { "\($0.exampleCount) labels" } ?? "Not yet")
            }

            VStack(alignment: .leading, spacing: 11) {
                VaultFieldLabel(title: "CURRENT ENTRY LABEL", hint: "Exact predictable leaf IDs")
                Text("Classify the entry first, then state what it is and is not. Ancestor paths are computed locally; do not enter parent nodes such as content.topics.")
                    .font(.system(size: 11))
                    .foregroundStyle(VaultPalette.muted)

                VStack(alignment: .leading, spacing: 6) {
                    VaultFieldLabel(title: "POSITIVE LEAF TAGS", hint: "Comma separated")
                    TextField("content.entities.clash-royale", text: $model.trainingPositiveTags)
                        .textFieldStyle(.plain)
                        .vaultInput()
                }
                VStack(alignment: .leading, spacing: 6) {
                    VaultFieldLabel(title: "NEGATIVE LEAF TAGS", hint: "Optional, comma separated")
                    TextField("content.entities.minecraft", text: $model.trainingNegativeTags)
                        .textFieldStyle(.plain)
                        .vaultInput()
                }
                HStack(spacing: 10) {
                    Button("Store current label") { model.storeCurrentTrainingExample() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.result == nil)
                    Text("The newest label for the same source entry replaces its older label. Labels remain on this Mac.")
                        .font(.system(size: 10))
                        .foregroundStyle(VaultPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .background(VaultPalette.navyPale.opacity(0.62), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 10) {
                VaultFieldLabel(title: "REBUILD CORRECTION LAYER", hint: "No network or provider")
                HStack(alignment: .bottom, spacing: 10) {
                    VStack(alignment: .leading, spacing: 6) {
                        VaultFieldLabel(title: "PASSES", hint: "1–12")
                        TextField("3", text: $model.trainingEpochs)
                            .textFieldStyle(.plain)
                            .vaultInput()
                            .frame(width: 110)
                    }
                    Button("Retrain local model") { model.retrainLocalModel() }
                        .buttonStyle(.borderedProminent)
                        .disabled(labelCount == 0)
                    Spacer(minLength: 0)
                }
                Text("Rebuild replaces the previous personal correction layer deterministically from retained compatible labels. It affects new classifications; existing activity remains an historical record until it is explicitly re-evaluated.")
                    .font(.system(size: 10))
                    .foregroundStyle(VaultPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let run = corpus?.lastRun {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(VaultPalette.navy)
                    Text("Last rebuild: \(run.exampleCount) labels • \(run.labelUpdateCount) updates • \(run.epochs) passes • taxonomy \(run.taxonomyVersion)")
                        .font(.system(size: 10))
                        .foregroundStyle(VaultPalette.muted)
                }
            }
            if let notice = model.trainingNotice {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(VaultPalette.navy)
                    Text(notice)
                        .font(.system(size: 11))
                        .foregroundStyle(VaultPalette.muted)
                }
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(VaultPalette.navyPale.opacity(0.58), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            if let issue = model.issue { VaultIssueCard(issue: issue) }
        }
    }

    private var backupWorkspace: some View {
        let configuration = model.localState?.backupConfiguration
        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Local model backup")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(VaultPalette.ink)
                    Text("Keep private copies of this Mac's active seed package, local training corpus, and personal correction layer. Nothing is uploaded, shared, or sent to a server.")
                        .font(.system(size: 12))
                        .foregroundStyle(VaultPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Text(configuration?.isEnabled == true ? "ON" : "OFF")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(0.7)
                    .foregroundStyle(configuration?.isEnabled == true ? VaultPalette.navy : VaultPalette.muted)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(configuration?.isEnabled == true ? VaultPalette.navyPale : .gray.opacity(0.12), in: Capsule())
            }

            VStack(alignment: .leading, spacing: 10) {
                VaultFieldLabel(title: "OWNER GATE", hint: "This Mac's Keychain")
                if model.backupUnlocked {
                    Label("Backup controls are unlocked for this app session.", systemImage: "lock.open.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(VaultPalette.navy)
                } else {
                    Text("Set an owner code once, or enter the existing owner code to unlock backup mode for this app session. The code itself is never written to the state file or a backup.")
                        .font(.system(size: 11))
                        .foregroundStyle(VaultPalette.muted)
                    HStack(spacing: 8) {
                        SecureField(model.hasBackupOwnerCode ? "Enter local backup owner code" : "Create local backup owner code (8+ characters)", text: $model.backupOwnerCode)
                            .textFieldStyle(.plain)
                            .vaultInput()
                        Button(model.hasBackupOwnerCode ? "Unlock" : "Set code") {
                            if model.hasBackupOwnerCode {
                                model.unlockBackupMode()
                            } else {
                                model.setBackupOwnerCode()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.backupOwnerCode.isEmpty)
                    }
                }
            }
            .padding(12)
            .background(VaultPalette.navyPale.opacity(0.62), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 10) {
                VaultFieldLabel(title: "PRIVATE SNAPSHOT FOLDER", hint: "A local path you control")
                TextField("/Users/you/Vault Classifier Backups", text: $model.backupDirectory)
                    .textFieldStyle(.plain)
                    .vaultInput()
                    .disabled(!model.backupUnlocked)
                Toggle("Back up automatically after every successful local model rebuild", isOn: $model.backupEnabled)
                    .toggleStyle(.switch)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(VaultPalette.ink)
                    .disabled(!model.backupUnlocked)
                Text("Each snapshot contains model material only: the active package, policies, explicit training corpus, and correction layer—not the activity cache, decision ledger, or audit history. The folder retains the current snapshot and three previous snapshots; no existing snapshot is deleted when automatic mode is turned off.")
                    .font(.system(size: 10))
                    .foregroundStyle(VaultPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button("Save backup mode") { model.saveBackupConfiguration() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.backupUnlocked)
                    Button("Create backup now") { model.backupLocalModelNow() }
                        .buttonStyle(.bordered)
                        .disabled(!model.backupUnlocked || configuration?.isEnabled != true)
                }
            }

            if let notice = model.backupNotice {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(VaultPalette.navy)
                    Text(notice)
                        .font(.system(size: 11))
                        .foregroundStyle(VaultPalette.muted)
                }
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(VaultPalette.navyPale.opacity(0.58), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            if let issue = model.issue { VaultIssueCard(issue: issue) }
        }
    }

    private var auditWorkspace: some View {
        let auditState = model.localState?.auditState
        let configuration = auditState?.configuration
        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Personal audit")
                        .font(.title2.weight(.semibold))
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
                    .foregroundStyle(model.auditEnabled && model.allowLocalLLMAudit && model.hasStoredGeminiAPIKey ? VaultPalette.gold : VaultPalette.muted)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(model.auditEnabled && model.allowLocalLLMAudit && model.hasStoredGeminiAPIKey ? VaultPalette.goldPale : .gray.opacity(0.12), in: Capsule())
            }

            Toggle("Enable personal local auditing", isOn: $model.auditEnabled)
                .toggleStyle(.switch)
                .tint(VaultPalette.gold)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(VaultPalette.ink)

            if model.auditEnabled && !model.allowLocalLLMAudit {
                Text("Resource controls currently prevent Gemini dispatch. Enable Personal LLM audit dispatch in Local activity before a queued item can spend tokens.")
                    .font(.system(size: 11))
                    .foregroundStyle(VaultPalette.muted)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(VaultPalette.goldPale, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
                                .background(VaultPalette.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
                            Button(model.hasStoredGeminiAPIKey ? "Replace" : "Store") { model.presentGeminiCredentialEntry() }
                                .buttonStyle(.bordered)
                            if model.hasStoredGeminiAPIKey {
                                Button("Remove", role: .destructive) { model.removeGeminiAPIKey() }
                                    .buttonStyle(.bordered)
                            }
                        }
                        Text("The extension, shared local bridge, state file, diagnostics, and Vault server never receive this credential. An entry is sent to Gemini only after you press Run Gemini below.")
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
                    .background(VaultPalette.goldPale, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            HStack(spacing: 10) {
                Button("Save local audit settings") { model.saveAuditConfiguration() }
                    .buttonStyle(.borderedProminent)
                    .tint(VaultPalette.gold)
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
                    .foregroundStyle(VaultPalette.gold)
            }

            if let candidates = auditState?.candidates.suffix(6).reversed(), !candidates.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    VaultFieldLabel(title: "LOCAL AUDIT QUEUE", hint: "No evidence leaves this Mac until you explicitly run a configured adapter")
                    ForEach(Array(candidates)) { candidate in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: candidate.intent == .potentialFalseAllow ? "questionmark.circle" : "flag.fill")
                                .foregroundStyle(VaultPalette.gold)
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
                                .foregroundStyle(candidate.eligibility.isEligible ? VaultPalette.gold : VaultPalette.red)
                            Button(model.isRunningAudit(candidate) ? "Running…" : "Run Gemini") { model.runGeminiAudit(candidate) }
                                .buttonStyle(.bordered)
                                .tint(VaultPalette.gold)
                                .font(.system(size: 10))
                                .disabled(!candidate.eligibility.isEligible || !model.auditEnabled || !model.allowLocalLLMAudit || !model.hasStoredGeminiAPIKey || model.isRunningAudit(candidate))
                        }
                        .padding(10)
                        .background(VaultPalette.inset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
                                    .foregroundStyle(auditResult.finding == .potentialFalseAllow ? VaultPalette.red : VaultPalette.gold)
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
                        .background(VaultPalette.inset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
            }

            Text(configuration == nil
                ? "Provider credentials are never stored in the extension, shared local bridge, this state file, or a server."
                : "The saved configuration has no provider credential; it only controls local selection and budget reservations. Gemini returns actual input, output, and thinking/other usage for the local ledger.")
                .font(.system(size: 11))
                .foregroundStyle(VaultPalette.muted)

            if let issue = model.issue { VaultIssueCard(issue: issue) }
        }
    }

    private var integrationWorkspace: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Browser bridge")
                .font(.title2.weight(.semibold))
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
    // Shared Vault language: semantic macOS surfaces, cool navy hardware, and
    // restrained accents with one clear meaning each.
    static let navy = Color(red: 34 / 255, green: 52 / 255, blue: 79 / 255)
    static let navyDark = Color(red: 7 / 255, green: 13 / 255, blue: 24 / 255)
    static let navyPale = navy.opacity(0.11)
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let inset = Color(nsColor: .underPageBackgroundColor)
    static let ink = Color.primary
    static let muted = Color.secondary
    static let border = Color(nsColor: .separatorColor)
    static let cyan = Color(red: 14 / 255, green: 116 / 255, blue: 144 / 255)
    static let cyanPale = cyan.opacity(0.12)
    static let gold = Color(red: 161 / 255, green: 98 / 255, blue: 7 / 255)
    static let goldPale = gold.opacity(0.12)
    static let red = Color(red: 153 / 255, green: 27 / 255, blue: 27 / 255)
    static let redPale = red.opacity(0.12)
}

private struct VaultPrimaryActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                LinearGradient(
                    colors: [VaultPalette.navy, VaultPalette.navyDark],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .overlay(alignment: .top) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(.white.opacity(configuration.isPressed ? 0.12 : 0.25), lineWidth: 0.7)
            }
            .shadow(color: VaultPalette.navy.opacity(configuration.isPressed ? 0.10 : 0.22), radius: configuration.isPressed ? 2 : 5, y: configuration.isPressed ? 1 : 3)
            .opacity(configuration.isPressed ? 0.88 : 1)
    }
}

private struct VaultMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(VaultPalette.muted)
            Text(value)
                .font(.headline)
                .foregroundStyle(VaultPalette.ink)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VaultPalette.inset, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
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
                .font(.caption)
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
                .font(.caption.weight(.semibold))
                .foregroundStyle(VaultPalette.ink)
            Text(hint)
                .font(.caption)
                .foregroundStyle(VaultPalette.muted)
        }
    }
}

private struct VaultInput: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.body)
            .foregroundStyle(VaultPalette.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(VaultPalette.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(VaultPalette.border.opacity(0.9), lineWidth: 1))
    }
}

private extension View {
    func vaultInput() -> some View { modifier(VaultInput()) }
}

private struct VaultResultCard: View {
    let result: ClassificationResult

    private var actionColor: Color {
        switch result.strongestAction {
        case .allow: return VaultPalette.cyan
        case .dim: return VaultPalette.gold
        case .block: return VaultPalette.red
        }
    }

    private var actionPale: Color {
        switch result.strongestAction {
        case .allow: return VaultPalette.cyanPale
        case .dim: return VaultPalette.goldPale
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
#endif
