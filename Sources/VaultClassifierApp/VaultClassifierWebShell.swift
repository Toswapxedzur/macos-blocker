import AppKit
import WebKit

/// The development shell is deliberately a bundled local WebKit document.
/// AppKit owns the native window; every visible control and layout is rendered
/// by the local HTML/CSS/JS asset below.
final class VaultClassifierWebShell {
    private let model: VaultClassifierViewModel
    private let coordinator: Coordinator

    init(model: VaultClassifierViewModel) {
        self.model = model
        self.coordinator = Coordinator(model: model)
    }

    func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
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

    private final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        static let messageHandlerName = "vaultClassifier"

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
                self.model.performWebAction(action, data: data)
                self.sendState()
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

        private func sendState() {
            let payload = model.webSnapshot()
            guard let webView,
                  JSONSerialization.isValidJSONObject(payload),
                  let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
                return
            }
            // Base64 keeps local strings as data rather than source code when
            // crossing the native-to-web boundary.
            let encoded = data.base64EncodedString()
            webView.evaluateJavaScript("window.VaultClassifier && window.VaultClassifier.receive(JSON.parse(atob('\(encoded)')));")
        }
    }
}
