import AppKit
import Foundation
import WebKit

/// The development shell is deliberately a bundled local WebKit document.
/// AppKit owns the native window; every visible control and layout is rendered
/// by the local HTML/CSS/JS asset below.
final class VaultClassifierWebShell {
    private let model: VaultClassifierViewModel
    private let coordinator: Coordinator
    private let creatorAvatarSchemeHandler: CreatorAvatarSchemeHandler

    @MainActor
    init(model: VaultClassifierViewModel) {
        self.model = model
        self.coordinator = Coordinator(model: model)
        self.creatorAvatarSchemeHandler = CreatorAvatarSchemeHandler(cache: model.creatorAvatarCache)
        Task { @MainActor [weak coordinator] in
            model.onWebStateChange = { [weak coordinator] in
                Task { @MainActor in coordinator?.sendState() }
            }
        }
    }

    func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(creatorAvatarSchemeHandler, forURLScheme: CreatorAvatarCache.scheme)
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(coordinator, name: Coordinator.messageHandlerName)

        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = coordinator
        view.allowsBackForwardNavigationGestures = false
        coordinator.webView = view

        guard let index = Bundle.module.url(forResource: "index", withExtension: "html", subdirectory: "WebAssets") else {
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
    static func stateUpdateJavaScript(payload: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return nil
        }
        let encoded = data.base64EncodedString()
        return "window.VaultClassifier && window.VaultClassifier.receive(JSON.parse(new TextDecoder().decode(Uint8Array.from(atob('\(encoded)'), value => value.charCodeAt(0)))));"
    }

    private final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        static let messageHandlerName = "vaultClassifier"
        private static let layoutLogger = TagTreeLayoutLogger()

        let model: VaultClassifierViewModel
        weak var webView: WKWebView?

        init(model: VaultClassifierViewModel) {
            self.model = model
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == Self.messageHandlerName,
                  let envelope = message.body as? [String: Any],
                  envelope.count <= 2,
                  let action = envelope["action"] as? String,
                  action.count <= 64,
                  let data = envelope["data"] as? [String: Any],
                  data.count <= 16 else {
                return
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if action == "layoutTrace" {
                    Self.layoutLogger.recordWebTrace(data)
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
            webView.reload()
        }

        func sendState() {
            let payload = model.webSnapshot()
            Self.layoutLogger.recordNativeSnapshot(payload)
            guard let webView,
                  let script = VaultClassifierWebShell.stateUpdateJavaScript(payload: payload) else {
                return
            }
            webView.evaluateJavaScript(script)
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
        let directory = library.appendingPathComponent("Logs/VaultClassifier", isDirectory: true)
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
