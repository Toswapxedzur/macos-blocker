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
    private var sharedHubServer: SharedHubServer?
    private var latestLedgerID: UUID?
    /// Credentials saved without Keychain are intentionally process-scoped.
    /// They support a one-session explicit provider run without writing a raw
    /// credential into the workspace catalog or to disk.
    private var sessionProviderCredentials: [String: ProviderCredentialRecord] = [:]
    /// Keep the AppKit object alive while its sheet is visible. WKScriptMessage
    /// callbacks do not otherwise guarantee an `NSAlert` remains retained.
    private var activeProviderCredentialAlert: NSAlert?
    private var testingProviderProfileIDs = Set<String>()

    init() {
        do {
            let package = try SeedPackageLoader.bundled()
            let appSupport = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let vaultDirectory = appSupport.appendingPathComponent("VaultClassifier", isDirectory: true)
            let coordinator = try LocalClassifierCoordinator(verifiedPackage: package, stateFile: LocalStateFile(url: vaultDirectory.appendingPathComponent("state.json")), defaultPolicies: [StarterPolicies.clashRoyale])
            self.coordinator = coordinator
            self.policies = coordinator.policies()
            self.localState = coordinator.snapshot()
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
            sharedHubClient.onStateChange = { [weak self] in
                self?.onWebStateChange?()
            }
            let sharedHubServer = SharedHubServer()
            self.sharedHubServer = sharedHubServer
            sharedHubServer.onRequest = { [weak self] request in
                self?.handleSharedHubRequest(request) ?? .failure("classifier-unavailable")
            }
            sharedHubServer.onStateChange = { [weak self] in
                self?.onWebStateChange?()
            }
            sharedHubClient.connectUsingStoredKey()
        } catch {
            issue = error.localizedDescription
        }
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
                return try sharedHubReply(NativeCollectionInfoResponse(
                    enabledPlatformIDs: coordinator.enabledCollectionPlatformIDs()
                ))
            case .collect:
                let request = try JSONDecoder().decode(NativeCollectionRequest.self, from: request.bodyData)
                let inserted = try coordinator.collectPlatformEntry(request.entry)
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
            return .failure(error.localizedDescription)
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

    func presentSharedHubPairingEntry(forHosting: Bool = false) {
        let alert = NSAlert()
        alert.messageText = forHosting ? "Open shared Vault server" : "Connect to Mac Vault"
        alert.informativeText = forHosting
            ? "Enter the same 64-character pairing key used by the Vault extension. Vault Classifier will host the shared local bridge at ws://127.0.0.1:8787."
            : "Enter the 64-character pairing key shown by Mac Vault. It is stored only in this Mac's Keychain and joins the existing local Vault bridge at ws://127.0.0.1:8787."
        alert.addButton(withTitle: forHosting ? "Open server" : "Connect")
        alert.addButton(withTitle: "Cancel")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "Mac Vault pairing key"
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try SharedHubPairingKeyStore.save(field.stringValue)
            if forHosting {
                hostSharedHub()
            } else {
                sharedHubClient?.connectUsingStoredKey()
            }
            issue = nil
        } catch {
            issue = error.localizedDescription
        }
    }

    func connectSharedHub() {
        if SharedHubPairingKeyStore.load() != nil {
            sharedHubServer?.stop()
            sharedHubClient?.connectUsingStoredKey()
        } else {
            presentSharedHubPairingEntry()
        }
    }

    func hostSharedHub() {
        guard let key = SharedHubPairingKeyStore.load() else {
            presentSharedHubPairingEntry(forHosting: true)
            return
        }
        sharedHubClient?.disconnect()
        sharedHubServer?.start(pairingKey: key)
        issue = nil
    }

    func stopSharedHubServer() {
        sharedHubServer?.stop()
        issue = nil
    }

    func disconnectSharedHub() {
        do {
            sharedHubServer?.stop()
            try SharedHubPairingKeyStore.remove()
            sharedHubClient?.disconnect()
            issue = nil
        } catch {
            issue = error.localizedDescription
        }
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
    }

    func createProviderProfile(typeRaw: String) {
        do {
            guard let type = APIKeyProviderType(rawValue: typeRaw),
                  type.isSelectableProfileType,
                  var catalog = localState?.workspaceCatalog else {
                throw WebBridgeInputError.invalidChoice("provider type")
            }
            catalog.providerProfiles.append(.init(type: type))
            try coordinator?.updateWorkspaceCatalog(catalog)
            refreshLocalState()
            issue = nil
        } catch { issue = error.localizedDescription }
    }

    func renameProviderProfile(profileID: String, name: String) {
        do {
            let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty,
                  var catalog = localState?.workspaceCatalog,
                  let index = catalog.providerProfiles.firstIndex(where: { $0.id == profileID }) else {
                throw WebBridgeInputError.invalidChoice("provider profile")
            }
            catalog.providerProfiles[index].name = cleaned
            catalog.providerProfiles[index].updatedAtMilliseconds = WorkspaceCatalog.now()
            try coordinator?.updateWorkspaceCatalog(catalog)
            refreshLocalState()
            issue = nil
        } catch { issue = error.localizedDescription }
    }

    func configureProviderProfile(
        profileID: String,
        name: String,
        modelIdentifier: String?,
        batchSize: String?,
        maximumTokens: String?,
        youtubeProviderID: String?,
        searchEnabled: Bool?,
        customEndpoint: String?,
        protocolConfiguration: [String: String],
        inputCostUSDPerMillion: String?,
        outputCostUSDPerMillion: String?,
        storesFullRequestRecords: Bool?
    ) {
        do {
            guard var catalog = localState?.workspaceCatalog,
                  let index = catalog.providerProfiles.firstIndex(where: { $0.id == profileID }) else {
                throw WebBridgeInputError.invalidChoice("provider profile")
            }
            var profile = catalog.providerProfiles[index]
            let cleanedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanedName.isEmpty else { throw WebBridgeInputError.invalidChoice("provider profile name") }
            profile.name = cleanedName
            let descriptor = ProviderProtocolRegistry.descriptor(for: profile.type)
            if descriptor.supportsLLMConfiguration {
                guard let modelIdentifier, let batchSize, let maximumTokens else {
                    throw WebBridgeInputError.missingValue("provider model settings")
                }
                profile.modelIdentifier = modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
                profile.batchSize = try providerPositiveInteger(batchSize, maximum: APIKeyProviderProfile.maximumBatchSize, label: "Provider batch size")
                profile.maximumTokens = try providerPositiveInteger(maximumTokens, maximum: APIKeyProviderProfile.maximumTokenLimit, label: "Provider maximum tokens")
                let normalizedYouTubeID = youtubeProviderID?.trimmingCharacters(in: .whitespacesAndNewlines)
                profile.youtubeProviderID = normalizedYouTubeID?.isEmpty == false ? normalizedYouTubeID : nil
                profile.searchEnabled = searchEnabled ?? false
                let normalizedEndpoint = customEndpoint?.trimmingCharacters(in: .whitespacesAndNewlines)
                profile.customEndpoint = normalizedEndpoint?.isEmpty == false ? normalizedEndpoint : nil
            } else {
                profile.modelIdentifier = ""
                profile.batchSize = 1
                profile.maximumTokens = 1_024
                profile.youtubeProviderID = nil
                profile.searchEnabled = false
                let normalizedEndpoint = customEndpoint?.trimmingCharacters(in: .whitespacesAndNewlines)
                profile.customEndpoint = normalizedEndpoint?.isEmpty == false ? normalizedEndpoint : nil
            }
            profile.protocolConfiguration = protocolConfiguration
            profile.inputCostUSDPerMillion = try providerCostRate(inputCostUSDPerMillion, label: "Provider input token cost")
            profile.outputCostUSDPerMillion = try providerCostRate(outputCostUSDPerMillion, label: "Provider output token cost")
            profile.storesFullRequestRecords = storesFullRequestRecords ?? false
            profile.updatedAtMilliseconds = WorkspaceCatalog.now()
            catalog.providerProfiles[index] = profile
            try coordinator?.updateWorkspaceCatalog(catalog)
            refreshLocalState()
            issue = nil
        } catch { issue = error.localizedDescription }
    }

    /// A provider test is always an explicit user action. It sends only the
    /// fixed harmless prompt declared by `ProviderTestProtocol`, never browser
    /// evidence or catalog data, and records no credential or headers.
    func testProviderProfile(profileID: String) {
        guard !testingProviderProfileIDs.contains(profileID) else { return }
        guard let profile = localState?.workspaceCatalog.providerProfiles.first(where: { $0.id == profileID }) else {
            issue = WebBridgeInputError.invalidChoice("provider profile").localizedDescription
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
                urlRequest.httpBody = request.body
                urlRequest.timeoutInterval = 30
                request.plan.headers.forEach { urlRequest.setValue($0.value, forHTTPHeaderField: $0.key) }
                try self.apply(credential: credential, to: &urlRequest, plan: request.plan)
                let (data, response) = try await URLSession.shared.data(for: urlRequest)
                let duration = max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
                guard let http = response as? HTTPURLResponse else { throw ProviderTestProtocolError.invalidResponse }
                guard (200..<300).contains(http.statusCode) else { throw ProviderTestHTTPError.status(http.statusCode) }
                let parsed = try ProviderTestProtocol.parseResponse(data, format: request.plan.bodyFormat, operation: request.operation)
                let cost = ProviderTestProtocol.estimatedCost(profile: profile, usage: parsed.usage)
                try self.appendProviderTestRecord(.init(
                    profileID: profile.id,
                    provider: profile.type.rawValue,
                    model: profile.modelIdentifier,
                    operation: request.operation.rawValue,
                    endpoint: ProviderTestProtocol.safeEndpoint(request.plan.url),
                    method: request.plan.method,
                    statusCode: http.statusCode,
                    durationMilliseconds: duration,
                    inputTokens: parsed.usage.inputTokens,
                    outputTokens: parsed.usage.outputTokens,
                    estimatedCostUSD: cost,
                    outcome: "succeeded",
                    requestContent: profile.storesFullRequestRecords ? request.prompt : nil,
                    responseContent: profile.storesFullRequestRecords ? parsed.content : nil
                ))
                self.issue = nil
            } catch {
                let duration = max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
                if let prepared {
                    try? self.appendProviderTestRecord(.init(
                        profileID: profile.id,
                        provider: profile.type.rawValue,
                        model: profile.modelIdentifier,
                        operation: prepared.operation.rawValue,
                        endpoint: ProviderTestProtocol.safeEndpoint(prepared.plan.url),
                        method: prepared.plan.method,
                        statusCode: nil,
                        durationMilliseconds: duration,
                        inputTokens: nil,
                        outputTokens: nil,
                        estimatedCostUSD: nil,
                        outcome: "failed"
                    ))
                }
                self.issue = error.localizedDescription
            }
            self.testingProviderProfileIDs.remove(profileID)
            self.onWebStateChange?()
        }
    }

    private func providerCredential(for profileID: String) throws -> ProviderCredentialRecord {
        if let credential = sessionProviderCredentials[profileID] { return credential }
        if let credential = ProviderCredentialStore.loadCredentialRecord(for: profileID) { return credential }
        throw ProviderTestProtocolError.missingCredential
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
        case .bearerToken:
            request.setValue("Bearer \(try value(.bearerToken))", forHTTPHeaderField: plan.authenticationHeader ?? "Authorization")
        case .apiKeyHeader:
            request.setValue(try value(.apiKey), forHTTPHeaderField: plan.authenticationHeader ?? "X-API-Key")
        case .apiKeyQuery:
            guard var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false) else { throw ProviderTestProtocolError.invalidResponse }
            components.queryItems = (components.queryItems ?? []) + [.init(name: plan.authenticationHeader ?? "key", value: try value(.apiKey))]
            request.url = components.url
        case .bearerTokenAndClientID, .awsSignatureV4:
            throw ProviderTestProtocolError.unsupportedProvider
        }
    }

    private func appendProviderTestRecord(_ record: ProviderRequestRecord) throws {
        guard var catalog = localState?.workspaceCatalog else { return }
        catalog.providerRequestRecords.insert(record, at: 0)
        catalog.providerRequestRecords = Array(catalog.providerRequestRecords.prefix(100))
        if record.outcome == "succeeded" {
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

    func presentProviderCredentialEntry(profileID: String) {
        do {
            guard activeProviderCredentialAlert == nil else { return }
            guard let profile = localState?.workspaceCatalog.providerProfiles.first(where: { $0.id == profileID }) else {
                throw WebBridgeInputError.invalidChoice("provider profile")
            }
            let descriptor = ProviderProtocolRegistry.descriptor(for: profile.type)
            guard !descriptor.credentialFields.isEmpty else {
                refreshLocalState()
                issue = nil
                return
            }
            let alert = NSAlert()
            alert.messageText = "Store provider credential"
            alert.informativeText = "This value is entered directly into this Mac’s Keychain. It is not sent through the web workspace."
            alert.addButton(withTitle: "Store in Keychain")
            alert.addButton(withTitle: "Cancel")
            let fields = descriptor.credentialFields.map { field in
                (field, NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24)))
            }
            let stack = NSStackView()
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 8
            for (field, control) in fields {
                let label = NSTextField(labelWithString: nativeCredentialLabel(field))
                stack.addArrangedSubview(label)
                stack.addArrangedSubview(control)
            }
            alert.accessoryView = stack
            alert.window.initialFirstResponder = fields.first?.1
            guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) else {
                throw WebBridgeInputError.invalidChoice("application window")
            }
            NSApp.activate(ignoringOtherApps: true)
            activeProviderCredentialAlert = alert
            alert.beginSheetModal(for: window) { [weak self] response in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    defer {
                        self.activeProviderCredentialAlert = nil
                        self.onWebStateChange?()
                    }
                    guard response == .alertFirstButtonReturn else { return }
                    do {
                        let record = ProviderCredentialRecord(values: Dictionary(uniqueKeysWithValues: fields.map { ($0.0, $0.1.stringValue) }))
                        try ProviderCredentialStore.saveCredentialRecord(record, for: profileID, descriptor: descriptor)
                        self.refreshLocalState()
                        self.issue = nil
                    } catch {
                        self.issue = error.localizedDescription
                    }
                }
            }
            DispatchQueue.main.async { [weak self, weak window] in
                guard self?.activeProviderCredentialAlert === alert else { return }
                window?.makeFirstResponder(fields.first?.1)
            }
        } catch { issue = error.localizedDescription }
    }

    /// The LLM-assist panel deliberately accepts a masked direct entry field.
    /// It forwards a credential only for this explicit save action, never in a
    /// snapshot. The user may opt into persistent Keychain storage; otherwise
    /// the validated value survives only for this process.
    func saveProviderCredential(profileID: String, credentialValues: [String: String], storeInKeychain: Bool) {
        do {
            guard let profile = localState?.workspaceCatalog.providerProfiles.first(where: { $0.id == profileID }) else {
                throw WebBridgeInputError.invalidChoice("provider profile")
            }
            let descriptor = ProviderProtocolRegistry.descriptor(for: profile.type)
            var values: [ProviderCredentialField: String] = [:]
            for (rawField, value) in credentialValues {
                guard let field = ProviderCredentialField(rawValue: rawField), values[field] == nil else {
                    throw WebBridgeInputError.invalidChoice("provider credential")
                }
                values[field] = value
            }
            let record = ProviderCredentialRecord(values: values)
            try record.validate(for: descriptor)
            if storeInKeychain {
                try ProviderCredentialStore.saveCredentialRecord(record, for: profileID, descriptor: descriptor)
                sessionProviderCredentials.removeValue(forKey: profileID)
            } else {
                // An unchecked Keychain option means no credential is retained
                // after the app exits. Remove any prior persistent replacement.
                try ProviderCredentialStore.removeCredential(for: profileID)
                sessionProviderCredentials[profileID] = record
            }
            refreshLocalState()
            issue = nil
        } catch { issue = error.localizedDescription }
    }

    func removeProviderCredential(profileID: String) {
        do {
            guard localState?.workspaceCatalog.providerProfiles.contains(where: { $0.id == profileID }) == true else {
                throw WebBridgeInputError.invalidChoice("provider profile")
            }
            try ProviderCredentialStore.removeCredential(for: profileID)
            sessionProviderCredentials.removeValue(forKey: profileID)
            refreshLocalState()
            issue = nil
        } catch { issue = error.localizedDescription }
    }

    func deleteProviderProfile(profileID: String) {
        do {
            guard var catalog = localState?.workspaceCatalog,
                  catalog.providerProfiles.contains(where: { $0.id == profileID }) else {
                throw WebBridgeInputError.invalidChoice("provider profile")
            }
            catalog.providerProfiles.removeAll(where: { $0.id == profileID })
            catalog.providerRequestRecords.removeAll(where: { $0.profileID == profileID })
            for index in catalog.providerProfiles.indices where catalog.providerProfiles[index].youtubeProviderID == profileID {
                catalog.providerProfiles[index].youtubeProviderID = nil
                catalog.providerProfiles[index].updatedAtMilliseconds = WorkspaceCatalog.now()
            }
            try coordinator?.updateWorkspaceCatalog(catalog)
            try ProviderCredentialStore.removeCredential(for: profileID)
            sessionProviderCredentials.removeValue(forKey: profileID)
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
            message: "This removes the local setup and its Keychain credential. It cannot be undone.",
            confirmTitle: "Delete profile"
        ) { [weak self] in
            self?.deleteProviderProfile(profileID: profileID)
        }
    }

    private func nativeCredentialLabel(_ field: ProviderCredentialField) -> String {
        switch field {
        case .apiKey: return "API key"
        case .bearerToken: return "Bearer token"
        case .clientSecret: return "Client secret"
        case .accessKeyID: return "AWS access key ID"
        case .secretAccessKey: return "AWS secret access key"
        case .sessionToken: return "AWS session token"
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
            guard let tree = catalog.trees.first, let dataset = catalog.datasets.first else {
                throw WebBridgeInputError.invalidChoice("workspace assets")
            }
            catalog.bindings.append(.init(
                id: definition.id,
                name: definition.name,
                browser: definition.browser,
                treeID: tree.id,
                datasetID: dataset.id,
                collectionEnabled: false
            ))
            try coordinator?.updateWorkspaceCatalog(catalog)
            refreshLocalState()
            issue = nil
        } catch { issue = error.localizedDescription }
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

    func createLocalModel(name: String) {
        do {
            let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { throw WebBridgeInputError.invalidChoice("local model name") }
            guard var catalog = localState?.workspaceCatalog,
                  let binding = catalog.bindings.first,
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
                trainingPlatformID: binding.id
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

    func configureLocalModel(modelID: String, treeID: String, platformID: String, baseEmbeddingID: String?) {
        do {
            guard var catalog = localState?.workspaceCatalog else { return }
            try configureLocalModel(
                in: &catalog,
                modelID: modelID,
                treeID: treeID,
                platformID: platformID,
                baseEmbeddingID: baseEmbeddingID
            )
            try coordinator?.updateWorkspaceCatalog(catalog)
            refreshLocalState()
            issue = nil
        } catch { issue = error.localizedDescription }
    }

    func trainLocalModel(modelID: String, treeID: String, platformID: String, baseEmbeddingID: String?) {
        do {
            guard var catalog = localState?.workspaceCatalog else { return }
            try configureLocalModel(
                in: &catalog,
                modelID: modelID,
                treeID: treeID,
                platformID: platformID,
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
        platformID: String,
        baseEmbeddingID: String?
    ) throws {
        guard let modelIndex = catalog.models.firstIndex(where: { $0.id == modelID }),
              let tree = catalog.trees.first(where: { $0.id == treeID }),
              let binding = catalog.bindings.first(where: { $0.id == platformID }),
              let dataset = catalog.datasets.first(where: { $0.id == binding.datasetID }) else {
            throw WebBridgeInputError.invalidChoice("local model setup")
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
            prior.trainingPlatformID != binding.id ||
            prior.baseEmbeddingID != baseEmbedding
        catalog.models[modelIndex].treeID = tree.id
        catalog.models[modelIndex].treeRevision = tree.revision
        catalog.models[modelIndex].datasetID = dataset.id
        catalog.models[modelIndex].datasetRevision = dataset.revision
        catalog.models[modelIndex].trainingPlatformID = binding.id
        catalog.models[modelIndex].baseEmbeddingID = baseEmbedding
        if changed {
            catalog.models[modelIndex].isReady = false
            catalog.models[modelIndex].embeddedNeuralModel = nil
            catalog.models[modelIndex].embeddedTrainingReport = nil
            catalog.models[modelIndex].trainedAtMilliseconds = nil
            for bindingIndex in catalog.bindings.indices where catalog.bindings[bindingIndex].activeModelID == modelID {
                catalog.bindings[bindingIndex].activeModelID = nil
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
            if refreshState { refreshLocalState() }
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
        }
    }

    func recordManualClassification(title: String, tags: String, platformID: String) {
        do {
            guard var catalog = localState?.workspaceCatalog,
                  let binding = catalog.bindings.first(where: { $0.id == platformID }),
                  let tree = catalog.trees.first(where: { $0.id == binding.treeID }),
                  let datasetIndex = catalog.datasets.firstIndex(where: { $0.id == binding.datasetID }) else { return }
            let labels = splitTagList(tags)
            guard !labels.isEmpty, labels.allSatisfy({ tagID in tree.nodes.contains(where: { $0.id == tagID && !$0.isRetired }) }) else {
                throw WebBridgeInputError.invalidChoice("tag IDs")
            }
            catalog.datasets[datasetIndex].records.append(.init(title: title, tagIDs: labels, origin: .manual, review: .approved, platformID: binding.id, treeRevision: tree.revision))
            catalog.datasets[datasetIndex].revision += 1
            try coordinator?.updateWorkspaceCatalog(catalog)
            refreshLocalState()
        } catch { issue = error.localizedDescription }
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
            guard var catalog = localState?.workspaceCatalog,
                  let bindingIndex = catalog.bindings.firstIndex(where: { $0.id == "youtube" }),
                  let tree = catalog.trees.first(where: { $0.id == catalog.bindings[bindingIndex].treeID }),
                  let dataset = catalog.datasets.first(where: { $0.id == catalog.bindings[bindingIndex].datasetID }) else {
                refreshLocalState()
                return
            }
            let modelID = catalog.bindings[bindingIndex].activeModelID ?? catalog.models.first(where: { $0.treeID == tree.id && $0.datasetID == dataset.id })?.id ?? UUID().uuidString
            if let modelIndex = catalog.models.firstIndex(where: { $0.id == modelID }) {
                catalog.models[modelIndex].treeRevision = tree.revision
                catalog.models[modelIndex].datasetRevision = dataset.revision
                catalog.models[modelIndex].version += 1
                catalog.models[modelIndex].isReady = true
            } else {
                catalog.models.append(.init(id: modelID, name: "Local neural model", treeID: tree.id, treeRevision: tree.revision, datasetID: dataset.id, datasetRevision: dataset.revision, isReady: true))
            }
            catalog.bindings[bindingIndex].activeModelID = modelID
            try coordinator.updateWorkspaceCatalog(catalog)
            refreshLocalState()
            trainingNotice = "Rebuilt this Mac's correction layer from \(run.exampleCount) explicit label\(run.exampleCount == 1 ? "" : "s") in \(run.epochs) pass\(run.epochs == 1 ? "" : "es")."
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
            platform: "manual",
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
        let inspect: [String: Any] = [
            "title": title,
            "sourceID": sourceID,
            "surface": surface.rawValue,
            "result": result.map(webResult) ?? NSNull(),
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
        let catalog = state?.workspaceCatalog ?? .starter()
        let assets: [String: Any] = [
            "trees": catalog.trees.map { tree in
                ["id": tree.id, "name": tree.name, "revision": tree.revision, "nodes": tree.nodes.enumerated().map { index, node -> [String: Any] in
                    let position = node.resolvedCanvasPosition(index: index)
                    return ["id": node.id, "name": node.name, "parentID": node.parentID ?? NSNull(), "retired": node.isRetired, "positionX": position.x, "positionY": position.y]
                }] as [String: Any]
            },
            "datasets": catalog.datasets.map { dataset in
                [
                    "id": dataset.id,
                    "name": dataset.name,
                    "revision": dataset.revision,
                    "records": dataset.records.map { record -> [String: Any] in
                        ["id": record.id, "title": record.title, "tags": record.tagIDs, "origin": record.origin.rawValue, "review": record.review.rawValue, "platformID": record.platformID]
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
                            "firstObservedAtMilliseconds": entry.firstObservedAtMilliseconds,
                            "lastObservedAtMilliseconds": entry.lastObservedAtMilliseconds,
                            "observationCount": entry.observationCount,
                        ] as [String: Any]
                    },
                ] as [String: Any]
            },
            "models": catalog.models.map { model in
                [
                    "id": model.id,
                    "name": model.name,
                    "treeID": model.treeID,
                    "treeRevision": model.treeRevision,
                    "datasetID": model.datasetID,
                    "datasetRevision": model.datasetRevision,
                    "platformID": model.trainingPlatformID ?? NSNull(),
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
            },
            "baseEmbeddings": LocalBaseEmbedding.allCases.map(\.rawValue),
            "providerProfiles": catalog.providerProfiles.map { profile in
                [
                    "id": profile.id,
                    "name": profile.name,
                    "type": profile.type.rawValue,
                    "modelIdentifier": profile.modelIdentifier,
                    "batchSize": profile.batchSize,
                    "maximumTokens": profile.maximumTokens,
                    "youtubeProviderID": profile.youtubeProviderID ?? NSNull(),
                    "searchEnabled": profile.searchEnabled,
                    "customEndpoint": profile.customEndpoint ?? NSNull(),
                    "protocolConfiguration": profile.protocolConfiguration,
                    "inputCostUSDPerMillion": profile.inputCostUSDPerMillion ?? NSNull(),
                    "outputCostUSDPerMillion": profile.outputCostUSDPerMillion ?? NSNull(),
                    "storesFullRequestRecords": profile.storesFullRequestRecords,
                    "hasStoredCredential": ProviderCredentialStore.hasCredential(for: profile.id),
                    "hasSessionCredential": sessionProviderCredentials[profile.id] != nil,
                    "testing": testingProviderProfileIDs.contains(profile.id),
                ] as [String: Any]
            },
            "providerRequestRecords": catalog.providerRequestRecords.map { record in
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
                    "estimatedCostUSD": record.estimatedCostUSD ?? NSNull(),
                    "outcome": record.outcome,
                    "requestContent": record.requestContent ?? NSNull(),
                    "responseContent": record.responseContent ?? NSNull(),
                    "createdAtMilliseconds": record.createdAtMilliseconds,
                ] as [String: Any]
            },
            "providerProtocols": Dictionary(uniqueKeysWithValues: APIKeyProviderType.allCases
                .map { type -> (String, [String: Any]) in
                    let descriptor = ProviderProtocolRegistry.descriptor(for: type)
                    return (type.rawValue, [
                        "identifier": descriptor.identifier,
                        "revision": descriptor.revision,
                        "family": descriptor.family.rawValue,
                        "supportsLLMConfiguration": descriptor.supportsLLMConfiguration,
                        "supportsYouTubeTool": descriptor.requestFormats.contains(where: { $0.operation == .generateText }),
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
                }),
            "bindings": catalog.bindings.map { binding in
                ["id": binding.id, "name": binding.name, "browser": binding.browser, "treeID": binding.treeID, "datasetID": binding.datasetID, "activeModelID": binding.activeModelID ?? NSNull(), "policyID": binding.policyID ?? NSNull(), "collectionEnabled": binding.collectionEnabled] as [String: Any]
            },
            "collectionPlatforms": CollectionPlatformRegistry.definitions.map { definition in
                ["id": definition.id, "name": definition.name, "browser": definition.browser, "collectorAvailable": definition.collectorAvailable] as [String: Any]
            },
            "tokenUsage": budgetRecords.suffix(12).reversed().map { record -> [String: Any] in
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
            },
        ]
        let sharedHub: [String: Any] = [
            "address": SharedBrowserBridgeProtocol.address,
            "state": sharedHubServer?.isHosting == true
                ? (sharedHubServer?.state.rawValue ?? "off")
                : (sharedHubClient?.state.rawValue ?? "off"),
            "error": sharedHubServer?.isHosting == true
                ? (sharedHubServer?.error ?? "")
                : (sharedHubClient?.error ?? ""),
            "hasPairingKey": sharedHubClient?.hasStoredPairingKey ?? false,
            "isHosting": sharedHubServer?.isHosting ?? false,
            "serverState": sharedHubServer?.state.rawValue ?? "off",
            "serverError": sharedHubServer?.error ?? "",
        ]
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
            "bridge": sharedHub,
        ]
    }

    /// The web renderer is a bundled local asset, but its messages are still
    /// treated as untrusted UI input. Keep the surface small and bounded so it
    /// cannot become another native IPC or provider-control path.
    func performWebAction(_ action: String, data: [String: Any]) {
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
            case "hostSharedHub":
                hostSharedHub()
            case "stopSharedHubServer":
                stopSharedHubServer()
            case "disconnectSharedHub":
                disconnectSharedHub()
            case "createTree":
                createTree(name: try webString(data, key: "name", limit: 128))
            case "addCollectionPlatform":
                addCollectionPlatform(platformID: try webString(data, key: "platformID", limit: 64))
            case "setCollectionEnabled":
                setCollectionEnabled(
                    platformID: try webString(data, key: "platformID", limit: 64),
                    enabled: try webBool(data, key: "enabled")
                )
            case "createLocalModel":
                createLocalModel(name: try webString(data, key: "name", limit: 128))
            case "createProviderProfile":
                createProviderProfile(typeRaw: try webString(data, key: "type", limit: 32))
            case "renameProviderProfile":
                renameProviderProfile(
                    profileID: try webString(data, key: "profileID", limit: 128),
                    name: try webString(data, key: "name", limit: APIKeyProviderProfile.maximumNameLength)
                )
            case "configureProviderProfile":
                configureProviderProfile(
                    profileID: try webString(data, key: "profileID", limit: 128),
                    name: try webString(data, key: "name", limit: APIKeyProviderProfile.maximumNameLength),
                    modelIdentifier: try webOptionalString(data, key: "modelIdentifier", limit: APIKeyProviderProfile.maximumModelIdentifierLength),
                    batchSize: try webOptionalString(data, key: "batchSize", limit: 16),
                    maximumTokens: try webOptionalString(data, key: "maximumTokens", limit: 16),
                    youtubeProviderID: try webOptionalString(data, key: "youtubeProviderID", limit: 128),
                    searchEnabled: data["searchEnabled"] as? Bool,
                    customEndpoint: try webOptionalString(data, key: "customEndpoint", limit: APIKeyProviderProfile.maximumEndpointLength),
                    protocolConfiguration: try webProviderConfiguration(data),
                    inputCostUSDPerMillion: try webOptionalString(data, key: "inputCostUSDPerMillion", limit: 32),
                    outputCostUSDPerMillion: try webOptionalString(data, key: "outputCostUSDPerMillion", limit: 32),
                    storesFullRequestRecords: data["storesFullRequestRecords"] as? Bool
                )
            case "presentProviderCredentialEntry":
                presentProviderCredentialEntry(profileID: try webString(data, key: "profileID", limit: 128))
            case "saveProviderCredential":
                saveProviderCredential(
                    profileID: try webString(data, key: "profileID", limit: 128),
                    credentialValues: try webProviderCredentials(data),
                    storeInKeychain: data["storeInKeychain"] as? Bool ?? false
                )
            case "testProviderProfile":
                testProviderProfile(profileID: try webString(data, key: "profileID", limit: 128))
            case "removeProviderCredential":
                removeProviderCredential(profileID: try webString(data, key: "profileID", limit: 128))
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
                    platformID: try webString(data, key: "platformID", limit: 256),
                    baseEmbeddingID: try webOptionalString(data, key: "baseEmbeddingID", limit: 128)
                )
            case "trainLocalModel":
                trainLocalModel(
                    modelID: try webString(data, key: "modelID", limit: 256),
                    treeID: try webString(data, key: "treeID", limit: 256),
                    platformID: try webString(data, key: "platformID", limit: 256),
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
            case "recordManualClassification":
                recordManualClassification(
                    title: try webString(data, key: "title", limit: 512),
                    tags: try webString(data, key: "tags", limit: 1_024),
                    platformID: try webString(data, key: "platformID", limit: 64)
                )
            case "classify":
                title = try webString(data, key: "title", limit: 4_096)
                sourceID = try webString(data, key: "sourceID", limit: 1_024)
                let surfaceValue = try webString(data, key: "surface", limit: 16)
                guard let value = EntrySurface(rawValue: surfaceValue) else { throw WebBridgeInputError.invalidChoice("surface") }
                surface = value
                classify()
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

    private func webProviderConfiguration(_ data: [String: Any]) throws -> [String: String] {
        guard let raw = data["protocolConfiguration"] as? [String: Any] else { return [:] }
        guard raw.count <= ProviderConfigurationField.allCases.count else {
            throw WebBridgeInputError.exceedsLimit("protocol configuration", ProviderConfigurationField.allCases.count)
        }
        return try Dictionary(uniqueKeysWithValues: raw.map { key, value in
            guard key.count <= 64, let string = value as? String, string.count <= 512 else {
                throw WebBridgeInputError.invalidChoice("protocol configuration")
            }
            return (key, string)
        })
    }

    private func webProviderCredentials(_ data: [String: Any]) throws -> [String: String] {
        guard let raw = data["credentials"] as? [String: Any] else {
            throw WebBridgeInputError.missingValue("provider credential")
        }
        guard raw.count <= ProviderCredentialField.allCases.count else {
            throw WebBridgeInputError.exceedsLimit("provider credential", ProviderCredentialField.allCases.count)
        }
        return try Dictionary(uniqueKeysWithValues: raw.map { key, value in
            guard ProviderCredentialField(rawValue: key) != nil,
                  let credential = value as? String,
                  credential.count <= ProviderCredentialStore.maximumCredentialCharacters else {
                throw WebBridgeInputError.invalidChoice("provider credential")
            }
            return (key, credential)
        })
    }

    private func providerCostRate(_ raw: String?, label: String) throws -> Double? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        guard let value = Double(trimmed), value.isFinite, (0...1_000_000).contains(value) else {
            throw WebBridgeInputError.invalidChoice(label)
        }
        return value
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
