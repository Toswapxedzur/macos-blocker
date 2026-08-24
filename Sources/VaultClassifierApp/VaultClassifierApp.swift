import AppKit
import Combine
import VaultClassifierCore
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

        var id: String { rawValue }
    }

    @Published var workspace: Workspace = .tagTree
    @Published var issue: String?
    @Published var localState: LocalClassifierState?
    @Published var policies: [NamedPolicy] = []
    @Published var editingPolicyID = ""
    @Published var editingPolicyName = ""
    @Published var editingPolicyIncludeTag = "content.entities.clash-royale"
    @Published var editingPolicyExcludeTag = ""
    @Published var editingFeedAction: PresentationAction = .dim
    @Published var editingPageAction: PresentationAction = .block
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

    private var coordinator: LocalClassifierCoordinator?
    private var groundedResearchQueue: GroundedResearchQueue?
    private var sharedHubClient: SharedHubClient?
    private var collectionDiagnostics: CollectionDiagnosticsStore?
    private var providerModelCatalogStore: ProviderModelCatalogStore?
    private(set) var sourceIconCache: SourceIconCache?
    private var testingProviderProfileIDs = Set<String>()
    private var successfulProviderTestProfileIDs = Set<String>()
    /// Model identifiers and model-list capability signals come from explicit
    /// provider Probes. They are retained without credentials or request data.
    private var providerModelCatalogs = [String: [ProviderModelCatalogEntry]]()
    private var providerModelCatalogErrors = [String: String]()
    private var loadingProviderModelProfileIDs = Set<String>()
    private let modelDownloadManager: ModelDownloadManager
    private var modelDownloadFractions: [String: Double] = [:]

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
            let coordinator = try LocalClassifierCoordinator(verifiedPackage: package, stateFile: LocalStateFile(url: vaultDirectory.appendingPathComponent("state.json")), defaultPolicies: [StarterPolicies.clashRoyale])
            self.coordinator = coordinator
            self.policies = coordinator.policies()
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
              let searchProfileID = settings.webSearchProviderProfileID,
              let llmProfile = profiles.first(where: { $0.id == llmProfileID }),
              let searchProfile = profiles.first(where: { $0.id == searchProfileID }),
              ProviderGenerationProtocol.supportsGeneration(profile: llmProfile),
              searchProfile.type.supportsRawWebSearch,
              let llmCredential = try? researchCredential(for: llmProfile),
              let searchCredential = try? researchCredential(for: searchProfile)
        else { return nil }

        return .init(
            providers: .init(
                llmProfile: llmProfile,
                llmCredential: llmCredential,
                llmModelIdentifier: modelIdentifier,
                webSearchProfile: searchProfile,
                webSearchCredential: searchCredential,
                searchResultCount: settings.searchResultCount,
                snippetContextChars: settings.snippetContextChars
            ),
            requestsPerMinute: settings.requestsPerMinute,
            dailyTokenLimit: settings.dailyTokenLimit,
            failureCooldownMilliseconds: Int64(settings.cooldownHours) * 60 * 60 * 1_000
        )
    }

    nonisolated private static func researchCredential(
        for profile: APIKeyProviderProfile
    ) throws -> ProviderCredentialRecord {
        let descriptor = ProviderProtocolRegistry.descriptor(for: profile.type)
        guard !descriptor.credentialFields.isEmpty else { return .init(values: [:]) }
        let value = profile.credential?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard descriptor.credentialFields.count == 1,
              let field = descriptor.credentialFields.first,
              !value.isEmpty else {
            throw ProviderTestProtocolError.missingCredential
        }
        let credential = ProviderCredentialRecord(values: [field: value])
        try credential.validate(for: descriptor)
        return credential
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

    private func handleSharedHubRequest(_ request: SharedHubClient.Request) -> SharedHubClient.Reply {
        handleSharedHubRequestBody(request)
    }

    // Dev-only instrumentation, routed into the unified VaultDevLog file.
    private static let perfEnabled = VaultDevLog.shared.isEnabled
    private func perfLog(_ message: @autoclosure () -> String) {
        guard Self.perfEnabled else { return }
        let collected = localState?.workspaceCatalog.datasets.reduce(0) { $0 + $1.collectedEntries.count } ?? -1
        VaultDevLog.shared.log("perf", message(), ["collected": "\(collected)"])
    }
    /// Structured native-side event into the unified dev log.
    private func devLog(_ event: String, _ fields: [String: String] = [:]) {
        VaultDevLog.shared.log("native", event, fields)
    }
    private func perfMS(_ start: DispatchTime, _ end: DispatchTime = DispatchTime.now()) -> String {
        String(format: "%.1f", Double(end.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
    }

    /// Maps display tag nodes to the wire tag shape, dropping any whose colors do
    /// not normalize. The response struct additionally gates on a valid theme
    /// pair; keeping this mapping shared means the single and batch paths emit
    /// identical tags.
    private static func nativeVideoTags(from tags: [TagNode]) -> [NativeVideoTag] {
        tags.compactMap { tag in
            guard let lightColorHex = TagColorAssignment.normalizedHex(tag.lightColorHex),
                  let darkColorHex = TagColorAssignment.normalizedHex(tag.darkColorHex) else {
                return nil
            }
            return NativeVideoTag(
                id: tag.id,
                name: tag.name,
                lightColorHex: lightColorHex,
                darkColorHex: darkColorHex
            )
        }
    }

    /// Classifications currently running, keyed by platform + entryID. Repeated
    /// pending requests for a video already on the serial LLM queue must not
    /// enqueue duplicate work — without this, every provisional re-request
    /// multiplied the queue and starved the tail of the viewport.
    private var inFlightVideoClassifications = Set<String>()

    private static func inFlightKey(_ platformID: String, _ entryID: String) -> String {
        "\(platformID)\u{1F}\(entryID)"
    }

    /// Queue background classification for videos with no cached decision,
    /// skipping any already in flight. Each completed video is broadcast through
    /// the hub so provisional pills resolve the moment the result exists,
    /// instead of waiting for the extension's next poll.
    private func queueVideoClassification(platformID: String, items: [NativeVideoTagsBatchItem]) {
        let fresh = items.filter {
            inFlightVideoClassifications.insert(Self.inFlightKey(platformID, $0.entryID)).inserted
        }
        guard !fresh.isEmpty else { return }
        Task { @MainActor [weak self] in
            for item in fresh {
                defer { self?.inFlightVideoClassifications.remove(Self.inFlightKey(platformID, item.entryID)) }
                guard let coordinator = self?.coordinator else { continue }
                guard let projection = try? await coordinator.classifyVideo(
                    platformID: platformID, entryID: item.entryID, creatorID: item.creatorID,
                    title: item.title, summary: item.summary, text: item.text) else { continue }
                self?.broadcastResolvedVideoTags(platformID: platformID, entryID: item.entryID, projection: projection)
            }
            self?.onWebStateChange?()
        }
    }

    private func broadcastResolvedVideoTags(platformID: String, entryID: String, projection: VideoTagsProjection) {
        let broadcast = NativeVideoTagsBroadcast(platformID: platformID, items: [NativeVideoTagsBatchResponseItem(
            entryID: entryID, tags: Self.nativeVideoTags(from: projection.tags),
            predicted: projection.predicted, pending: false)])
        guard let encoded = try? JSONEncoder().encode(broadcast),
              let object = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any] else { return }
        sharedHubClient?.broadcast(operation: "video-tags-updated", body: object)
        devLog("video-tags-updated", ["platform": platformID, "entry": entryID, "tags": "\(projection.tags.count)"])
    }

    /// Dev-only pipeline test mode (`ADAMANCIA_VAULT_TAG_TEST=creator-echo`):
    /// every video-tags request is answered instantly with one tag named after
    /// the video's creator, bypassing the decision cache and LLM classification
    /// entirely. This isolates the extension→hub→app→pill path from model
    /// latency and never activates outside the development environment.
    private static let creatorEchoTestMode = VaultRuntimeEnvironment.current == .development
        && ProcessInfo.processInfo.environment["ADAMANCIA_VAULT_TAG_TEST"] == "creator-echo"

    /// `acceptedTags` silently drops any tag whose colors fail the OKLab
    /// theme-pair validation, so hardcoded hexes would render as a "None" pill.
    /// Search neutral greys with the real validator instead: near-achromatic
    /// pairs skip the hue check, so a grey pair inside the lightness-inversion
    /// window is guaranteed to survive `acceptedTags`. Computed once, lazily.
    private static let creatorEchoColors: (light: String, dark: String) = {
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

    private static func creatorEchoTag(creatorID: String) -> NativeVideoTag {
        // "youtube:handle:@name" → "@name"; fall back to the whole identifier.
        let name = creatorID.split(separator: ":").last.map(String.init) ?? creatorID
        return NativeVideoTag(
            id: "vault:test:\(name)",
            name: name,
            lightColorHex: Self.creatorEchoColors.light,
            darkColorHex: Self.creatorEchoColors.dark
        )
    }

    private func handleSharedHubRequestBody(_ request: SharedHubClient.Request) -> SharedHubClient.Reply {
        do {
            guard let coordinator else { return .failure("classifier-unavailable") }
            if request.operation != .collect && request.operation != .diagnostic {
                devLog("hub-op", ["op": request.operation.rawValue])
            }
            switch request.operation {
            case .bridgeInfo:
                _ = try JSONDecoder().decode(NativeBridgeInfoRequest.self, from: request.bodyData)
                let response = NativeBridgeInfoResponse(policies: coordinator.policies().prefix(64).map {
                    NativeBridgePolicy(id: $0.id, name: $0.name)
                })
                return try sharedHubReply(response)
            case .collectionInfo:
                _ = try JSONDecoder().decode(NativeCollectionInfoRequest.self, from: request.bodyData)
                let response = NativeCollectionInfoResponse(enabledPlatformIDs: coordinator.enabledCollectionPlatformIDs(), developmentMode: VaultDevLog.shared.isEnabled)
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
                // Diagnostics are recorded to the local log, not the web
                // snapshot; pushing here would re-render the whole UI with an
                // unchanged payload.
                return try sharedHubReply(NativeCollectionDiagnosticResponse(accepted: true))
            case .collect:
                let request = try JSONDecoder().decode(NativeCollectionRequest.self, from: request.bodyData)
                collectionDiagnostics?.record(platformID: request.entry.platform, event: "collection-received", outcome: "received")
                let tStore = DispatchTime.now()
                let inserted = try coordinator.collectPlatformEntry(
                    request.entry,
                    firstObservedAtMilliseconds: request.firstObservedAtMilliseconds,
                    lastObservedAtMilliseconds: request.lastObservedAtMilliseconds,
                    observationCount: request.observationCount
                )
                cacheSourceIcon(from: request.entry)
                collectionDiagnostics?.record(platformID: request.entry.platform, event: "collection-stored", outcome: inserted ? "inserted" : "duplicate")
                // Browser collection bypasses WebKit actions, so publish the
                // freshly persisted catalog to the already-open app now.
                let tSnapshot = DispatchTime.now()
                refreshLocalState()
                let tPush = DispatchTime.now()
                onWebStateChange?()
                let tEnd = DispatchTime.now()
                perfLog("collect store=\(perfMS(tStore, tSnapshot)) snapshot=\(perfMS(tSnapshot, tPush)) push=\(perfMS(tPush, tEnd)) total=\(perfMS(tStore, tEnd))ms")
                return try sharedHubReply(NativeCollectionResponse(accepted: true, inserted: inserted))
            case .videoTags:
                let videoTags = try JSONDecoder().decode(NativeVideoTagsRequest.self, from: request.bodyData)
                try videoTags.validate()
                if Self.creatorEchoTestMode {
                    devLog("video-tags", ["platform": videoTags.platformID, "entry": videoTags.entryID, "outcome": "creator-echo"])
                    return try sharedHubReply(NativeVideoTagsResponse(
                        platformID: videoTags.platformID, entryID: videoTags.entryID,
                        tags: [Self.creatorEchoTag(creatorID: videoTags.creatorID)], predicted: false, pending: false))
                }
                if let cached = coordinator.cachedVideoTags(platformID: videoTags.platformID, entryID: videoTags.entryID) {
                    devLog("video-tags", ["platform": videoTags.platformID, "entry": videoTags.entryID, "outcome": "cached", "tags": "\(cached.tags.count)"])
                    return try sharedHubReply(NativeVideoTagsResponse(
                        platformID: videoTags.platformID, entryID: videoTags.entryID,
                        tags: Self.nativeVideoTags(from: cached.tags), predicted: cached.predicted, pending: false))
                }
                // No classifier type targets this platform → definitively empty, not
                // pending (avoids a stuck "Tagging" pill that re-requests forever).
                guard coordinator.hasClassifierTypes(platformID: videoTags.platformID) else {
                    devLog("video-tags", ["platform": videoTags.platformID, "entry": videoTags.entryID, "outcome": "empty-no-types"])
                    return try sharedHubReply(NativeVideoTagsResponse(
                        platformID: videoTags.platformID, entryID: videoTags.entryID, tags: [], predicted: false, pending: false))
                }
                devLog("video-tags", ["platform": videoTags.platformID, "entry": videoTags.entryID, "outcome": "queued-pending"])
                // Not classified yet: queue background classification and report
                // pending. The completed result is pushed to the browsers over the
                // hub, so the pill resolves without polling.
                queueVideoClassification(platformID: videoTags.platformID, items: [NativeVideoTagsBatchItem(
                    entryID: videoTags.entryID, creatorID: videoTags.creatorID,
                    title: videoTags.title, summary: videoTags.summary, text: videoTags.text)])
                return try sharedHubReply(NativeVideoTagsResponse(
                    platformID: videoTags.platformID, entryID: videoTags.entryID, tags: [], predicted: false, pending: true))
            case .videoTagsBatch:
                let batch = try JSONDecoder().decode(NativeVideoTagsBatchRequest.self, from: request.bodyData)
                try batch.validate()
                if Self.creatorEchoTestMode {
                    devLog("video-tags-batch", ["platform": batch.platformID, "items": "\(batch.items.count)", "outcome": "creator-echo"])
                    return try sharedHubReply(NativeVideoTagsBatchResponse(
                        platformID: batch.platformID,
                        items: batch.items.map { item in
                            NativeVideoTagsBatchResponseItem(
                                entryID: item.entryID,
                                tags: [Self.creatorEchoTag(creatorID: item.creatorID)],
                                predicted: false, pending: false)
                        }))
                }
                let platformHasTypes = coordinator.hasClassifierTypes(platformID: batch.platformID)
                var responses: [NativeVideoTagsBatchResponseItem] = []
                var pendingItems: [NativeVideoTagsBatchItem] = []
                var cachedCount = 0
                for item in batch.items {
                    if let cached = coordinator.cachedVideoTags(platformID: batch.platformID, entryID: item.entryID) {
                        cachedCount += 1
                        responses.append(NativeVideoTagsBatchResponseItem(
                            entryID: item.entryID, tags: Self.nativeVideoTags(from: cached.tags), predicted: cached.predicted, pending: false))
                    } else if !platformHasTypes {
                        // No classifier type for this platform → definitively empty.
                        responses.append(NativeVideoTagsBatchResponseItem(entryID: item.entryID, tags: [], predicted: false, pending: false))
                    } else {
                        responses.append(NativeVideoTagsBatchResponseItem(entryID: item.entryID, tags: [], predicted: false, pending: true))
                        pendingItems.append(item)
                    }
                }
                devLog("video-tags-batch", ["platform": batch.platformID, "items": "\(batch.items.count)", "cached": "\(cachedCount)", "pending": "\(pendingItems.count)", "hasTypes": platformHasTypes ? "1" : "0"])
                if !pendingItems.isEmpty {
                    queueVideoClassification(platformID: batch.platformID, items: pendingItems)
                }
                return try sharedHubReply(NativeVideoTagsBatchResponse(platformID: batch.platformID, items: responses))
            case .devLog:
                let entry = try JSONDecoder().decode(NativeDevLogRequest.self, from: request.bodyData)
                try entry.validate()
                VaultDevLog.shared.log(entry.layer, entry.event, entry.fields)
                return try sharedHubReply(NativeDevLogResponse(accepted: true))
            }
        } catch {
            collectionDiagnostics?.record(event: "request-rejected", outcome: "rejected")
            onWebStateChange?()
            return .failure(error.localizedDescription)
        }
    }

    private func cacheSourceIcon(from entry: EntryEvidence) {
        guard case .string(let iconURL)? = entry.evidence.metadata["sourceIconURL"],
              SourceIconURLPolicy.isAccepted(platformID: entry.platform, value: iconURL) else {
            return
        }
        cacheSourceIcon(remoteURL: iconURL)
    }

    private func cacheSourceIcon(remoteURL: String) {
        sourceIconCache?.cache(remoteURL: remoteURL) { [weak self] in
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

    func refreshLocalState() {
        localState = coordinator?.snapshot()
        reconcileProviderModelCatalogs()
    }

    private func llmProviderProfileIDs() -> Set<String> {
        Set(localState?.workspaceCatalog.providerProfiles.compactMap { profile in
            profile.type.supportsLLMConfiguration ? profile.id : nil
        } ?? [])
    }

    private func reconcileProviderModelCatalogs() {
        let allowedProfileIDs = llmProviderProfileIDs()
        let retainedCatalogs = providerModelCatalogs.filter { allowedProfileIDs.contains($0.key) }
        guard retainedCatalogs != providerModelCatalogs else { return }
        providerModelCatalogs = retainedCatalogs
        providerModelCatalogStore?.save(retainedCatalogs, allowedProfileIDs: allowedProfileIDs)
    }

    private func persistProviderModelCatalogs() {
        providerModelCatalogStore?.save(providerModelCatalogs, allowedProfileIDs: llmProviderProfileIDs())
    }

    func createProviderProfile(typeRaw: String) {
        do {
            guard let type = APIKeyProviderType(rawValue: typeRaw),
                  var catalog = localState?.workspaceCatalog else {
                throw WebBridgeInputError.invalidChoice("provider type")
            }
            let profile = APIKeyProviderProfile(type: type)
            catalog.providerProfiles.append(profile)
            try coordinator?.updateWorkspaceCatalog(catalog)
            refreshLocalState()
            issue = nil
        } catch { issue = error.localizedDescription }
    }

    /// A provider test is always an explicit user action. It sends either the
    /// fixed harmless language-model prompt or a bounded provider-specific
    /// platform health request or fixed raw-search query, never browser
    /// evidence or catalog data, and records no credential or headers.
    func testProviderProfile(
        profileID: String,
        rawCredential: String? = nil,
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
                let responseUsage = (try? ProviderTestProtocol.usage(
                    from: data,
                    format: request.plan.bodyFormat
                )) ?? .init(tokenCount: nil)
                let parsed: ProviderTestParsedResponse
                do {
                    parsed = try ProviderTestProtocol.parseResponse(data, format: request.plan.bodyFormat, operation: request.operation)
                } catch {
                    throw ProviderResponseParseFailure(
                        underlyingError: error,
                        statusCode: http.statusCode,
                        responseShape: ProviderTestProtocol.responseShape(for: data),
                        usage: responseUsage
                    )
                }
                try self.appendProviderTestRecord(.init(
                    profileID: profile.id,
                    provider: profile.type.rawValue,
                    model: ProviderTestProtocol.modelIdentifier(for: profile),
                    operation: request.operation.rawValue,
                    endpoint: ProviderTestProtocol.safeEndpoint(request.plan.url),
                    method: request.plan.method,
                    statusCode: http.statusCode,
                    durationMilliseconds: duration,
                    tokenCount: parsed.usage.tokenCount,
                    outcome: "succeeded"
                ))
                self.successfulProviderTestProfileIDs.insert(profileID)
                self.issue = nil
            } catch {
                let duration = max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
                if let prepared {
                    let failure = self.providerFailureMetadata(for: error)
                    try? self.appendProviderTestRecord(.init(
                        profileID: profile.id,
                        provider: profile.type.rawValue,
                        model: ProviderTestProtocol.modelIdentifier(for: profile),
                        operation: prepared.operation.rawValue,
                        endpoint: ProviderTestProtocol.safeEndpoint(prepared.plan.url),
                        method: prepared.plan.method,
                        statusCode: failure.statusCode,
                        responseShape: failure.responseShape,
                        durationMilliseconds: duration,
                        tokenCount: failure.tokenCount,
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

    /// A Probe explicitly refreshes one locally cached provider model list. A
    /// failed refresh deliberately preserves the last successful bounded list
    /// until a later successful Probe replaces it.
    private func fetchProviderModelCatalog(profileID: String) {
        guard !loadingProviderModelProfileIDs.contains(profileID) else { return }
        do {
            guard let profile = localState?.workspaceCatalog.providerProfiles.first(where: { $0.id == profileID }) else {
                throw WebBridgeInputError.invalidChoice("provider profile")
            }
            let plan = try ProviderModelCatalogProtocol.prepare(profile: profile)
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
                    var models = try ProviderModelCatalogProtocol.parse(response.data, providerType: profile.type)
                    if profile.type == .ollama {
                        models = await self.ollamaModelsWithCapabilities(
                            models,
                            profile: profile,
                            credential: credential
                        )
                    }
                    self.providerModelCatalogs[profileID] = models
                    self.persistProviderModelCatalogs()
                    self.issue = nil
                } catch {
                    self.providerModelCatalogErrors[profileID] = error.localizedDescription
                }
                self.loadingProviderModelProfileIDs.remove(profileID)
                self.onWebStateChange?()
            }
        } catch {
            providerModelCatalogErrors[profileID] = error.localizedDescription
            onWebStateChange?()
        }
    }

    private func ollamaModelsWithCapabilities(
        _ models: [ProviderModelCatalogEntry],
        profile: APIKeyProviderProfile,
        credential: ProviderCredentialRecord
    ) async -> [ProviderModelCatalogEntry] {
        var resolved = [ProviderModelCatalogEntry]()
        for model in models {
            guard let request = try? ProviderModelCatalogProtocol.prepareOllamaToolCapabilityProbe(
                profile: profile,
                modelIdentifier: model.identifier
            ) else {
                resolved.append(model)
                continue
            }
            guard let response = try? await performProviderRequest(
                plan: request.plan,
                body: request.body,
                credential: credential,
                timeout: 5
            ) else {
                resolved.append(model)
                continue
            }
            var updated = model
            updated.supportsTools = ProviderModelCatalogProtocol.ollamaModelSupportsTools(response.data)
            resolved.append(updated)
        }
        return resolved
    }

    func probeProviderModelCatalog(profileID: String) {
        guard let profile = localState?.workspaceCatalog.providerProfiles.first(where: { $0.id == profileID }),
              profile.type.supportsLLMConfiguration else {
            issue = WebBridgeInputError.invalidChoice("LLM provider profile").localizedDescription
            return
        }
        fetchProviderModelCatalog(profileID: profileID)
    }

    private func providerCredential(for profileID: String) throws -> ProviderCredentialRecord {
        guard let profile = localState?.workspaceCatalog.providerProfiles.first(where: { $0.id == profileID }) else {
            throw ProviderTestProtocolError.missingCredential
        }
        let descriptor = ProviderProtocolRegistry.descriptor(for: profile.type)
        guard !descriptor.credentialFields.isEmpty else { return .init(values: [:]) }
        let normalizedCredential = profile.credential?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard descriptor.credentialFields.count == 1,
              let field = descriptor.credentialFields.first,
              !normalizedCredential.isEmpty else {
            throw ProviderTestProtocolError.missingCredential
        }
        let value = normalizedCredential
        let credential = ProviderCredentialRecord(values: [field: value])
        try credential.validate(for: descriptor)
        return credential
    }

    private func providerFailureMetadata(
        for error: Error
    ) -> (statusCode: Int?, responseShape: String?, tokenCount: Int?) {
        if case let ProviderTestHTTPError.status(statusCode) = error {
            return (statusCode, nil, nil)
        }
        guard let failure = error as? ProviderResponseParseFailure else { return (nil, nil, nil) }
        return (failure.statusCode, failure.responseShape, failure.usage.tokenCount)
    }

    private struct ProviderResponseParseFailure: LocalizedError {
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

    /// Sends a bounded provider request used by explicit connection tests and
    /// model-catalog probes.
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
        // Keep every current-day classified request with known aggregate usage,
        // including a malformed 2xx response, so pruning cannot bypass the
        // configured daily budget.
        let todayStartMilliseconds = Int64(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 * 1_000)
        let budgetRecords = catalog.providerRequestRecords.filter {
            $0.classifierTypeID != nil &&
                $0.tokenCount != nil &&
                $0.createdAtMilliseconds >= todayStartMilliseconds
        }
        let budgetRecordIDs = Set(budgetRecords.map(\.id))
        let otherRecords = catalog.providerRequestRecords.filter { !budgetRecordIDs.contains($0.id) }
        catalog.providerRequestRecords = budgetRecords + Array(otherRecords.prefix(100))
        let isLanguageModel = APIKeyProviderType(rawValue: record.provider)
            .map { ProviderProtocolRegistry.descriptor(for: $0).supportsLLMConfiguration } ?? false
        if isLanguageModel, let tokenCount = record.tokenCount {
            catalog.tokenUsage.insert(.init(
                provider: record.provider,
                model: record.model,
                tokenCount: tokenCount,
                status: record.outcome
            ), at: 0)
            catalog.tokenUsage = Array(catalog.tokenUsage.prefix(200))
        }
        try coordinator?.updateWorkspaceCatalog(catalog)
        refreshLocalState()
    }

    /// Stores every compact provider connection field in the local workspace.
    /// API keys and tokens are ordinary visible text fields: an empty committed
    /// value clears the saved credential.
    private func applyProviderConnection(
        profileID: String,
        rawCredential: String?,
        customEndpoint: String?,
        testModelIdentifier: String?,
        protocolConfiguration: [String: String]?
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
        let descriptor = ProviderProtocolRegistry.descriptor(for: profile.type)
        if descriptor.credentialFields.isEmpty {
            profile.credential = nil
        } else if let rawCredential {
            let value = rawCredential.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty {
                profile.credential = nil
            } else {
                guard descriptor.credentialFields.count == 1,
                      let field = descriptor.credentialFields.first else {
                    throw WebBridgeInputError.invalidChoice("provider credential")
                }
                let credential = ProviderCredentialRecord(values: [field: value])
                try credential.validate(for: descriptor)
                profile.credential = credential.values[field]
            }
        }
        try profile.validate()
        profile.updatedAtMilliseconds = WorkspaceCatalog.now()
        catalog.providerProfiles[index] = profile
        try coordinator?.updateWorkspaceCatalog(catalog)
        refreshLocalState()
        return profile
    }

    func updateProviderConnection(
        profileID: String,
        rawCredential: String? = nil,
        customEndpoint: String?,
        testModelIdentifier: String?,
        protocolConfiguration: [String: String]?
    ) {
        successfulProviderTestProfileIDs.remove(profileID)
        do {
            _ = try applyProviderConnection(
                profileID: profileID,
                rawCredential: rawCredential,
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
            catalog.providerRequestRecords.removeAll(where: { $0.profileID == profileID })
            for index in catalog.classifierTypes.indices {
                guard let current = catalog.classifierTypes[index].researchOverrides else { continue }
                let updated = Self.researchSettings(current, removingProviderID: profileID)
                if updated != current {
                    catalog.classifierTypes[index].researchOverrides = updated
                    catalog.classifierTypes[index].updatedAtMilliseconds = WorkspaceCatalog.now()
                }
            }
            successfulProviderTestProfileIDs.remove(profileID)
            try coordinator?.updateWorkspaceCatalog(catalog)
            if let currentSettings = localState?.settings {
                let research = Self.researchSettings(
                    currentSettings.research,
                    removingProviderID: profileID
                )
                guard research != currentSettings.research else {
                    refreshLocalState()
                    issue = nil
                    return
                }
                try coordinator?.updateSettings(.init(
                    packageUpdateMode: currentSettings.packageUpdateMode,
                    localLLM: currentSettings.localLLM,
                    research: research
                ))
            }
            refreshLocalState()
            issue = nil
        } catch { issue = error.localizedDescription }
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
        if updated.webSearchProviderProfileID == profileID {
            updated.webSearchProviderProfileID = nil
        }
        return updated
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

    func createClassifierType(name: String, platformID: String) {
        do {
            let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty,
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
            catalog.classifierTypes.append(.init(
                name: cleaned,
                treeID: tree.id,
                treeRevision: tree.revision,
                datasetID: dataset.id,
                datasetRevision: dataset.revision,
                applicablePlatformID: platformID,
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
              let searchProfileID = settings.webSearchProviderProfileID,
              let modelIdentifier = settings.llmModelIdentifier,
              !modelIdentifier.isEmpty,
              let llmProfile = catalog.providerProfiles.first(where: { $0.id == llmProfileID }),
              let searchProfile = catalog.providerProfiles.first(where: { $0.id == searchProfileID }),
              ProviderGenerationProtocol.supportsGeneration(profile: llmProfile),
              searchProfile.type.supportsRawWebSearch else {
            throw WebBridgeInputError.invalidChoice("research providers and model")
        }
        _ = try researchCredential(for: llmProfile)
        _ = try researchCredential(for: searchProfile)
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
        confidenceThresholds: [Double]?
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
                confidenceThresholds: confidenceThresholds
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
        let overrides = LocalModelOverrides(
            houseRules: houseRules,
            allowDecline: data["allowDecline"] as? Bool,
            confidenceThresholds: rawThresholds.isEmpty ? nil : rawThresholds
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
                webSearchProviderProfileID: optionalString("webSearchProviderProfileID"),
                requestsPerMinute: optionalInteger("requestsPerMinute") ?? defaults.requestsPerMinute,
                dailyTokenLimit: optionalInteger("dailyTokenLimit") ?? defaults.dailyTokenLimit,
                maxSubjectsPerVideo: optionalInteger("maxSubjectsPerVideo") ?? defaults.maxSubjectsPerVideo,
                cooldownHours: optionalInteger("cooldownHours") ?? defaults.cooldownHours,
                trigger: (data["trigger"] as? String).flatMap(ResearchTrigger.init(rawValue:)) ?? defaults.trigger,
                confidenceTriggerLevel: optionalInteger("confidenceTriggerLevel") ?? defaults.confidenceTriggerLevel,
                searchResultCount: optionalInteger("searchResultCount") ?? defaults.searchResultCount,
                snippetContextChars: optionalInteger("snippetContextChars") ?? defaults.snippetContextChars,
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

    private func positiveInteger(_ raw: String, label: String) throws -> Int {
        let digits = raw.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(digits), value > 0 else { throw AppInputError.invalidNumber(label) }
        return value
    }

    private func nonnegativeInteger(_ raw: String, label: String) throws -> Int {
        let digits = raw.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(digits), value >= 0 else { throw AppInputError.invalidNumber(label) }
        return value
    }

    /// The WKWebView receives only the bounded local state necessary to render
    /// this development shell. Browser evidence, API keys, pairing material,
    /// stable identifiers stay in native storage.
    func webSnapshot() -> [String: Any] {
        let state = localState ?? coordinator?.snapshot()
        let backup = state?.backupConfiguration
        let notices: [String: Any] = [
            "backup": backupNotice ?? NSNull(),
        ]
        let catalog = state?.workspaceCatalog ?? .starter()
        let researchSettings = state?.settings.research ?? ResearchSettings()
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
        let availableModelFiles = VaultLocalLLMEngine.availableModelFiles()
        let settingsPayload: [String: Any] = [
            "packageUpdateMode": packageUpdateMode.rawValue,
            "localLLM": [
                    "modelFileName": llmSettings.modelFileName ?? "",
                    "engineEnabled": llmSettings.engineEnabled,
                    "contextTokens": llmSettings.contextTokens,
                    "batchTokens": llmSettings.batchTokens,
                    "gpuOffload": llmSettings.gpuOffload,
                    "maximumOutputTokens": llmSettings.maximumOutputTokens,
                    "temperature": llmSettings.temperature,
                    "allowDecline": llmSettings.allowDecline,
                    "maximumTags": llmSettings.maximumTags,
                    "confidenceThresholds": llmSettings.confidenceThresholds,
                    "houseRules": llmSettings.houseRules,
                    "maxResidentModels": llmSettings.maxResidentModels,
                    "engineStatus": llmEngineStatus,
                    "availableModels": availableModelFiles,
                    "modelLibrary": Self.modelLibraryPayload(
                        availableModelFiles: availableModelFiles,
                        downloadFractions: modelDownloadFractions,
                        systemRAMGB: HardwareProfile.physicalRAMGB()
                    ),
            ] as [String: Any],
            "research": [
                "enabled": researchSettings.enabled,
                "llmProviderProfileID": researchSettings.llmProviderProfileID ?? "",
                "llmModelIdentifier": researchSettings.llmModelIdentifier ?? "",
                "webSearchProviderProfileID": researchSettings.webSearchProviderProfileID ?? "",
                "requestsPerMinute": researchSettings.requestsPerMinute,
                "dailyTokenLimit": researchSettings.dailyTokenLimit,
                "maxSubjectsPerVideo": researchSettings.maxSubjectsPerVideo,
                "cooldownHours": researchSettings.cooldownHours,
                "trigger": researchSettings.trigger.rawValue,
                "confidenceTriggerLevel": researchSettings.confidenceTriggerLevel,
                "searchResultCount": researchSettings.searchResultCount,
                "snippetContextChars": researchSettings.snippetContextChars,
                "knowledgeTTLDays": researchSettings.knowledgeTTLDays,
                "maxKnowledgePerVideo": researchSettings.maxKnowledgePerVideo,
                "tokensUsedToday": GroundedResearchQueue.usedResearchTokens(in: catalog.tokenUsage, at: Date()),
            ] as [String: Any],
        ]
        let backupPayload: [String: Any] = [
            "hasOwnerCode": hasBackupOwnerCode,
            "unlocked": backupUnlocked,
            "enabled": backupEnabled,
            "directory": backupDirectory,
            "savedEnabled": backup?.isEnabled ?? false,
        ]
        var assets = [String: Any]()
        assets["trees"] = catalog.trees.map { tree in
                ["id": tree.id, "name": tree.name, "revision": tree.revision, "nodes": tree.nodes.enumerated().map { index, node -> [String: Any] in
                    let position = node.resolvedCanvasPosition(index: index)
                    return ["id": node.id, "name": node.name, "description": node.description ?? NSNull(), "parentID": node.parentID ?? NSNull(), "retired": node.isRetired, "lightColorHex": node.lightColorHex ?? NSNull(), "darkColorHex": node.darkColorHex ?? NSNull(), "positionX": position.x, "positionY": position.y]
                }] as [String: Any]
            }
        assets["datasets"] = catalog.datasets.map { dataset in
                [
                    "id": dataset.id,
                    "name": dataset.name,
                    "revision": dataset.revision,
                    "collectedCreators": webCollectedCreators(dataset.collectedEntries),
                ] as [String: Any]
            }
        assets["classifierTypes"] = catalog.classifierTypes.map { classifierType in
                return [
                    "id": classifierType.id,
                    "name": classifierType.name,
                    "order": classifierType.order,
                    "treeID": classifierType.treeID,
                    "treeRevision": classifierType.treeRevision,
                    "datasetID": classifierType.datasetID,
                    "datasetRevision": classifierType.datasetRevision,
                    "applicablePlatformID": classifierType.applicablePlatformID ?? NSNull(),
                    "localModelOverrides": classifierType.localModelOverrides.map { overrides in
                        [
                            "houseRules": overrides.houseRules ?? NSNull(),
                            "allowDecline": overrides.allowDecline ?? NSNull(),
                            "confidenceThresholds": overrides.confidenceThresholds ?? NSNull(),
                        ] as [String: Any]
                    } ?? NSNull(),
                    "modelFileName": classifierType.modelFileName ?? "",
                    "researchOverrides": classifierType.researchOverrides.map { research in
                        [
                            "enabled": research.enabled,
                            "llmProviderProfileID": research.llmProviderProfileID ?? "",
                            "llmModelIdentifier": research.llmModelIdentifier ?? "",
                            "webSearchProviderProfileID": research.webSearchProviderProfileID ?? "",
                            "requestsPerMinute": research.requestsPerMinute,
                            "dailyTokenLimit": research.dailyTokenLimit,
                            "maxSubjectsPerVideo": research.maxSubjectsPerVideo,
                            "cooldownHours": research.cooldownHours,
                            "trigger": research.trigger.rawValue,
                            "confidenceTriggerLevel": research.confidenceTriggerLevel,
                            "searchResultCount": research.searchResultCount,
                            "snippetContextChars": research.snippetContextChars,
                            "knowledgeTTLDays": research.knowledgeTTLDays,
                            "maxKnowledgePerVideo": research.maxKnowledgePerVideo,
                        ] as [String: Any]
                    } ?? NSNull(),
                ] as [String: Any]
            }
        assets["providerProfiles"] = catalog.providerProfiles.map { profile in
                let descriptor = ProviderProtocolRegistry.descriptor(for: profile.type)
                return [
                    "id": profile.id,
                    "name": profile.name,
                    "type": profile.type.rawValue,
                    "defaultModelIdentifier": profile.type.defaultModelIdentifier,
                    "customEndpoint": profile.customEndpoint ?? NSNull(),
                    "protocolConfiguration": profile.protocolConfiguration,
                    "testModelIdentifier": profile.testModelIdentifier ?? NSNull(),
                    "credential": profile.credential ?? "",
                    "hasCredential": !descriptor.credentialFields.isEmpty && profile.credential?.isEmpty == false,
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
                    "responseShape": record.responseShape ?? NSNull(),
                    "durationMilliseconds": record.durationMilliseconds,
                    "tokenCount": record.tokenCount ?? NSNull(),
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
                        "supportsGenerateText": ProviderGenerationProtocol.supportsGeneration(
                            profile: APIKeyProviderProfile(type: type)
                        ),
                        "supportsPlatformData": descriptor.requestFormats.contains(where: { $0.operation == .readPublicContent }),
                        "supportsNativeWebSearch": type.supportsProviderNativeWebSearch,
                        "supportsAttachedWebSearchTool": type.supportsAttachedWebSearchTool,
                        "supportsRawWebSearch": type.supportsRawWebSearch,
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
                return ["id": binding.id, "name": binding.name, "browser": binding.browser, "treeID": binding.treeID, "datasetID": binding.datasetID, "activeClassifierTypeID": binding.activeClassifierTypeID ?? NSNull(), "policyID": binding.policyID ?? NSNull(), "collectionEnabled": binding.collectionEnabled, "sourceKind": definition?.sourceKind.rawValue ?? CollectionSourceKind.creator.rawValue, "supportsLocalModel": definition?.supportsLocalModel ?? false] as [String: Any]
            }
        assets["collectionPlatforms"] = CollectionPlatformRegistry.definitions.map { definition in
                ["id": definition.id, "name": definition.name, "browser": definition.browser, "sourceKind": definition.sourceKind.rawValue, "collectorAvailable": definition.collectorAvailable, "supportsLocalModel": definition.supportsLocalModel, "apiProviderType": definition.apiProviderType?.rawValue ?? NSNull()] as [String: Any]
            }
        assets["providerModelCatalogs"] = providerModelCatalogs.mapValues { $0.map(\.identifier) }
        assets["providerModelCapabilities"] = providerModelCatalogs.mapValues { entries in
            Dictionary(uniqueKeysWithValues: entries.map { entry in
                (
                    entry.identifier,
                    [
                        "supportsTools": entry.supportsTools ?? NSNull(),
                        "supportsNativeWebSearch": entry.supportsNativeWebSearch ?? NSNull(),
                    ] as [String: Any]
                )
            })
        }
        assets["providerModelCatalogErrors"] = providerModelCatalogErrors
        assets["loadingProviderModelProfileIDs"] = Array(loadingProviderModelProfileIDs).sorted()
        // Collection diagnostics are recorded to the local
        // `collection-diagnostics.json` log only. They are deliberately not
        // included in the web snapshot, so they never reach the WebView state
        // or the browser bridge.
        return [
            "workspace": workspace.rawValue,
            "issue": issue ?? NSNull(),
            "notices": notices,
            "policies": policiesPayload,
            "settings": settingsPayload,
            "backup": backupPayload,
            "assets": assets,
            "trash": catalog.trash.map { entry in
                [
                    "id": entry.id,
                    "kind": entry.kind.rawValue,
                    "name": entry.name,
                    "deletedAtMilliseconds": entry.deletedAtMilliseconds,
                ] as [String: Any]
            },
        ]
    }

    static func modelLibraryPayload(
        availableModelFiles: [String],
        downloadFractions: [String: Double],
        systemRAMGB: Int
    ) -> [[String: Any]] {
        let downloaded = Set(availableModelFiles)
        let recommendedID = LocalModelCatalog.recommended(systemRAMGB: systemRAMGB)?.id
        return LocalModelCatalog.curated
            .sorted { lhs, rhs in
                lhs.downloadSizeBytes == rhs.downloadSizeBytes
                    ? lhs.displayName < rhs.displayName
                    : lhs.downloadSizeBytes < rhs.downloadSizeBytes
            }
            .map { entry in
                let state: [String: Any]
                if let fraction = downloadFractions[entry.id] {
                    state = [
                        "kind": "downloading",
                        "fraction": min(1, max(0, fraction)),
                    ]
                } else if downloaded.contains(entry.ggufFileName) {
                    state = ["kind": "downloaded"]
                } else {
                    state = ["kind": "available"]
                }
                return [
                    "id": entry.id,
                    "displayName": entry.displayName,
                    "family": entry.family,
                    "paramsB": entry.paramsB,
                    "repo": entry.repo,
                    "ggufFileName": entry.ggufFileName,
                    "downloadSizeBytes": entry.downloadSizeBytes,
                    "minimumRAMGB": entry.minimumRAMGB,
                    "downloadURL": (try? entry.downloadURL.absoluteString) ?? "",
                    // Latency is deliberately nil until this exact artifact is
                    // benchmarked on the current Mac. Model size is not a
                    // substitute for a measured decision time.
                    "latencyBand": NSNull(),
                    "recommended": entry.id == recommendedID,
                    "state": state,
                ] as [String: Any]
            }
    }

    /// The web renderer is a bundled local asset, but its messages are still
    /// treated as untrusted UI input. Keep the surface small and bounded so it
    /// cannot become another native IPC or provider-control path.
    /// Returns whether the web shell should publish a new snapshot.
    func performWebAction(_ action: String, data: [String: Any]) -> Bool {
        do {
            switch action {
            case "state":
                refreshLocalState()
            case "workspace":
                let selected = try webString(data, key: "workspace", limit: 32)
                guard let value = Workspace(rawValue: selected) else { throw WebBridgeInputError.invalidChoice("workspace") }
                workspace = value
                // The WebView already owns the current bounded snapshot and
                // switches workspaces optimistically. Avoid echoing the same
                // multi-megabyte state back across the bridge for navigation.
                return false
            case "createTree":
                createTree(name: try webString(data, key: "name", limit: 128))
            case "addCollectionPlatform":
                addCollectionPlatform(platformID: try webString(data, key: "platformID", limit: 64))
            case "confirmDeleteCollectionPlatform":
                deleteCollectionPlatform(platformID: try webString(data, key: "platformID", limit: 64))
            case "restoreTrashedEntry":
                restoreTrashedEntry(entryID: try webString(data, key: "id", limit: 64))
            case "permanentlyDeleteTrashedEntry":
                permanentlyDeleteTrashedEntry(entryID: try webString(data, key: "id", limit: 64))
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
            case "createClassifierType":
                createClassifierType(
                    name: try webString(data, key: "name", limit: ClassifierTypeAsset.maximumNameLength),
                    platformID: try webString(data, key: "platformID", limit: 64)
                )
            case "reorderClassifierTypes":
                reorderClassifierTypes(orderedIDs: try webStringArray(data, key: "orderedIDs", limit: 256, elementLimit: 256))
            case "configureClassifierType":
                configureClassifierType(
                    typeID: try webString(data, key: "typeID", limit: 256),
                    name: try webString(data, key: "name", limit: ClassifierTypeAsset.maximumNameLength),
                    applicablePlatformID: try webString(data, key: "applicablePlatformID", limit: 64)
                )
            case "confirmDeleteClassifierType":
                deleteClassifierType(typeID: try webString(data, key: "typeID", limit: 256))
            case "createProviderProfile":
                createProviderProfile(typeRaw: try webString(data, key: "type", limit: 32))
            case "testProviderProfile":
                testProviderProfile(
                    profileID: try webString(data, key: "profileID", limit: 128),
                    rawCredential: try webOptionalString(data, key: "credential", limit: ProviderCredentialRecord.maximumCharacters),
                    customEndpoint: try webOptionalString(data, key: "customEndpoint", limit: APIKeyProviderProfile.maximumEndpointLength),
                    testModelIdentifier: try webOptionalString(data, key: "testModelIdentifier", limit: APIKeyProviderProfile.maximumTestModelIdentifierLength),
                    protocolConfiguration: try webProviderConfiguration(data)
                )
            case "updateProviderConnection":
                updateProviderConnection(
                    profileID: try webString(data, key: "profileID", limit: 128),
                    rawCredential: try webOptionalString(data, key: "credential", limit: ProviderCredentialRecord.maximumCharacters),
                    customEndpoint: try webOptionalString(data, key: "customEndpoint", limit: APIKeyProviderProfile.maximumEndpointLength),
                    testModelIdentifier: try webOptionalString(data, key: "testModelIdentifier", limit: APIKeyProviderProfile.maximumTestModelIdentifierLength),
                    protocolConfiguration: try webProviderConfiguration(data)
                )
            case "probeProviderModelCatalog":
                probeProviderModelCatalog(profileID: try webString(data, key: "profileID", limit: 128))
            case "confirmDeleteProviderProfile":
                confirmProviderProfileDeletion(profileID: try webString(data, key: "profileID", limit: 128))
            case "renameTree":
                renameTree(treeID: try webString(data, key: "treeID", limit: 256), name: try webString(data, key: "name", limit: 128))
            case "deleteTree":
                deleteTree(treeID: try webString(data, key: "treeID", limit: 256))
            case "rearrangeTree":
                rearrangeTree(treeID: try webString(data, key: "treeID", limit: 256))
            case "addTag":
                addTag(
                    treeID: try webString(data, key: "treeID", limit: 256),
                    name: try webString(data, key: "name", limit: 128),
                    description: try webOptionalString(data, key: "description", limit: TagTreeNode.maximumDescriptionLength),
                    parentID: try webOptionalString(data, key: "parentID", limit: 256),
                    positionX: try webCanvasCoordinate(data, key: "positionX"),
                    positionY: try webCanvasCoordinate(data, key: "positionY")
                )
            case "moveTag":
                moveTag(treeID: try webString(data, key: "treeID", limit: 256), nodeID: try webString(data, key: "nodeID", limit: 256), positionX: try webCanvasCoordinate(data, key: "positionX"), positionY: try webCanvasCoordinate(data, key: "positionY"))
            case "renameTag":
                renameTag(treeID: try webString(data, key: "treeID", limit: 256), nodeID: try webString(data, key: "nodeID", limit: 256), name: try webString(data, key: "name", limit: 128), refreshState: false)
            case "updateTag":
                updateTag(
                    treeID: try webString(data, key: "treeID", limit: 256),
                    nodeID: try webString(data, key: "nodeID", limit: 256),
                    name: try webString(data, key: "name", limit: 128),
                    description: try webOptionalString(data, key: "description", limit: TagTreeNode.maximumDescriptionLength)
                )
            case "connectTag":
                connectTag(treeID: try webString(data, key: "treeID", limit: 256), nodeID: try webString(data, key: "nodeID", limit: 256), parentID: try webString(data, key: "parentID", limit: 256))
            case "disconnectTag":
                disconnectTag(treeID: try webString(data, key: "treeID", limit: 256), nodeID: try webString(data, key: "nodeID", limit: 256))
            case "deleteTag":
                deleteTag(treeID: try webString(data, key: "treeID", limit: 256), nodeID: try webString(data, key: "nodeID", limit: 256))
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
            case "savePackageSettings":
                let rawMode = try webString(data, key: "packageUpdateMode", limit: 32)
                guard let updateMode = PackageUpdateMode(rawValue: rawMode) else {
                    throw WebBridgeInputError.invalidChoice("package update mode")
                }
                packageUpdateMode = updateMode
                savePackageSettings()
            case "saveLocalLLMSettings":
                let thresholds = try ["confidenceBand2", "confidenceBand3", "confidenceBand4", "confidenceBand5"].map { key -> Double in
                    let raw = try webString(data, key: key, limit: 16)
                    guard let value = Double(raw), value > 0, value < 1 else {
                        throw WebBridgeInputError.invalidChoice("confidence threshold")
                    }
                    return value
                }
                let rawTemperature = try webString(data, key: "temperature", limit: 16)
                guard let temperature = Double(rawTemperature), temperature >= 0 else {
                    throw WebBridgeInputError.invalidChoice("temperature")
                }
                saveLocalLLMSettings(LocalLLMSettings(
                    modelFileName: try webString(data, key: "modelFileName", limit: 255),
                    engineEnabled: try webBool(data, key: "engineEnabled"),
                    contextTokens: try positiveInteger(try webString(data, key: "contextTokens", limit: 16), label: "Context tokens"),
                    batchTokens: try positiveInteger(try webString(data, key: "batchTokens", limit: 16), label: "Batch tokens"),
                    gpuOffload: try webBool(data, key: "gpuOffload"),
                    maximumOutputTokens: try positiveInteger(try webString(data, key: "maximumOutputTokens", limit: 16), label: "Output tokens"),
                    temperature: temperature,
                    allowDecline: try webBool(data, key: "allowDecline"),
                    maximumTags: try positiveInteger(try webString(data, key: "maximumTags", limit: 16), label: "Maximum tags"),
                    confidenceThresholds: thresholds,
                    houseRules: try webString(data, key: "houseRules", limit: 4_000),
                    maxResidentModels: try positiveInteger(
                        try webString(data, key: "maxResidentModels", limit: 16),
                        label: "Resident models"
                    )
                ))
            case "downloadModel":
                downloadModel(id: try webString(data, key: "id", limit: 128))
            case "cancelModelDownload":
                cancelModelDownload(id: try webString(data, key: "id", limit: 128))
            case "deleteModelFile":
                deleteModelFile(fileName: try webString(data, key: "fileName", limit: 255))
            case "saveResearchSettings":
                saveResearchSettings(ResearchSettings(
                    enabled: try webBool(data, key: "enabled"),
                    llmProviderProfileID: try webOptionalString(data, key: "llmProviderProfileID", limit: 256),
                    llmModelIdentifier: try webOptionalString(data, key: "llmModelIdentifier", limit: 256),
                    webSearchProviderProfileID: try webOptionalString(data, key: "webSearchProviderProfileID", limit: 256),
                    requestsPerMinute: try positiveInteger(
                        try webString(data, key: "requestsPerMinute", limit: 16),
                        label: "Research requests per minute"
                    ),
                    dailyTokenLimit: try positiveInteger(
                        try webString(data, key: "dailyTokenLimit", limit: 16),
                        label: "Research daily token limit"
                    ),
                    maxSubjectsPerVideo: try positiveInteger(
                        try webString(data, key: "maxSubjectsPerVideo", limit: 16),
                        label: "Research subjects per video"
                    ),
                    cooldownHours: try positiveInteger(
                        try webString(data, key: "cooldownHours", limit: 16),
                        label: "Research cooldown hours"
                    ),
                    trigger: try {
                        let raw = try webString(data, key: "trigger", limit: 64)
                        guard let value = ResearchTrigger(rawValue: raw) else {
                            throw WebBridgeInputError.invalidChoice("research trigger")
                        }
                        return value
                    }(),
                    confidenceTriggerLevel: try positiveInteger(
                        try webString(data, key: "confidenceTriggerLevel", limit: 16),
                        label: "Research confidence trigger"
                    ),
                    searchResultCount: try positiveInteger(
                        try webString(data, key: "searchResultCount", limit: 16),
                        label: "Research search results"
                    ),
                    snippetContextChars: try positiveInteger(
                        try webString(data, key: "snippetContextChars", limit: 16),
                        label: "Research snippet context"
                    ),
                    knowledgeTTLDays: try nonnegativeInteger(
                        try webString(data, key: "knowledgeTTLDays", limit: 16),
                        label: "Research knowledge TTL"
                    ),
                    maxKnowledgePerVideo: try positiveInteger(
                        try webString(data, key: "maxKnowledgePerVideo", limit: 16),
                        label: "Research knowledge per video"
                    )
                ))
            case "submitCorrection":
                submitCorrection(
                    classifierTypeID: try webString(data, key: "typeID", limit: 256),
                    platformID: try webString(data, key: "platformID", limit: 64),
                    entryID: try webString(data, key: "entryID", limit: 256),
                    correctTagIDs: try webStringArray(
                        data,
                        key: "correctTagIDs",
                        limit: CorrectionExample.maximumTagIDs,
                        elementLimit: 256
                    ),
                    note: try webOptionalString(data, key: "note", limit: CorrectionExample.maximumNoteLength)
                )
            case "saveClassifierTypeLocalModel":
                let input = try Self.parseClassifierTypeLocalModelWebInput(data)
                saveClassifierTypeLocalModel(
                    typeID: input.typeID,
                    overrideEnabled: input.overrideEnabled,
                    modelFileName: input.modelFileName,
                    houseRules: input.overrides?.houseRules,
                    allowDecline: input.overrides?.allowDecline,
                    confidenceThresholds: input.overrides?.confidenceThresholds
                )
            case "saveClassifierTypeResearch":
                let input = try Self.parseClassifierTypeResearchWebInput(data)
                saveClassifierTypeResearch(
                    typeID: input.typeID,
                    overrideEnabled: input.overrideEnabled,
                    settings: input.settings
                )
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
            default:
                throw WebBridgeInputError.invalidChoice("action")
            }
        } catch {
            issue = error.localizedDescription
        }
        return true
    }

    /// The primary (creator-level) list carried in every snapshot: one row per
    /// (platform, creator) with only the fields the master lists and creator
    /// cards render. The heavy per-entry body is intentionally excluded and
    /// served lazily by `webCreatorEntriesPayload` when a creator is chosen, so
    /// the collected corpus never rides along on unrelated state updates.
    private func webCollectedCreators(_ entries: [CollectedPlatformEntry]) -> [[String: Any]] {
        struct Aggregate {
            var platformID: String
            var creatorID: String
            var creatorName: String
            var entryCount: Int
            var firstObserved: Int64
            var lastObserved: Int64
            var iconURL: String?
            var subscriberCount: String?
            var latestObservedForFields: Int64
        }
        // Collapse a creator's observed identity forms (e.g. @handle + channel)
        // into one canonical row so the same creator never appears twice.
        let identityIndex = CreatorIdentityIndex(entries: entries)
        var order: [String] = []
        var groups: [String: Aggregate] = [:]
        for entry in entries {
            let canonicalCreatorID = identityIndex.canonical(of: entry.creatorID)
            let key = "\(entry.platformID)\u{1F}\(canonicalCreatorID)"
            let icon = entry.sourceIconURL.flatMap { sourceIconCache?.cachedURL(for: $0)?.absoluteString }
            let subscriber = entry.attributes["subscriberCount"]
            if var aggregate = groups[key] {
                aggregate.entryCount += 1
                aggregate.firstObserved = min(aggregate.firstObserved, entry.firstObservedAtMilliseconds)
                aggregate.lastObserved = max(aggregate.lastObserved, entry.lastObservedAtMilliseconds)
                // Display name/icon/subscriber follow the most recently observed
                // entry; an older observation only fills a still-missing icon.
                if entry.lastObservedAtMilliseconds >= aggregate.latestObservedForFields {
                    aggregate.latestObservedForFields = entry.lastObservedAtMilliseconds
                    aggregate.creatorName = entry.creatorName
                    if let icon { aggregate.iconURL = icon }
                    if let subscriber { aggregate.subscriberCount = subscriber }
                } else if aggregate.iconURL == nil, let icon {
                    aggregate.iconURL = icon
                }
                groups[key] = aggregate
            } else {
                order.append(key)
                groups[key] = Aggregate(
                    platformID: entry.platformID,
                    creatorID: canonicalCreatorID,
                    creatorName: entry.creatorName,
                    entryCount: 1,
                    firstObserved: entry.firstObservedAtMilliseconds,
                    lastObserved: entry.lastObservedAtMilliseconds,
                    iconURL: icon,
                    subscriberCount: subscriber,
                    latestObservedForFields: entry.lastObservedAtMilliseconds
                )
            }
        }
        return order.compactMap { key in
            guard let aggregate = groups[key] else { return nil }
            return [
                "platformID": aggregate.platformID,
                "creatorID": aggregate.creatorID,
                "creatorName": aggregate.creatorName,
                "entryCount": aggregate.entryCount,
                "firstObservedAtMilliseconds": aggregate.firstObserved,
                "lastObservedAtMilliseconds": aggregate.lastObserved,
                "cachedSourceIconURL": aggregate.iconURL ?? NSNull(),
                "subscriberCount": aggregate.subscriberCount ?? NSNull(),
            ]
        }
    }

    /// The full per-entry projection, delivered for one chosen creator only.
    private func webCollectedEntry(_ entry: CollectedPlatformEntry, catalog: WorkspaceCatalog) -> [String: Any] {
        let correctionForms = catalog.classifierTypes
            .filter { $0.applicablePlatformID == entry.platformID }
            .sorted { ($0.order, $0.id) < ($1.order, $1.id) }
            .compactMap { type -> [String: Any]? in
                guard let tree = catalog.trees.first(where: {
                    $0.id == type.treeID && $0.revision == type.treeRevision
                }), let taxonomy = try? tree.inferenceTaxonomy() else { return nil }
                let correction = catalog.correctionExamples.first {
                    $0.classifierTypeID == type.id && $0.platformID == entry.platformID &&
                        $0.entryID == entry.entryID
                }
                let classification = catalog.videoClassification(
                    classifierTypeID: type.id,
                    platformID: entry.platformID,
                    entryID: entry.entryID
                )
                return [
                    "typeID": type.id,
                    "typeName": type.name,
                    "tagOptions": taxonomy.nodes.values
                        .filter(\.predictable)
                        .sorted { ($0.name, $0.id) < ($1.name, $1.id) }
                        .map { ["id": $0.id, "name": $0.name] },
                    "correctTagIDs": correction?.correctTagIDs ?? classification?.tags.map(\.tagID) ?? [],
                    "note": correction?.note ?? "",
                    "corrected": correction != nil,
                ] as [String: Any]
            }
        return [
            "id": entry.id,
            "platformID": entry.platformID,
            "entryID": entry.entryID,
            "creatorID": entry.creatorID,
            "creatorName": entry.creatorName,
            "entryType": entry.entryType,
            "title": entry.title,
            "surface": entry.surface.rawValue,
            "text": entry.text ?? NSNull(),
            "summary": entry.summary ?? NSNull(),
            "suppliedTags": entry.suppliedTags,
            "canonicalURL": entry.canonicalURL ?? NSNull(),
            "attributes": entry.attributes,
            "cachedSourceIconURL": entry.sourceIconURL.flatMap {
                sourceIconCache?.cachedURL(for: $0)?.absoluteString
            } ?? NSNull(),
            "firstObservedAtMilliseconds": entry.firstObservedAtMilliseconds,
            "lastObservedAtMilliseconds": entry.lastObservedAtMilliseconds,
            "observationCount": entry.observationCount,
            "correctionForms": correctionForms,
        ]
    }

    /// Serves the full entries for one chosen creator, in response to a bounded
    /// `loadCreatorEntries` web action. Delivered on its own targeted channel so
    /// choosing a creator never re-pushes or re-renders the whole snapshot.
    func webCreatorEntriesPayload(datasetID: String, platformID: String, creatorID: String) -> [String: Any]? {
        let catalog = (localState ?? coordinator?.snapshot())?.workspaceCatalog
        guard let catalog,
              let dataset = catalog.datasets.first(where: { $0.id == datasetID }) else { return nil }
        // The selected creator is a canonical identity; return the entries of
        // every form in its class so a merged creator shows all its content.
        let identityClass = CreatorIdentityIndex(entries: dataset.collectedEntries).members(of: creatorID)
        let entries = dataset.collectedEntries
            .filter { $0.platformID == platformID && identityClass.contains($0.creatorID) }
            .map { webCollectedEntry($0, catalog: catalog) }
        return [
            "datasetID": datasetID,
            "platformID": platformID,
            "creatorID": creatorID,
            "entries": entries,
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
    case backupLocked

    var errorDescription: String? {
        switch self {
        case .invalidNumber(let label): return "\(label) must be a positive whole number."
        case .backupLocked: return "Enter the local backup owner code before changing backup mode."
        }
    }
}

private enum ProviderTestHTTPError: Error, LocalizedError {
    case status(Int)

    var errorDescription: String? {
        switch self {
        case .status(let status): return "The provider returned HTTP \(status)."
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
