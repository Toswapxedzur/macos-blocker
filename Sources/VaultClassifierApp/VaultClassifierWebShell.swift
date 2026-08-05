import AppKit
import Foundation
import VaultClassifierCore
import WebKit

/// The development shell is deliberately a bundled local WebKit document.
/// AppKit owns the native window; every visible control and layout is rendered
/// by the local HTML/CSS/JS asset below.
final class VaultClassifierWebShell {
    /// The largest current WebView action is the classifier-type form. Its
    /// fields are individually parsed and bounded by `performWebAction`.
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
        if ProcessInfo.processInfo.environment["ADAMANCIA_VAULT_ENVIRONMENT"] == "development" {
            try? data.write(to: URL(fileURLWithPath: "/tmp/vault-web-payload.json"))
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
        private lazy var stateDelivery = LatestWebStateDelivery(
            schedule: { action in
                // Visual state is intentionally slower than authoritative
                // model mutation. A short batching window coalesces collector
                // bursts while keeping direct controls perceptually current.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: action)
            },
            makeScript: { [weak self] revision in
                guard let self else { return nil }
                let payload = self.model.webSnapshot()
                Self.layoutLogger.recordNativeSnapshot(payload)
                return VaultClassifierWebShell.stateUpdateJavaScript(
                    payload: payload,
                    presentationRevision: revision
                )
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
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            // A full classifier-type save carries the three decision-priority
            // controls in addition to its model and LLM controls (18 fields
            // today). Keep this small but sufficient action-specific bound;
            // the view model still validates every individual value.
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
        guard !deliveryScheduled,
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
        guard !deliveryInFlight,
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
