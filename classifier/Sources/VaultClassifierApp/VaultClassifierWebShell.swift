import AppKit
import Foundation
import VaultClassifierCore
import WebKit

/// The native half of the Classifier scene. The page (app.js / app.css /
/// strings.js) runs in its host's web view — Mac Vault's one document, beside
/// the Vault editor — and talks to the model through the "vaultClassifier"
/// message handler installed here.
final class VaultClassifierWebShell {
    /// WebView actions carry only a small bounded dictionary. Every live field
    /// is also parsed and bounded individually by `performWebAction`.
    static let maximumWebActionDataFields = VaultClassifierPresentation.maximumWebActionDataFields

    private let model: VaultClassifierViewModel
    private let coordinator: Coordinator
    private let sourceIconSchemeHandler: SourceIconSchemeHandler

    @MainActor
    init(model: VaultClassifierViewModel) {
        self.model = model
        self.coordinator = Coordinator(model: model)
        self.sourceIconSchemeHandler = SourceIconSchemeHandler(cache: model.sourceIconCache, pictures: model.creatorPictures)
        Task { @MainActor [weak coordinator] in
            model.onWebStateChange = { [weak coordinator] in
                Task { @MainActor [weak coordinator] in coordinator?.sendState() }
            }
        }
    }

    /// Before the host's web view exists: the page's message handler and the
    /// creator-avatar scheme.
    func install(in configuration: WKWebViewConfiguration) {
        configuration.setURLSchemeHandler(sourceIconSchemeHandler, forURLScheme: SourceIconCache.scheme)
        configuration.userContentController.add(coordinator, name: Coordinator.messageHandlerName)
    }

    /// The host's web view, where the page runs.
    func attach(_ webView: WKWebView) {
        coordinator.webView = webView
    }

    /// The host reloaded the page after its web content process died.
    func pageReloaded() {
        coordinator.pageReloaded()
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
        VaultClassifierPresentation.stateUpdateJavaScript(payload: payload, presentationRevision: presentationRevision)
    }

    /// The page's files (served by the host under "classifier/").
    static var webAssetsDirectory: URL? {
        Bundle.module.resourceURL?.appendingPathComponent("WebAssets", isDirectory: true)
    }

    static func bundledWebAssetURL(named name: String, extension fileExtension: String) -> URL? {
        VaultClassifierBundledAssets.url(named: name, extension: fileExtension)
    }

    private final class Coordinator: NSObject, WKScriptMessageHandler {
        static let messageHandlerName = "vaultClassifier"

        let model: VaultClassifierViewModel
        weak var webView: WKWebView?
        /// Whether the host currently shows this scene (Mac Vault shows one scene
        /// at a time).
        private var hostShowsPage = true
        private var initialStateSent = false
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
                // The web view calls this on the main thread.
                let payload = MainActor.assumeIsolated { self.model.webSnapshot() }
                let tBuilt = DispatchTime.now()
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
                if self.model.performWebAction(action, data: data) {
                    // Warm the newly loaded renderer even while its scene is
                    // hidden. Later background updates retain normal batching.
                    if action == "state", !self.initialStateSent,
                       let script = VaultClassifierWebShell.stateUpdateJavaScript(payload: self.model.webSnapshot()),
                       let webView = self.webView {
                        self.initialStateSent = true
                        webView.evaluateJavaScript(script) { _, _ in }
                    } else {
                        self.sendState()
                    }
                }
            }
        }

        /// The page reloaded (its script asks for state again on start); a
        /// delivery in flight to the dead page never completes.
        func pageReloaded() {
            initialStateSent = false
            stateDelivery.recoverAfterWebContentProcessTermination()
        }

        func sendState() {
            stateDelivery.request()
        }
    }
}
