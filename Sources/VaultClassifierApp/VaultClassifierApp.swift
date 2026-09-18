import AppKit
import Combine
import VaultClassifierCore
import VaultClassifierResearch
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
    @Published var hasBackupOwnerCode = false
    @Published var backupUnlocked = false
    @Published var backupNotice: String?
    /// Web actions normally receive a synchronous state refresh. Native sheets
    /// complete later, so they explicitly use this bounded local callback.
    var onWebStateChange: (() -> Void)?

    var coordinator: LocalClassifierCoordinator?
    var groundedResearchQueue: GroundedResearchQueue?
    @Published var researchQueueStatus = GroundedResearchQueueStatus()
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
            let vaultDirectory = try VaultClassifierDirectory.prepare()
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
    func installLocalLLMEngine(coordinator: LocalClassifierCoordinator) {
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
