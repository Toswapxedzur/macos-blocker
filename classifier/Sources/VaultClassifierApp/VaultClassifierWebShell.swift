import AppKit
import Foundation
import VaultClassifierCore
import WebKit

/// The development shell is deliberately a bundled local WebKit document.
/// AppKit owns the native window; every visible control and layout is rendered
/// by the local HTML/CSS/JS asset below.
final class VaultClassifierWebShell {
    /// WebView actions carry only a small bounded dictionary. Every live field
    /// is also parsed and bounded individually by `performWebAction`.
    static let maximumWebActionDataFields = 24

    private let model: VaultClassifierViewModel
    private let coordinator: Coordinator
    private let sourceIconSchemeHandler: SourceIconSchemeHandler

    @MainActor
    init(model: VaultClassifierViewModel) {
        self.model = model
        self.coordinator = Coordinator(model: model)
        self.sourceIconSchemeHandler = SourceIconSchemeHandler(cache: model.sourceIconCache)
        Task { @MainActor [weak coordinator] in
            model.onWebStateChange = { [weak coordinator] in
                Task { @MainActor in coordinator?.sendState() }
            }
        }
    }

    func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(sourceIconSchemeHandler, forURLScheme: SourceIconCache.scheme)
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(coordinator, name: Coordinator.messageHandlerName)

        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = coordinator
        view.allowsBackForwardNavigationGestures = false
        coordinator.webView = view

        guard let index = Self.bundledWebAssetURL(named: "index", extension: "html") else {
            preconditionFailure("Vault Classifier web shell is missing its bundled index.html resource.")
        }
        view.loadFileURL(index, allowingReadAccessTo: index.deletingLastPathComponent())
        return view
    }

    deinit {
        coordinator.webView?.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.messageHandlerName)
        coordinator.webView?.navigationDelegate = nil
    }

    /// The host tells the shell whether its page is in front. While it is not,
    /// no snapshot is built or pushed; the newest state lands when it returns.
    @MainActor
    func setPresentationVisible(_ visible: Bool) {
        coordinator.setHostShowsPage(visible)
    }

    /// Builds a data-only native-to-WebKit update. `atob` returns a binary
    /// string, so decode its bytes as UTF-8 before parsing JSON; otherwise
    /// curly quotes and other non-ASCII collected metadata render garbled.
    static func stateUpdateJavaScript(
        payload: [String: Any],
        presentationRevision: UInt64? = nil
    ) -> String? {
        var deliveredPayload = payload
        if let presentationRevision {
            deliveredPayload["presentationRevision"] = presentationRevision
        }
        guard JSONSerialization.isValidJSONObject(deliveredPayload),
              let data = try? JSONSerialization.data(withJSONObject: deliveredPayload, options: [.sortedKeys]) else {
            return nil
        }
        let encoded = data.base64EncodedString()
        return "window.VaultClassifier && window.VaultClassifier.receive(JSON.parse(new TextDecoder().decode(Uint8Array.from(atob('\(encoded)'), value => value.charCodeAt(0)))));"
    }

    /// Targeted delivery of one chosen creator's entries. Same binary-safe
    /// decode as `stateUpdateJavaScript`, but routed to `receiveCreatorEntries`
    /// so it patches only the open detail pane instead of the whole snapshot.
    static func creatorEntriesJavaScript(payload: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return nil
        }
        let encoded = data.base64EncodedString()
        return "window.VaultClassifier && window.VaultClassifier.receiveCreatorEntries && window.VaultClassifier.receiveCreatorEntries(JSON.parse(new TextDecoder().decode(Uint8Array.from(atob('\(encoded)'), value => value.charCodeAt(0)))));"
    }

    static func bundledWebAssetURL(named name: String, extension fileExtension: String) -> URL? {
        Bundle.module.url(forResource: name, withExtension: fileExtension, subdirectory: "WebAssets")
    }

    private final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        static let messageHandlerName = "vaultClassifier"
        private static let layoutLogger = TagTreeLayoutLogger()

        let model: VaultClassifierViewModel
        weak var webView: WKWebView?
        /// Whether the host currently shows this page (Mac Vault hides it behind
        /// its other scenes). Standalone/test contexts never hide it.
        private var hostShowsPage = true
        private var occlusionObserver: NSObjectProtocol?
        private lazy var stateDelivery = LatestWebStateDelivery(
            schedule: { action in
                // Visual state is intentionally slower than authoritative
                // model mutation. A short batching window coalesces collector
                // bursts while keeping direct controls perceptually current.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: action)
            },
            makeScript: { [weak self] revision in
                guard let self else { return nil }
                let tStart = DispatchTime.now()
                let payload = self.model.webSnapshot()
                let tBuilt = DispatchTime.now()
                Self.layoutLogger.recordNativeSnapshot(payload)
                let script = VaultClassifierWebShell.stateUpdateJavaScript(
                    payload: payload,
                    presentationRevision: revision
                )
                if ProcessInfo.processInfo.environment["VAULT_DECODE_TIMING"] == "1" {
                    FileHandle.standardError.write(Data(String(format: "[web-snapshot] build=%.0fms serialize=%.0fms bytes=%d\n",
                        Double(tBuilt.uptimeNanoseconds - tStart.uptimeNanoseconds) / 1_000_000,
                        Double(DispatchTime.now().uptimeNanoseconds - tBuilt.uptimeNanoseconds) / 1_000_000, script?.utf8.count ?? 0).utf8))
                }
                return script
            },
            evaluate: { [weak self] script, completion in
                guard let webView = self?.webView else {
                    completion()
                    return
                }
                webView.evaluateJavaScript(script) { _, _ in completion() }
            }
        )

        init(model: VaultClassifierViewModel) {
            self.model = model
            super.init()
            // A closed, minimised or fully covered window is as invisible as a
            // hidden scene; resume delivery when it can be seen again.
            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main
            ) { [weak self] note in
                guard let self, let window = note.object as? NSWindow, window == self.webView?.window else { return }
                self.updatePresentationSuspension()
            }
        }

        deinit {
            if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        }

        @MainActor
        func setHostShowsPage(_ shows: Bool) {
            hostShowsPage = shows
            updatePresentationSuspension()
        }

        @MainActor
        private func updatePresentationSuspension() {
            let windowVisible = webView?.window.map { $0.occlusionState.contains(.visible) } ?? true
            stateDelivery.setSuspended(!(hostShowsPage && windowVisible))
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            // Keep the envelope small; the view model still validates every
            // individual value for the selected action.
            guard message.name == Self.messageHandlerName,
                  let envelope = message.body as? [String: Any],
                  envelope.count <= 2,
                  let action = envelope["action"] as? String,
                  action.count <= 64,
                  let data = envelope["data"] as? [String: Any],
                  data.count <= VaultClassifierWebShell.maximumWebActionDataFields else {
                return
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if action == "layoutTrace" {
                    Self.layoutLogger.recordWebTrace(data)
                    return
                }
                // Host navigation (the Vault/Classifier/Activity switch in the
                // header). The classifier stays host-agnostic: it just forwards
                // the requested scene name to whatever host installed the hook.
                if action == "switch-scene" {
                    if let scene = data["scene"] as? String, scene.count <= 32 {
                        VaultClassifierPage.hostNavigationHandler?(scene)
                    }
                    return
                }
                if action == "loadCreatorEntries" {
                    self.deliverCreatorEntries(data)
                    return
                }
                if self.model.performWebAction(action, data: data) {
                    self.sendState()
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor [weak self] in self?.sendState() }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard navigationAction.request.url?.isFileURL == true else {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            stateDelivery.recoverAfterWebContentProcessTermination()
            webView.reload()
        }

        func sendState() {
            stateDelivery.request()
        }

        /// Answers a bounded `loadCreatorEntries` request on its own channel:
        /// the chosen creator's full entries are pushed straight to the WebView
        /// via `receiveCreatorEntries`, bypassing the authoritative snapshot so
        /// selecting a creator never re-renders the page.
        @MainActor
        private func deliverCreatorEntries(_ data: [String: Any]) {
            guard let datasetID = data["datasetID"] as? String, datasetID.count <= 64,
                  let platformID = data["platformID"] as? String, platformID.count <= 64,
                  let creatorID = data["creatorID"] as? String, creatorID.count <= 256,
                  let payload = model.webCreatorEntriesPayload(
                      datasetID: datasetID,
                      platformID: platformID,
                      creatorID: creatorID
                  ),
                  let script = VaultClassifierWebShell.creatorEntriesJavaScript(payload: payload),
                  let webView else {
                return
            }
            webView.evaluateJavaScript(script) { _, _ in }
        }
    }
}

/// Keeps WebKit presentation strictly downstream from authoritative state.
/// At most one script may render at a time; requests received before that
/// render completes collapse into one newest-state delivery.
final class LatestWebStateDelivery {
    typealias Scheduler = (@escaping () -> Void) -> Void
    typealias ScriptBuilder = (_ presentationRevision: UInt64) -> String?
    typealias Evaluator = (_ script: String, _ completion: @escaping () -> Void) -> Void

    private let schedule: Scheduler
    private let makeScript: ScriptBuilder
    private let evaluate: Evaluator
    private var requestedRevision: UInt64 = 0
    private var deliveredRevision: UInt64 = 0
    private var deliveryScheduled = false
    private var deliveryInFlight = false
    private var activeDeliveryRevision: UInt64?
    /// While the page cannot be seen (another scene is in front, or the window
    /// is closed / occluded) no snapshot is built: building + serialising one
    /// costs ~150 ms of main-thread time per classification burst, all for a
    /// render nobody sees. Requests keep counting; the newest state is delivered
    /// once, when the page shows again.
    private(set) var suspended = false

    func setSuspended(_ flag: Bool) {
        guard flag != suspended else { return }
        suspended = flag
        if !flag { scheduleIfNeeded() }
    }

    init(
        schedule: @escaping Scheduler,
        makeScript: @escaping ScriptBuilder,
        evaluate: @escaping Evaluator
    ) {
        self.schedule = schedule
        self.makeScript = makeScript
        self.evaluate = evaluate
    }

    func request() {
        requestedRevision &+= 1
        scheduleIfNeeded()
    }

    func recoverAfterWebContentProcessTermination() {
        activeDeliveryRevision = nil
        deliveryInFlight = false
        requestedRevision &+= 1
        scheduleIfNeeded()
    }

    private func scheduleIfNeeded() {
        guard !suspended,
              !deliveryScheduled,
              !deliveryInFlight,
              deliveredRevision < requestedRevision else {
            return
        }
        deliveryScheduled = true
        schedule { [weak self] in
            self?.beginLatestDelivery()
        }
    }

    private func beginLatestDelivery() {
        deliveryScheduled = false
        guard !suspended,
              !deliveryInFlight,
              deliveredRevision < requestedRevision else {
            return
        }
        let revision = requestedRevision
        guard let script = makeScript(revision) else {
            deliveredRevision = revision
            scheduleIfNeeded()
            return
        }
        deliveryInFlight = true
        activeDeliveryRevision = revision
        evaluate(script) { [weak self] in
            guard let self,
                  self.activeDeliveryRevision == revision else {
                return
            }
            self.activeDeliveryRevision = nil
            self.deliveryInFlight = false
            self.deliveredRevision = max(self.deliveredRevision, revision)
            self.scheduleIfNeeded()
        }
    }
}

/// Development-only geometry trace for the Tag tree canvas. It deliberately
/// records only local IDs, phase names, and numeric layout values—never tag
/// names, user text, provider configuration, or browser evidence.
private final class TagTreeLayoutLogger {
    private let url: URL
    private var previousSnapshot = ""

    init() {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
        let directory = library
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent(
                VaultRuntimeEnvironment.current.classifierLogDirectoryName,
                isDirectory: true
            )
        self.url = directory.appendingPathComponent("tag-tree-layout.log")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
    }

    func recordNativeSnapshot(_ payload: [String: Any]) {
        let rows = ((payload["assets"] as? [String: Any])?["trees"] as? [[String: Any]] ?? []).flatMap { tree -> [String] in
            let treeID = identifier(tree["id"])
            return (tree["nodes"] as? [[String: Any]] ?? []).map { node in
                "tree=\(treeID) node=\(identifier(node["id"])) x=\(number(node["positionX"])) y=\(number(node["positionY"]))"
            }
        }
        let signature = rows.joined(separator: "|")
        guard signature != previousSnapshot else { return }
        previousSnapshot = signature
        append("native-snapshot nodes=\(rows.count) \(rows.joined(separator: " ; "))")
    }

    func recordWebTrace(_ data: [String: Any]) {
        let phase = identifier(data["phase"])
        let treeID = identifier(data["treeID"])
        let detail = String(data["detail"] as? String ?? "").prefix(4_096)
        append("web-\(phase) tree=\(treeID) \(detail)")
    }

    private func identifier(_ value: Any?) -> String {
        String(describing: value ?? "-").prefix(48).replacingOccurrences(of: " ", with: "_")
    }

    private func number(_ value: Any?) -> String {
        guard let value = value as? NSNumber else { return "-" }
        return value.doubleValue.formatted(.number.precision(.fractionLength(0...2)))
    }

    private func append(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        let data = Data(line.utf8)
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue,
           size > 262_144 {
            try? data.write(to: url, options: .atomic)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}
