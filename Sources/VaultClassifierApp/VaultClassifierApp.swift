import AppKit
import Combine
import VaultClassifierCore
import VaultClassifierBridge
import VaultClassifierLLM

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

    func applicationWillTerminate(_ notification: Notification) {
        // State writes are coalesced onto a background queue; flush so a clean
        // quit never drops the newest write.
        LocalStateFile.flushAllPendingWrites()
    }
}

@MainActor
final class VaultClassifierViewModel: ObservableObject {
    struct ClassifierTypeLocalModelWebInput: Equatable {
        var typeID: String
        var overrideEnabled: Bool
        var modelFileName: String?
        var overrides: LocalModelOverrides?
    }
    struct ClassifierTypeResearchWebInput: Equatable {
        var typeID: String
        var overrideEnabled: Bool
        var settings: ResearchSettings?
    }
    enum Workspace: String, CaseIterable, Identifiable, Hashable {
        case tagTree
        case llmAssist
        case browserBridge
        case classificationData
        case knowledge

        var id: String { rawValue }
    }

    @Published var workspace: Workspace = .tagTree
    @Published var issue: String?
    @Published var localState: LocalClassifierState?
    @Published var packageUpdateMode: PackageUpdateMode = .automatic
    // Local-model settings, mirrored from ClassifierSettings.localLLM.
    @Published var llmSettings = LocalLLMSettings()
    @Published private(set) var llmEngineStatus = "loading"
    @Published var backupOwnerCode = ""
    @Published var backupDirectory = ""
    @Published var backupEnabled = false
    @Published private(set) var hasBackupOwnerCode = false
    @Published private(set) var backupUnlocked = false
    @Published private(set) var backupNotice: String?
    /// Web actions normally receive a synchronous state refresh. Native sheets
    /// complete later, so they explicitly use this bounded local callback.
    var onWebStateChange: (() -> Void)?

    var coordinator: LocalClassifierCoordinator?
    var groundedResearchQueue: GroundedResearchQueue?
    @Published private(set) var researchQueueStatus = GroundedResearchQueueStatus()
    var sharedHubClient: SharedHubClient?
    var collectionDiagnostics: CollectionDiagnosticsStore?
    var providerModelCatalogStore: ProviderModelCatalogStore?
    private(set) var sourceIconCache: SourceIconCache?
    var testingProviderProfileIDs = Set<String>()
    var successfulProviderTestProfileIDs = Set<String>()
    /// Model identifiers and model-list capability signals come from explicit
    /// provider Probes. They are retained without credentials or request data.
    var providerModelCatalogs = [String: [ProviderModelCatalogEntry]]()
    var providerModelCatalogErrors = [String: String]()
    var loadingProviderModelProfileIDs = Set<String>()
    let modelDownloadManager: ModelDownloadManager
    var modelDownloadFractions: [String: Double] = [:]

    init(modelDownloadManager: ModelDownloadManager = ModelDownloadManager()) {
        self.modelDownloadManager = modelDownloadManager
        do {
            let vaultDirectory = try VaultDevelopmentEnvironmentMigration.prepareClassifierDirectory()
            RetiredCredentialCleanup.removePersonalAuditCredential()
            let package = try SeedPackageLoader.bundled()
            let collectionDiagnostics = CollectionDiagnosticsStore(fileURL: vaultDirectory.appendingPathComponent("collection-diagnostics.json"))
            self.collectionDiagnostics = collectionDiagnostics
            self.sourceIconCache = SourceIconCache(
                directory: vaultDirectory.appendingPathComponent("source-icons", isDirectory: true),
                retiredDirectory: vaultDirectory.appendingPathComponent("creator-avatars", isDirectory: true)
            )
            collectionDiagnostics.record(event: "app-started", outcome: "ready")
            let coordinator = try LocalClassifierCoordinator(verifiedPackage: package, stateFile: LocalStateFile(url: vaultDirectory.appendingPathComponent("state.json")))
            self.coordinator = coordinator
            self.localState = coordinator.snapshot()
            try migrateRetiredProviderCredentialsToWorkspace()
            purgeExpiredTrashOnLaunch()
            let providerModelCatalogStore = ProviderModelCatalogStore(fileURL: vaultDirectory.appendingPathComponent("provider-model-catalogs.json"))
            self.providerModelCatalogStore = providerModelCatalogStore
            self.providerModelCatalogs = providerModelCatalogStore.load(allowedProfileIDs: llmProviderProfileIDs())
            loadResourceSettings(from: coordinator.snapshot().settings)
            loadBackupConfiguration(from: coordinator.snapshot().backupConfiguration)
            self.hasBackupOwnerCode = LocalBackupOwnerCodeStore.hasOwnerCode
            let sharedHubClient = SharedHubClient()
            self.sharedHubClient = sharedHubClient
            VaultDevLog.shared.log("app", "launch", ["hub": SharedBrowserBridgeProtocol.address])
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
                // Hub connection state is not part of the web snapshot, so a
                // state change would push a byte-identical payload and force a
                // wasteful full re-render. Record the diagnostic only.
            }
            sharedHubClient.connect()
            installGroundedResearch(coordinator: coordinator)
            installLocalLLMEngine(coordinator: coordinator)
        } catch {
            issue = error.localizedDescription
        }
    }

    /// Hermetic construction for tests (CLASSIFIER-INDEPENDENCE §7, Phase 5):
    /// every file lives under `vaultDirectory`, and nothing touches the real
    /// app-support directory, the Keychain, the local hub, the GGUF engine, the
    /// network or the startup migrations. The coordinator runs on the stub LLM,
    /// so `webSnapshot()` / `performWebAction` can be characterised exactly.
    init(headlessVaultDirectory vaultDirectory: URL, modelDownloadManager: ModelDownloadManager = ModelDownloadManager()) throws {
        self.modelDownloadManager = modelDownloadManager
        let package = try SeedPackageLoader.bundled()
        let collectionDiagnostics = CollectionDiagnosticsStore(fileURL: vaultDirectory.appendingPathComponent("collection-diagnostics.json"))
        self.collectionDiagnostics = collectionDiagnostics
        self.sourceIconCache = SourceIconCache(
            directory: vaultDirectory.appendingPathComponent("source-icons", isDirectory: true),
            retiredDirectory: vaultDirectory.appendingPathComponent("creator-avatars", isDirectory: true)
        )
        let coordinator = try LocalClassifierCoordinator(verifiedPackage: package, stateFile: LocalStateFile(url: vaultDirectory.appendingPathComponent("state.json")))
        self.coordinator = coordinator
        self.localState = coordinator.snapshot()
        let providerModelCatalogStore = ProviderModelCatalogStore(fileURL: vaultDirectory.appendingPathComponent("provider-model-catalogs.json"))
        self.providerModelCatalogStore = providerModelCatalogStore
        self.providerModelCatalogs = providerModelCatalogStore.load(allowedProfileIDs: llmProviderProfileIDs())
        loadResourceSettings(from: coordinator.snapshot().settings)
        loadBackupConfiguration(from: coordinator.snapshot().backupConfiguration)
        coordinator.setOnDeviceLLM(StubOnDeviceLLM())
        llmEngineStatus = "disabled"
    }

    /// Loads the in-process llama.cpp engine (final Phase-0 contract) with the
    /// user's settings and installs it as the coordinator's on-device LLM.
    /// Loading is a ~1–2 s mmap, done off the main actor; until it completes
    /// (or if the engine is disabled / no model file is present) classification
    /// stays on the stub.
    private func installLocalLLMEngine(coordinator: LocalClassifierCoordinator) {
        let configuration = llmSettings
        coordinator.setOnDeviceLLMEngineResolver(nil)
        guard configuration.engineEnabled else {
            coordinator.setOnDeviceLLM(StubOnDeviceLLM())
            llmEngineStatus = "disabled"
            VaultDevLog.shared.log("llm", "engine-disabled", [:])
            return
        }
        guard let modelPath = VaultLocalLLMEngine.defaultModelPath(preferredFileName: configuration.modelFileName) else {
            coordinator.setOnDeviceLLM(StubOnDeviceLLM())
            llmEngineStatus = "no-model"
            VaultDevLog.shared.log("llm", "engine-skipped", ["reason": "no-model-file"])
            return
        }
        llmEngineStatus = "loading"
        let registry = LocalLLMEngineRegistry()
        Task.detached(priority: .userInitiated) {
            do {
                let engine = try await registry.engine(forModel: nil, configuration: configuration)
                coordinator.setOnDeviceLLM(engine)
                coordinator.setOnDeviceLLMEngineResolver(registry)
                VaultDevLog.shared.log("llm", "engine-loaded", ["model": (modelPath as NSString).lastPathComponent])
                await MainActor.run { [weak self] in
                    self?.llmEngineStatus = "loaded"
                    coordinator.startResearchBackfill()
                    self?.onWebStateChange?()
                }
            } catch {
                coordinator.setOnDeviceLLMEngineResolver(nil)
                VaultDevLog.shared.log("llm", "engine-load-failed", ["error": String(describing: error)])
                await MainActor.run { [weak self] in
                    self?.llmEngineStatus = "failed"
                    self?.onWebStateChange?()
                }
            }
        }
    }

    /// Installs the opt-in research lane once. Its closures read a fresh
    /// coordinator snapshot for every subject, so provider edits, budgets, and
    /// disabling the feature take effect without rebuilding the queue.
    private func installGroundedResearch(coordinator: LocalClassifierCoordinator) {
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

    /// A web field that is optional: blank, absent, or unparseable → nil.
    nonisolated static func optionalWebInteger(_ value: Any?) -> Int? {
        if let n = value as? Int { return n }
        guard let raw = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        return Int(raw)
    }

    /// Copies a valid retired Keychain credential into the provider's ordinary
    /// workspace field, then deletes the old Keychain item. Existing plain
    /// workspace values take precedence.
    /// Opportunistic trash purge: on launch, drop entries whose 24h lifetime
    /// has elapsed. There is no background timer.
    private func purgeExpiredTrashOnLaunch() {
        guard var catalog = localState?.workspaceCatalog, !catalog.trash.isEmpty else { return }
        guard catalog.purgeExpiredTrash() > 0 else { return }
        try? coordinator?.updateWorkspaceCatalog(catalog)
        localState = coordinator?.snapshot()
    }

    private func migrateRetiredProviderCredentialsToWorkspace() throws {
        guard var catalog = localState?.workspaceCatalog else {
            LegacyProviderCredentialMigration.purgeRemaining()
            return
        }
        defer { LegacyProviderCredentialMigration.purgeRemaining() }
        var changed = false
        for index in catalog.providerProfiles.indices {
            let profileID = catalog.providerProfiles[index].id
            let descriptor = ProviderProtocolRegistry.descriptor(for: catalog.providerProfiles[index].type)
            let retiredKeychainCredential = LegacyProviderCredentialMigration.consume(profileID: profileID)
            if catalog.providerProfiles[index].credential == nil,
               let credential = retiredKeychainCredential,
               let field = descriptor.credentialFields.first,
               (try? credential.validate(for: descriptor)) != nil,
               let value = credential.values[field] {
                catalog.providerProfiles[index].credential = value
                catalog.providerProfiles[index].updatedAtMilliseconds = WorkspaceCatalog.now()
                changed = true
            }
        }
        guard changed else { return }
        try coordinator?.updateWorkspaceCatalog(catalog)
        localState = coordinator?.snapshot()
    }

    // Dev-only instrumentation, routed into the unified VaultDevLog file.
    static let perfEnabled = VaultDevLog.shared.isEnabled
    /// Classifications currently running, keyed by platform + entryID. Repeated
    /// pending requests for a video already on the serial LLM queue must not
    /// enqueue duplicate work — without this, every provisional re-request
    /// multiplied the queue and starved the tail of the viewport.
    var inFlightVideoClassifications = Set<String>()

    /// Queue background classification for videos with no cached decision,
    /// skipping any already in flight. Each completed video is broadcast through
    /// the hub so provisional pills resolve the moment the result exists,
    /// instead of waiting for the extension's next poll.
    /// Videos handed to the engine together — its parallel-sequence capacity.
    static let classificationChunkSize = 16

    /// Dev-only pipeline test mode (`ADAMANCIA_VAULT_TAG_TEST=creator-echo`):
    /// every video-tags request is answered instantly with one tag named after
    /// the video's creator, bypassing the decision cache and LLM classification
    /// entirely. This isolates the extension→hub→app→pill path from model
    /// latency and never activates outside the development environment.
    static let creatorEchoTestMode = VaultRuntimeEnvironment.current == .development
        && ProcessInfo.processInfo.environment["ADAMANCIA_VAULT_TAG_TEST"] == "creator-echo"

    /// `acceptedTags` silently drops any tag whose colors fail the OKLab
    /// theme-pair validation, so hardcoded hexes would render as a "None" pill.
    /// Search neutral greys with the real validator instead: near-achromatic
    /// pairs skip the hue check, so a grey pair inside the lightness-inversion
    /// window is guaranteed to survive `acceptedTags`. Computed once, lazily.
    static let creatorEchoColors: (light: String, dark: String) = {
        for dark in stride(from: 20, through: 140, by: 2) {
            let darkHex = String(format: "#%02X%02X%02X", dark, dark, dark)
            for light in 150...250 {
                let lightHex = String(format: "#%02X%02X%02X", light, light, light)
                if TagColorAssignment.isValidThemePair(lightHex: lightHex, darkHex: darkHex) {
                    return (lightHex, darkHex)
                }
            }
        }
        return ("#E5E7EB", "#3F3F46")
    }()

    func refreshLocalState() {
        localState = coordinator?.snapshot()
        reconcileProviderModelCatalogs()
    }

    struct ProviderResponseParseFailure: LocalizedError {
        let underlyingError: Error
        let statusCode: Int
        let responseShape: String
        let usage: ProviderTestUsage

        init(
            underlyingError: Error,
            statusCode: Int,
            responseShape: String,
            usage: ProviderTestUsage = .init(tokenCount: nil)
        ) {
            self.underlyingError = underlyingError
            self.statusCode = statusCode
            self.responseShape = responseShape
            self.usage = usage
        }

        var errorDescription: String? { underlyingError.localizedDescription }
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
                  catalog.trashCollectionPlatform(platformID) != nil else {
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
        presentNativeConfirmation(
            title: "Delete \(binding.name)?",
            message: "This stops collection and removes \(entries) retained entries for this platform. Shared trees and classification data remain.",
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

    /// Creates a classifier type (a "group") from a preset the person picks. A
    /// preset is the *only* way to create a type: it seeds the type's on-device
    /// model overrides, its grounded-research profile, and a RAM-appropriate model
    /// (when already downloaded), so nobody hand-tunes the underlying knobs at
    /// creation. The detailed form stays available afterwards as "Advanced", which
    /// reports drift as "modified from <preset>". `presetID` must resolve to a
    /// known `VaultPreset`.
    func createClassifierType(name: String, platformID: String, presetID: String) {
        do {
            let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let preset = VaultPreset.resolve(presetID.trimmingCharacters(in: .whitespacesAndNewlines)),
                  !cleaned.isEmpty,
                  cleaned.count <= ClassifierTypeAsset.maximumNameLength,
                  CollectionPlatformRegistry.definition(for: platformID) != nil,
                  var catalog = localState?.workspaceCatalog else {
                throw WebBridgeInputError.invalidChoice("classifier type")
            }
            // Every platform is collectable by default; make sure its binding (the
            // shared dataset + collection toggle) exists before binding the type.
            let binding = try catalog.ensurePlatformBinding(platformID)
            guard let dataset = catalog.datasets.first(where: { $0.id == binding.datasetID }) else {
                throw WebBridgeInputError.invalidChoice("classifier type")
            }
            // Each type owns a fresh, empty tree — its own taxonomy.
            let tree = TagTreeAsset(name: cleaned, nodes: [])
            catalog.trees.append(tree)
            let nextOrder = (catalog.classifierTypes.map(\.order).max() ?? -1) + 1
            // Apply the preset bundle. Model file is set only when the recommended
            // model for this machine's RAM is already on disk — a preset must never
            // point a type at a missing model (nil = inherit the global choice).
            let modelFileName = preset.modelFileName(
                systemRAMGB: HardwareProfile.physicalRAMGB(),
                availableModelFiles: VaultLocalLLMEngine.availableModelFiles()
            )
            catalog.classifierTypes.append(.init(
                name: cleaned,
                treeID: tree.id,
                treeRevision: tree.revision,
                datasetID: dataset.id,
                datasetRevision: dataset.revision,
                applicablePlatformID: platformID,
                localModelOverrides: preset.localModelOverrides,
                modelFileName: modelFileName,
                researchOverrides: preset.researchOverrides(),
                presetID: preset.rawValue,
                order: nextOrder
            ))
            try coordinator?.updateWorkspaceCatalog(catalog)
            refreshLocalState()
            issue = nil
        } catch { issue = error.localizedDescription }
    }

    /// Rewrites the reorderable list positions from the order the person dragged
    /// them into. Unknown ids are ignored; omitted types keep their position.
    func reorderClassifierTypes(orderedIDs: [String]) {
        do {
            guard var catalog = localState?.workspaceCatalog else {
                throw WebBridgeInputError.invalidChoice("classifier type order")
            }
            var rank: [String: Int] = [:]
            for (index, id) in orderedIDs.enumerated() { rank[id] = index }
            for index in catalog.classifierTypes.indices {
                if let position = rank[catalog.classifierTypes[index].id] {
                    catalog.classifierTypes[index].order = position
                }
            }
            try coordinator?.updateWorkspaceCatalog(catalog)
            refreshLocalState()
            issue = nil
        } catch { issue = error.localizedDescription }
    }

    func configureClassifierType(
        typeID: String,
        name: String,
        applicablePlatformID: String
    ) {
        do {
            let cleanedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanedName.isEmpty,
                  cleanedName.count <= ClassifierTypeAsset.maximumNameLength,
                  var catalog = localState?.workspaceCatalog,
                  let typeIndex = catalog.classifierTypes.firstIndex(where: { $0.id == typeID }) else {
                throw WebBridgeInputError.invalidChoice("classifier type")
            }
            let existingClassifierType = catalog.classifierTypes[typeIndex]
            guard CollectionPlatformRegistry.definition(for: applicablePlatformID) != nil else {
                throw WebBridgeInputError.invalidChoice("classifier type")
            }
            let selectedBinding = try catalog.ensurePlatformBinding(applicablePlatformID)
            guard
                  // A type owns its own tree; the binding only supplies the shared
                  // dataset and the platform.
                  let tree = catalog.trees.first(where: { $0.id == existingClassifierType.treeID }),
                  let dataset = catalog.datasets.first(where: { $0.id == selectedBinding.datasetID }) else {
                throw WebBridgeInputError.invalidChoice("classifier type")
            }
            catalog.classifierTypes[typeIndex] = .init(
                id: catalog.classifierTypes[typeIndex].id,
                name: cleanedName,
                treeID: tree.id,
                treeRevision: tree.revision,
                datasetID: dataset.id,
                datasetRevision: dataset.revision,
                applicablePlatformID: selectedBinding.id,
                localModelOverrides: existingClassifierType.localModelOverrides,
                modelFileName: existingClassifierType.modelFileName,
                researchOverrides: existingClassifierType.researchOverrides,
                presetID: existingClassifierType.presetID,
                order: catalog.classifierTypes[typeIndex].order
            )
            try coordinator?.updateWorkspaceCatalog(catalog)
            refreshLocalState()
            issue = nil
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
            catalog.bindings[bindingIndex].activeClassifierTypeID = normalizedTypeID
            try coordinator?.updateWorkspaceCatalog(catalog)
            refreshLocalState()
            issue = nil
        } catch { issue = error.localizedDescription }
    }

    func deleteClassifierType(typeID: String) {
        do {
            guard var catalog = localState?.workspaceCatalog,
                  catalog.trashClassifierType(typeID) != nil else {
                throw WebBridgeInputError.invalidChoice("classifier type")
            }
            try coordinator?.updateWorkspaceCatalog(catalog)
            refreshLocalState()
            issue = nil
        } catch { issue = error.localizedDescription }
    }

    func restoreTrashedEntry(entryID: String) {
        do {
            guard var catalog = localState?.workspaceCatalog,
                  catalog.restoreTrashedEntry(entryID) else {
                throw WebBridgeInputError.invalidChoice("trash entry")
            }
            try coordinator?.updateWorkspaceCatalog(catalog)
            refreshLocalState()
            issue = nil
        } catch { issue = error.localizedDescription }
    }

    func permanentlyDeleteTrashedEntry(entryID: String) {
        do {
            guard var catalog = localState?.workspaceCatalog,
                  catalog.permanentlyDeleteTrashedEntry(entryID) else {
                throw WebBridgeInputError.invalidChoice("trash entry")
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
            message: "This removes this local decision configuration. Other data and provider profiles are retained.",
            confirmTitle: "Delete classifier type"
        ) { [weak self] in
            self?.deleteClassifierType(typeID: typeID)
        }
    }

    func presentNativeConfirmation(
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
            guard var catalog = localState?.workspaceCatalog else {
                throw WebBridgeInputError.invalidChoice("tag tree")
            }
            // A referenced ("bounded") tree cannot be trashed; trashTagTree
            // throws treeInUse and the message names why. Only an unreferenced
            // tree moves to trash.
            guard try catalog.trashTagTree(treeID) != nil else {
                throw WebBridgeInputError.invalidChoice("tag tree")
            }
            try coordinator?.updateWorkspaceCatalog(catalog)
            refreshLocalState()
            issue = nil
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

    private func normalizedTagDescription(_ rawDescription: String?) throws -> String? {
        let cleaned = rawDescription?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard cleaned.count <= TagTreeNode.maximumDescriptionLength else {
            throw WebBridgeInputError.invalidChoice("tag description")
        }
        return cleaned.isEmpty ? nil : cleaned
    }

    func addTag(
        treeID: String,
        name: String,
        description: String?,
        parentID: String?,
        positionX: Double,
        positionY: Double
    ) {
        do {
            guard var catalog = localState?.workspaceCatalog,
                  let treeIndex = catalog.trees.firstIndex(where: { $0.id == treeID }) else {
                throw WebBridgeInputError.invalidChoice("tag tree")
            }
            let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { throw WebBridgeInputError.invalidChoice("tag name") }
            let cleanedDescription = try normalizedTagDescription(description)
            let normalizedParentID = parentID?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let normalizedParentID, !normalizedParentID.isEmpty,
               !catalog.trees[treeIndex].nodes.contains(where: { $0.id == normalizedParentID }) {
                throw WebBridgeInputError.invalidChoice("tag parent")
            }
            catalog.trees[treeIndex].nodes.append(.init(
                name: cleaned,
                description: cleanedDescription,
                parentID: normalizedParentID?.isEmpty == false ? normalizedParentID : nil,
                positionX: positionX,
                positionY: positionY
            ))
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

    func updateTag(treeID: String, nodeID: String, name: String, description: String?) {
        do {
            guard var catalog = localState?.workspaceCatalog,
                  let treeIndex = catalog.trees.firstIndex(where: { $0.id == treeID }),
                  let nodeIndex = catalog.trees[treeIndex].nodes.firstIndex(where: { $0.id == nodeID }) else {
                throw WebBridgeInputError.invalidChoice("tag node")
            }
            let cleanedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanedName.isEmpty else { throw WebBridgeInputError.invalidChoice("tag name") }
            let cleanedDescription = try normalizedTagDescription(description)
            catalog.trees[treeIndex].nodes[nodeIndex].name = cleanedName
            catalog.trees[treeIndex].nodes[nodeIndex].description = cleanedDescription
            advanceTreeRevision(in: &catalog, treeIndex: treeIndex)
            try coordinator?.updateWorkspaceCatalog(catalog)
            refreshLocalState()
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
            TagColorAssignment.invalidateSubtree(
                rootID: nodeID,
                in: &catalog.trees[treeIndex]
            )
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
            TagColorAssignment.invalidateSubtree(
                rootID: nodeID,
                in: &catalog.trees[treeIndex]
            )
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
            let reparentedNodeIDs = catalog.trees[treeIndex].nodes.compactMap { node in
                node.parentID == nodeID ? node.id : nil
            }
            catalog.trees[treeIndex].nodes.remove(at: nodeIndex)
            for index in catalog.trees[treeIndex].nodes.indices where catalog.trees[treeIndex].nodes[index].parentID == nodeID {
                catalog.trees[treeIndex].nodes[index].parentID = replacementParentID
            }
            for reparentedNodeID in reparentedNodeIDs {
                TagColorAssignment.invalidateSubtree(
                    rootID: reparentedNodeID,
                    in: &catalog.trees[treeIndex]
                )
            }
            advanceTreeRevision(in: &catalog, treeIndex: treeIndex)
            try coordinator?.updateWorkspaceCatalog(catalog)
            refreshLocalState()
        } catch { issue = error.localizedDescription }
    }

    private func advanceTreeRevision(in catalog: inout WorkspaceCatalog, treeIndex: Int) {
        catalog.trees[treeIndex].revision += 1
        catalog.trees[treeIndex].updatedAtMilliseconds = WorkspaceCatalog.now()
    }

    func savePackageSettings() {
        do {
            guard let coordinator else { return }
            let settings = ClassifierSettings(
                packageUpdateMode: packageUpdateMode,
                localLLM: llmSettings,
                research: localState?.settings.research ?? ResearchSettings()
            )
            try coordinator.updateSettings(settings)
            refreshLocalState()
            issue = nil
        } catch {
            issue = error.localizedDescription
        }
    }

    /// Persists the local-model settings and rebuilds the engine so every knob
    /// (model file, context, sampling, decline, thresholds) applies immediately.
    func saveLocalLLMSettings(_ updated: LocalLLMSettings) {
        guard let coordinator else { return }
        do {
            llmSettings = updated
            let settings = ClassifierSettings(
                packageUpdateMode: packageUpdateMode,
                localLLM: updated,
                research: localState?.settings.research ?? ResearchSettings()
            )
            try coordinator.updateSettings(settings)
            coordinator.setClassificationOptions(maximumTags: updated.maximumTags, houseRules: updated.houseRules)
            installLocalLLMEngine(coordinator: coordinator)
            refreshLocalState()
            issue = nil
        } catch {
            issue = error.localizedDescription
        }
    }

    func downloadModel(id: String) {
        guard let entry = LocalModelCatalog.entry(id: id) else {
            issue = "The selected model is not in the local catalog."
            return
        }
        guard !VaultLocalLLMEngine.availableModelFiles().contains(entry.ggufFileName) else {
            modelDownloadFractions.removeValue(forKey: id)
            issue = nil
            return
        }
        guard modelDownloadFractions[id] == nil else { return }
        modelDownloadFractions[id] = 0
        issue = nil
        let manager = modelDownloadManager
        let reportProgress: ModelDownloadManager.ProgressHandler = { [weak self] progress in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.modelDownloadFractions[id] = progress.fraction
                self.onWebStateChange?()
            }
        }
        Task { [weak self] in
            do {
                _ = try await manager.download(entry, progress: reportProgress)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.modelDownloadFractions.removeValue(forKey: id)
                    self.issue = nil
                    // No silent default exists anymore, so the FIRST model the user
                    // downloads becomes the active one (loads the engine); a later
                    // download never overrides an already-chosen model.
                    if (self.llmSettings.modelFileName ?? "").isEmpty {
                        var updated = self.llmSettings
                        updated.modelFileName = entry.ggufFileName
                        self.saveLocalLLMSettings(updated)
                    }
                    self.onWebStateChange?()
                }
            } catch is CancellationError {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.modelDownloadFractions.removeValue(forKey: id)
                    self.onWebStateChange?()
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.modelDownloadFractions.removeValue(forKey: id)
                    self.issue = error.localizedDescription
                    self.onWebStateChange?()
                }
            }
        }
    }

    func cancelModelDownload(id: String) {
        guard LocalModelCatalog.entry(id: id) != nil else {
            issue = "The selected model is not in the local catalog."
            return
        }
        modelDownloadFractions.removeValue(forKey: id)
        let manager = modelDownloadManager
        Task { [weak self] in
            await manager.cancel(id: id)
            await MainActor.run { [weak self] in
                self?.onWebStateChange?()
            }
        }
    }

    func deleteModelFile(fileName: String) {
        let manager = modelDownloadManager
        Task { [weak self] in
            do {
                try await manager.deleteModelFile(fileName: fileName)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.issue = nil
                    self.onWebStateChange?()
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.issue = error.localizedDescription
                    self.onWebStateChange?()
                }
            }
        }
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

    func saveResearchSettings(_ updated: ResearchSettings) {
        guard let coordinator else { return }
        do {
            guard let catalog = localState?.workspaceCatalog else { return }
            try Self.validateResearchSettingsForEnable(updated, catalog: catalog)
            let current = localState?.settings ?? .init()
            try coordinator.updateSettings(.init(
                packageUpdateMode: current.packageUpdateMode,
                localLLM: current.localLLM,
                research: updated
            ))
            refreshLocalState()
            if updated.enabled { coordinator.startResearchBackfill() }
            issue = nil
        } catch {
            issue = error.localizedDescription
        }
    }

    nonisolated private static func validateResearchSettingsForEnable(
        _ settings: ResearchSettings,
        catalog: WorkspaceCatalog
    ) throws {
        guard settings.enabled else { return }
        guard let llmProfileID = settings.llmProviderProfileID,
              let modelIdentifier = settings.llmModelIdentifier,
              !modelIdentifier.isEmpty,
              let llmProfile = catalog.providerProfiles.first(where: { $0.id == llmProfileID }),
              ProviderGenerationProtocol.supportsGeneration(profile: llmProfile) else {
            throw WebBridgeInputError.invalidChoice("research providers and model")
        }
        _ = try researchCredential(for: llmProfile)

        guard GroundedGenerationProtocol.supportsProviderGrounding(profile: llmProfile) else {
            throw WebBridgeInputError.invalidChoice("grounding-capable provider")
        }
    }

    func saveClassifierTypeResearch(
        typeID: String,
        overrideEnabled: Bool,
        settings: ResearchSettings?
    ) {
        do {
            guard var catalog = localState?.workspaceCatalog,
                  let index = catalog.classifierTypes.firstIndex(where: { $0.id == typeID }),
                  catalog.classifierTypes[index].applicablePlatformID
                    .flatMap(CollectionPlatformRegistry.definition(for:))?.supportsLocalModel == true else {
                throw WebBridgeInputError.invalidChoice("classifier type research")
            }
            let overrideSettings = overrideEnabled ? settings : nil
            if let overrideSettings {
                try Self.validateResearchSettingsForEnable(overrideSettings, catalog: catalog)
            }
            catalog.classifierTypes[index].researchOverrides = overrideSettings
            catalog.classifierTypes[index].updatedAtMilliseconds = WorkspaceCatalog.now()
            try coordinator?.updateWorkspaceCatalog(catalog)
            refreshLocalState()
            if overrideSettings?.enabled == true,
               localState?.settings.research.enabled == true {
                coordinator?.startResearchBackfill()
            }
            issue = nil
        } catch {
            issue = error.localizedDescription
        }
    }

    func saveClassifierTypeLocalModel(
        typeID: String,
        overrideEnabled: Bool,
        modelFileName: String?,
        houseRules: String?,
        allowDecline: Bool?,
        confidenceThresholds: [Double]?,
        thumbnailOcrEvidence: Bool?,
        maximumTags: Int?,
        minimumTags: Int?,
        expectedTags: Int?
    ) {
        do {
            guard var catalog = localState?.workspaceCatalog,
                  let index = catalog.classifierTypes.firstIndex(where: { $0.id == typeID }),
                  catalog.classifierTypes[index].applicablePlatformID
                    .flatMap(CollectionPlatformRegistry.definition(for:))?.supportsLocalModel == true else {
                throw WebBridgeInputError.invalidChoice("classifier type local model")
            }
            let overrides = overrideEnabled ? LocalModelOverrides(
                houseRules: houseRules,
                allowDecline: allowDecline,
                confidenceThresholds: confidenceThresholds,
                thumbnailOcrEvidence: thumbnailOcrEvidence,
                maximumTags: maximumTags,
                minimumTags: minimumTags,
                expectedTags: expectedTags
            ) : nil
            catalog.classifierTypes[index].localModelOverrides = overrides?.isEmpty == false ? overrides : nil
            catalog.classifierTypes[index].modelFileName = modelFileName
            catalog.classifierTypes[index].updatedAtMilliseconds = WorkspaceCatalog.now()
            try coordinator?.updateWorkspaceCatalog(catalog)
            refreshLocalState()
            issue = nil
        } catch {
            issue = error.localizedDescription
        }
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

    static func parseClassifierTypeLocalModelWebInput(
        _ data: [String: Any]
    ) throws -> ClassifierTypeLocalModelWebInput {
        guard let typeID = data["typeID"] as? String, !typeID.isEmpty, typeID.count <= 256 else {
            throw WebBridgeInputError.missingValue("typeID")
        }
        guard let overrideEnabled = data["overrideEnabled"] as? Bool else {
            throw WebBridgeInputError.missingValue("overrideEnabled")
        }
        let modelFileName: String?
        if let rawModelFileName = data["modelFileName"] as? String {
            guard rawModelFileName.count <= 255 else {
                throw WebBridgeInputError.exceedsLimit("modelFileName", 255)
            }
            let cleaned = rawModelFileName.trimmingCharacters(in: .whitespacesAndNewlines)
            modelFileName = cleaned.isEmpty ? nil : cleaned
        } else {
            modelFileName = nil
        }
        guard overrideEnabled else {
            return .init(
                typeID: typeID,
                overrideEnabled: false,
                modelFileName: modelFileName,
                overrides: nil
            )
        }

        let houseRules: String?
        if let raw = data["houseRules"] as? String {
            guard raw.count <= 4_000 else { throw WebBridgeInputError.exceedsLimit("houseRules", 4_000) }
            houseRules = raw
        } else {
            houseRules = nil
        }
        let rawThresholds = ["confidenceBand2", "confidenceBand3", "confidenceBand4", "confidenceBand5"]
            .compactMap { key -> Double? in
                guard let raw = data[key] as? String,
                      let value = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
                      value.isFinite else { return nil }
                return value
            }
        // Empty/blank/unparseable → nil = inherit the global cap; the struct
        // clamps a set value to 1–16.
        let maximumTags: Int?
        if let raw = data["maximumTags"] as? String {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            maximumTags = trimmed.isEmpty ? nil : Int(trimmed)
        } else {
            maximumTags = data["maximumTags"] as? Int
        }
        let overrides = LocalModelOverrides(
            houseRules: houseRules,
            allowDecline: data["allowDecline"] as? Bool,
            confidenceThresholds: rawThresholds.isEmpty ? nil : rawThresholds,
            thumbnailOcrEvidence: data["thumbnailOcrEvidence"] as? Bool,
            maximumTags: maximumTags,
            minimumTags: Self.optionalWebInteger(data["minimumTags"]),
            expectedTags: Self.optionalWebInteger(data["expectedTags"])
        )
        return .init(
            typeID: typeID,
            overrideEnabled: true,
            modelFileName: modelFileName,
            overrides: overrides.isEmpty ? nil : overrides
        )
    }

    static func parseClassifierTypeResearchWebInput(
        _ data: [String: Any]
    ) throws -> ClassifierTypeResearchWebInput {
        guard let typeID = data["typeID"] as? String, !typeID.isEmpty, typeID.count <= 256 else {
            throw WebBridgeInputError.missingValue("typeID")
        }
        guard let overrideEnabled = data["overrideEnabled"] as? Bool else {
            throw WebBridgeInputError.missingValue("overrideEnabled")
        }
        guard overrideEnabled else {
            return .init(typeID: typeID, overrideEnabled: false, settings: nil)
        }

        let defaults = ResearchSettings()
        func optionalString(_ key: String) -> String? { data[key] as? String }
        func optionalInteger(_ key: String) -> Int? {
            guard let raw = data[key] as? String else { return nil }
            return Int(raw.replacingOccurrences(of: ",", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return .init(
            typeID: typeID,
            overrideEnabled: true,
            settings: ResearchSettings(
                enabled: data["enabled"] as? Bool ?? defaults.enabled,
                llmProviderProfileID: optionalString("llmProviderProfileID"),
                llmModelIdentifier: optionalString("llmModelIdentifier"),
                requestsPerMinute: optionalInteger("requestsPerMinute") ?? defaults.requestsPerMinute,
                dailyTokenLimit: optionalInteger("dailyTokenLimit") ?? defaults.dailyTokenLimit,
                cooldownHours: optionalInteger("cooldownHours") ?? defaults.cooldownHours,
                urgencyFloor: optionalInteger("urgencyFloor") ?? defaults.urgencyFloor,
                authorThreshold: AuthorResearchThreshold(
                    level: optionalInteger("authorLevel") ?? defaults.authorThreshold.level,
                    count: optionalInteger("authorCount") ?? defaults.authorThreshold.count,
                    windowDays: optionalInteger("authorWindowDays") ?? defaults.authorThreshold.windowDays
                ),
                knowledgeTTLDays: optionalInteger("knowledgeTTLDays") ?? defaults.knowledgeTTLDays,
                maxKnowledgePerVideo: optionalInteger("maxKnowledgePerVideo") ?? defaults.maxKnowledgePerVideo
            )
        )
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
                ? "Private local snapshots are enabled. Use Create backup now when you want a new snapshot."
                : "Local backups are off. Existing snapshots were left untouched."
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

    private func loadResourceSettings(from settings: ClassifierSettings) {
        packageUpdateMode = settings.packageUpdateMode
        llmSettings = settings.localLLM
        coordinator?.setClassificationOptions(
            maximumTags: settings.localLLM.maximumTags,
            houseRules: settings.localLLM.houseRules
        )
    }

    private func loadBackupConfiguration(from configuration: LocalBackupConfiguration?) {
        let defaultDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Vault Classifier Backups", isDirectory: true)
            .path
        backupDirectory = configuration?.directoryPath ?? defaultDirectory
        backupEnabled = configuration?.isEnabled ?? false
    }

    func positiveInteger(_ raw: String, label: String) throws -> Int {
        let digits = raw.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(digits), value > 0 else { throw AppInputError.invalidNumber(label) }
        return value
    }

    func nonnegativeInteger(_ raw: String, label: String) throws -> Int {
        let digits = raw.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(digits), value >= 0 else { throw AppInputError.invalidNumber(label) }
        return value
    }

}

enum AppInputError: Error, LocalizedError {
    case invalidNumber(String)
    case backupLocked

    var errorDescription: String? {
        switch self {
        case .invalidNumber(let label): return "\(label) must be a positive whole number."
        case .backupLocked: return "Enter the local backup owner code before changing backup mode."
        }
    }
}

enum ProviderTestHTTPError: Error, LocalizedError {
    case status(Int)

    var errorDescription: String? {
        switch self {
        case .status(let status): return "The provider returned HTTP \(status)."
        }
    }
}

enum WebBridgeInputError: Error, LocalizedError {
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
