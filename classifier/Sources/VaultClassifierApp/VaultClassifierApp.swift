import Foundation
#if canImport(AppKit)
import AppKit
#endif
#if canImport(Combine)
import Combine
#endif
import VaultClassifierCore
import VaultClassifierResearch
import VaultClassifierBridge
import VaultClassifierLLM

@MainActor
final class VaultClassifierViewModel: ObservableObject {
    /// A group's concrete dial positions and house rules from the web form.
    struct ClassifierTypeLocalModelWebInput: Equatable {
        var typeID: String
        var settings: LocalLLMSettings
    }
    /// A type's research switch from the web form (nil = follow the global switch).
    struct ClassifierTypeResearchWebInput: Equatable {
        var typeID: String
        var researchEnabled: Bool?
    }
    enum Workspace: String, CaseIterable, Identifiable, Hashable {
        case browserBridge
        case knowledge

        var id: String { rawValue }
    }

    @Published var workspace: Workspace = .browserBridge
    @Published var issue: String?
    @Published var localState: LocalClassifierState?
    @Published private(set) var modelEngineStatuses: [String: String] = [:]
    @Published var backupOwnerCode = ""
    @Published var backupDirectory = ""
    @Published var backupEnabled = false
    @Published var hasBackupOwnerCode = false
    @Published var backupUnlocked = false
    @Published var backupNotice: String?
    /// Knowledge → add term: confirms a queued lookup (the entry appears when it lands).
    @Published var knowledgeNotice: String?
    /// Web actions normally receive a synchronous state refresh. Native sheets
    /// complete later, so they explicitly use this bounded local callback.
    var onWebStateChange: (() -> Void)?

    var coordinator: LocalClassifierCoordinator?
    var groundedResearchQueue: GroundedResearchQueue?
    var dictionaryService: OfficialDictionaryService?
    @Published var dictionaryStatus: [String: Any] = [:]
    @Published var dictionaryBusy = false
    @Published var dictionaryNotice: String?
    @Published var personalDictionaryJSON: String?
    var contributionPromptNative = false
    @Published var researchQueueStatus = GroundedResearchQueueStatus()
    var sharedHubClient: SharedHubClient?
    var collectionDiagnostics: CollectionDiagnosticsStore?
    var providerModelCatalogStore: ProviderModelCatalogStore?
    private(set) var sourceIconCache: SourceIconCache?
    private(set) var creatorPictures: CreatorPictureStore?
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
            let vaultDirectory = try VaultClassifierDirectory.prepare()
            let package = try SeedPackageLoader.bundled()
            let collectionDiagnostics = CollectionDiagnosticsStore(fileURL: vaultDirectory.appendingPathComponent("collection-diagnostics.json"))
            self.collectionDiagnostics = collectionDiagnostics
            self.sourceIconCache = SourceIconCache(
                directory: vaultDirectory.appendingPathComponent("source-icons", isDirectory: true),
                retiredDirectory: vaultDirectory.appendingPathComponent("creator-avatars", isDirectory: true)
            )
            self.creatorPictures = CreatorPictureStore(directory: vaultDirectory.appendingPathComponent("creator-pictures", isDirectory: true))
            collectionDiagnostics.record(event: "app-started", outcome: "ready")
            let coordinator = try LocalClassifierCoordinator(verifiedPackage: package, stateFile: LocalStateFile(url: vaultDirectory.appendingPathComponent("state.json")))
            self.coordinator = coordinator
            self.localState = coordinator.snapshot()
            let providerModelCatalogStore = ProviderModelCatalogStore(fileURL: vaultDirectory.appendingPathComponent("provider-model-catalogs.json"))
            self.providerModelCatalogStore = providerModelCatalogStore
            self.providerModelCatalogs = providerModelCatalogStore.load(allowedProfileIDs: llmProviderProfileIDs())
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
            try installDictionaries(directory: vaultDirectory, coordinator: coordinator, automaticallyCheck: true)
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
        self.creatorPictures = CreatorPictureStore(directory: vaultDirectory.appendingPathComponent("creator-pictures", isDirectory: true))
        let coordinator = try LocalClassifierCoordinator(verifiedPackage: package, stateFile: LocalStateFile(url: vaultDirectory.appendingPathComponent("state.json")))
        self.coordinator = coordinator
        self.localState = coordinator.snapshot()
        let providerModelCatalogStore = ProviderModelCatalogStore(fileURL: vaultDirectory.appendingPathComponent("provider-model-catalogs.json"))
        self.providerModelCatalogStore = providerModelCatalogStore
        self.providerModelCatalogs = providerModelCatalogStore.load(allowedProfileIDs: llmProviderProfileIDs())
        loadBackupConfiguration(from: coordinator.snapshot().backupConfiguration)
        coordinator.setOnDeviceLLM(StubOnDeviceLLM())
        try installDictionaries(directory: vaultDirectory, coordinator: coordinator, automaticallyCheck: false)
    }

    /// Each group's selected model loads lazily through the shared registry.
    /// Missing model files produce provisional stub results, never another group's tier.
    func installLocalLLMEngine(coordinator: LocalClassifierCoordinator) {
        coordinator.setOnDeviceLLM(StubOnDeviceLLM())
        let registry = LocalLLMEngineRegistry { [weak self] fileName, status in
            Task { @MainActor [weak self] in
                guard let self, self.modelEngineStatuses[fileName] != status else { return }
                self.modelEngineStatuses[fileName] = status
                self.onWebStateChange?()
            }
        }
        coordinator.setOnDeviceLLMEngineResolver(registry)
        var seen = Set<SpeedQualityDial>()
        let configurations = coordinator.snapshot().workspaceCatalog.classifierTypes
            .map(\.localModel).filter { seen.insert($0.speedQuality).inserted }
            .prefix(LocalLLMSettings.maxResidentModels)
        // Keep the normal first-video path warm without choosing an app-wide tier.
        Task.detached(priority: .userInitiated) {
            for configuration in configurations {
                _ = try? await registry.engine(forModel: configuration.modelFileName, configuration: configuration)
            }
        }
    }

    // Dev-only instrumentation, routed into the unified VaultDevLog file.
    static let perfEnabled = VaultDevLog.shared.isEnabled
    /// Classifications currently running, keyed by platform + entryID. Repeated
    /// pending requests for a video already on the serial LLM queue must not
    /// enqueue duplicate work — without this, every provisional re-request
    /// multiplied the queue and starved the tail of the viewport.
    var inFlightVideoClassifications = Set<String>()

    /// The coalescing queue at the engine boundary (see ClassificationCoalescer):
    /// requests that arrive while the engine is busy wait and are drained
    /// together, up to `classificationChunkSize` per pass, instead of each
    /// running alone. When idle, the first arrival waits a short window so the
    /// rest of the screen can join it before the engine starts.
    lazy var classificationCoalescer: ClassificationCoalescer<NativeVideoTagsBatchItem> = {
        let coalescer = ClassificationCoalescer<NativeVideoTagsBatchItem>(
            chunkSize: Self.classificationChunkSize,
            arrivalWindowNanoseconds: Self.classificationArrivalWindowNanoseconds
        ) { [weak self] platformID, chunk in
            await self?.classifyChunk(platformID: platformID, chunk)
        }
        coalescer.onIdle = { [weak self] in self?.onWebStateChange?() }
        return coalescer
    }()

    /// Queue background classification for videos with no cached decision,
    /// skipping any already in flight. Each completed video is broadcast through
    /// the hub so provisional pills resolve the moment the result exists,
    /// instead of waiting for the extension's next poll.
    /// Videos handed to the engine together — its parallel-sequence capacity.
    static let classificationChunkSize = 16

    /// How long an idle engine waits for the rest of a screenful before it
    /// starts (a lone video pays this in full). `VAULT_ARRIVAL_WINDOW_MS`
    /// overrides it for latency measurements.
    static let classificationArrivalWindowNanoseconds: UInt64 = {
        let override = ProcessInfo.processInfo.environment["VAULT_ARRIVAL_WINDOW_MS"].flatMap(UInt64.init)
        return (override ?? 75) * 1_000_000
    }()

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
        let previous = localState
        localState = coordinator?.snapshot()
        reconcileProviderModelCatalogs()
        if Self.browserStateChanged(from: previous, to: localState) {
            sharedHubClient?.broadcast(operation: SharedBrowserBridgeOperation.classifierStateUpdatedBroadcast, body: [:] as [String: String])
        }
    }

    // Refresh browser projections and covers without invalidating stored decisions.
    static func browserStateChanged(from previous: LocalClassifierState?, to current: LocalClassifierState?) -> Bool {
        let activation: (LocalClassifierState?) -> [String] = { state in
            (state?.workspaceCatalog.classifierTypes ?? []).map {
                "\($0.id):\($0.treeID):\($0.treeRevision):\($0.isPaused):\($0.applicablePlatformIDs.joined(separator: ","))"
            }.sorted()
        }
        let recording: (LocalClassifierState?) -> [String] = { state in
            (state?.workspaceCatalog.bindings ?? []).filter(\.collectionEnabled).map(\.id).sorted()
        }
        let taxonomy: (LocalClassifierState?) -> [TagTreeAsset] = { state in
            (state?.workspaceCatalog.trees ?? []).map { tree in
                var tree = tree
                tree.updatedAtMilliseconds = 0
                tree.nodes = tree.nodes.map { node in
                    var node = node
                    node.positionX = nil
                    node.positionY = nil
                    return node
                }
                return tree
            }
        }
        return previous?.settings.classificationEnabled != current?.settings.classificationEnabled
            || activation(previous) != activation(current)
            || recording(previous) != recording(current)
            || taxonomy(previous) != taxonomy(current)
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

}

enum AppInputError: Error, LocalizedError {
    case invalidNumber(String)
    case invalidNonnegativeNumber(String)
    case invalidDecimal(String)
    case backupLocked

    var errorDescription: String? {
        switch self {
        case .invalidNumber(let label): return "\(label) must be a positive whole number."
        case .invalidNonnegativeNumber(let label): return "\(label) must be a whole number of 0 or more."
        case .invalidDecimal(let label): return "\(label) must be a positive number."
        case .backupLocked: return "Enter the local backup owner code before changing backup mode."
        }
    }
}

enum WebBridgeInputError: Error, LocalizedError {
    case missingValue(String)
    case exceedsLimit(String, Int)
    case invalidChoice(String)
    case fixedPlatforms
    case noPlatformsSelected

    private static func label(for field: String) -> String {
        let labels = [
            "name": "the name", "houseRules": "tagging instructions",
            "speedQuality": "Speed ↔ Quality", "strictness": "Strict ↔ Broad",
            "researchMode": "research for this group", "minimumTags": "minimum tags",
            "maximumTags": "maximum tags", "minimumTagsOverride": "minimum tags",
            "maximumTagsOverride": "maximum tags",
            "minimum tags greater than maximum tags": "tag counts (minimum must not exceed maximum)",
            "typeID": "the Classifier group",
            "treeID": "the tag tree", "nodeID": "the tag", "parentID": "the parent tag",
            "profileID": "the provider", "platformID": "the platform", "platformIDs": "platforms",
            "llmProfileID": "the research provider", "llmModelIdentifier": "the research model",
            "research providers and model": "the research provider and model",
            "grounding-capable provider": "a research provider with built-in web search",
            "modelIdentifier": "the model", "testModelIdentifier": "the test model",
            "credential": "provider credentials", "customEndpoint": "the endpoint",
            "meaning": "the description", "subject": "the subject", "creator": "the content source",
            "collection platform": "the platform", "collection keep": "history retention",
            "directory": "the folder", "ownerCode": "the backup owner code",
            "canvas coordinate": "the tag position", "action": "this action",
        ]
        return labels[field] ?? "this setting"
    }

    var errorDescription: String? {
        switch self {
        case .missingValue(let field): return "Check \(Self.label(for: field)) and try again."
        case .exceedsLimit(let field, let limit): return "Use at most \(limit) characters for \(Self.label(for: field))."
        case .invalidChoice(let field): return "Choose a supported value for \(Self.label(for: field))."
        case .fixedPlatforms: return "Platforms cannot be changed after the group is created."
        case .noPlatformsSelected: return "Select at least one platform."
        }
    }
}
