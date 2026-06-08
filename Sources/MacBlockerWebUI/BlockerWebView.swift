#if canImport(WebKit)
import SwiftUI
import WebKit
import MacBlockerCore

#if canImport(UIKit)
import UIKit
public typealias _CBViewRepresentable = UIViewRepresentable
#elseif canImport(AppKit)
import AppKit
public typealias _CBViewRepresentable = NSViewRepresentable
#endif

/// Hosts the ported customBlocker editor (`popup.html`) inside a WKWebView and
/// bridges its chrome.storage snapshot to a native file via `BlockerWebStore`.
public struct BlockerWebView: _CBViewRepresentable {
    private let store: BlockerWebStore
    private let onRunCustomGroup: ((String, String) -> Void)?
    /// Supplies the installed-application inventory as a JSON array string
    /// (`[{ "id": bundleId, "name": ..., "icon": dataURL }]`). Provided by the
    /// app layer (which can import AppKit / MacControl); nil on platforms with
    /// no native app list.
    private let appInventoryJSON: (() -> String?)?
    /// Supplies rule-log entries as a JSON array string. Called on the 1-second
    /// push timer; entries are forwarded to `window.__cbApplyNativeRuleLog`.
    private let ruleLogJSON: (() -> String?)?
    /// Invoked (on the main thread) right after the editor's store has been
    /// persisted, so the host can recompile/enforce the policy immediately.
    private let onStorePersisted: (() -> Void)?
    private let onSnoozePress: ((String) -> Void)?
    private let onPanelEvent: ((String, [String: String]) -> Void)?

    public init(
        store: BlockerWebStore = BlockerWebStore(),
        appInventoryJSON: (() -> String?)? = nil,
        ruleLogJSON: (() -> String?)? = nil,
        onStorePersisted: (() -> Void)? = nil,
        onRunCustomGroup: ((String, String) -> Void)? = nil,
        onSnoozePress: ((String) -> Void)? = nil,
        onPanelEvent: ((String, [String: String]) -> Void)? = nil
    ) {
        self.store = store
        self.appInventoryJSON = appInventoryJSON
        self.ruleLogJSON = ruleLogJSON
        self.onStorePersisted = onStorePersisted
        self.onRunCustomGroup = onRunCustomGroup
        self.onSnoozePress = onSnoozePress
        self.onPanelEvent = onPanelEvent
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(store: store, ruleLogJSON: ruleLogJSON, onStorePersisted: onStorePersisted, onRunCustomGroup: onRunCustomGroup, onSnoozePress: onSnoozePress, onPanelEvent: onPanelEvent)
    }

    private func makeWebView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "cbBridge")

        // Seed the editor's storage from the native snapshot before any
        // extension script reads chrome.storage.
        if let seed = store.loadRawJSON() {
            let escaped = Self.javaScriptStringLiteral(seed)
            let js = "window.__cbApplyNativeStore(\(escaped));"
            let userScript = WKUserScript(
                source: js,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
            controller.addUserScript(userScript)
        }

        let config = WKWebViewConfiguration()
        config.userContentController = controller
        config.preferences.javaScriptCanOpenWindowsAutomatically = false

        // Serve assets over a custom scheme so the editor's fetch() of
        // translation/*.json, manual/*.md, and the app inventory works
        // (WKWebView blocks fetch on file:// URLs). The handler must be
        // registered before the WKWebView is created. The app inventory is
        // served dynamically here rather than injected, because with real
        // icons it is multi-megabyte and too large for a user script.
        if let assetsDir = WebAssetsLocator.assetsDirectory {
            let handler = WebAssetSchemeHandler(
                assetsDirectory: assetsDir,
                inventoryJSONProvider: appInventoryJSON
            )
            config.setURLSchemeHandler(handler, forURLScheme: WebAssetSchemeHandler.scheme)
            context.coordinator.schemeHandler = handler
        }

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.uiDelegate = context.coordinator
        context.coordinator.webView = webView
        context.coordinator.startUsagePush()

        if WebAssetsLocator.assetsDirectory != nil {
            webView.load(URLRequest(url: WebAssetSchemeHandler.indexURL))
        } else {
            webView.loadHTMLString(Self.missingAssetsHTML, baseURL: nil)
        }
        return webView
    }

    private static func javaScriptStringLiteral(_ value: String) -> String {
        let data = (try? JSONEncoder().encode(value)) ?? Data("\"\"".utf8)
        return String(data: data, encoding: .utf8) ?? "\"\""
    }

    private static let missingAssetsHTML = """
    <html><body style="font-family:-apple-system;padding:24px">
    <h2>Web assets missing</h2>
    <p>Could not locate WebAssets/popup.html in the bundle.</p>
    </body></html>
    """

    // MARK: UIKit

    #if canImport(UIKit)
    public func makeUIView(context: Context) -> WKWebView {
        makeWebView(context: context)
    }

    public func updateUIView(_ uiView: WKWebView, context: Context) {}
    #elseif canImport(AppKit)
    public func makeNSView(context: Context) -> WKWebView {
        makeWebView(context: context)
    }

    public func updateNSView(_ nsView: WKWebView, context: Context) {}
    #endif

    // MARK: Coordinator

    public final class Coordinator: NSObject, WKScriptMessageHandler, WKUIDelegate {
        weak var webView: WKWebView?
        var schemeHandler: WebAssetSchemeHandler?
        private let store: BlockerWebStore
        private let ruleLogJSON: (() -> String?)?
        private let onStorePersisted: (() -> Void)?
        private let onRunCustomGroup: ((String, String) -> Void)?
        private let onSnoozePress: ((String) -> Void)?
        private let onPanelEvent: ((String, [String: String]) -> Void)?

        private var usagePushTimer: Timer?

        init(
            store: BlockerWebStore,
            ruleLogJSON: (() -> String?)?,
            onStorePersisted: (() -> Void)?,
            onRunCustomGroup: ((String, String) -> Void)?,
            onSnoozePress: ((String) -> Void)?,
            onPanelEvent: ((String, [String: String]) -> Void)?
        ) {
            self.store = store
            self.ruleLogJSON = ruleLogJSON
            self.onStorePersisted = onStorePersisted
            self.onRunCustomGroup = onRunCustomGroup
            self.onSnoozePress = onSnoozePress
            self.onPanelEvent = onPanelEvent
        }

        deinit {
            usagePushTimer?.invalidate()
        }

        func startUsagePush() {
            usagePushTimer?.invalidate()
            let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.pushUsage()
                self?.pushRuleLog()
            }
            usagePushTimer = timer
        }

        private func pushUsage() {
            guard let webView else { return }
            let usage = store.loadUsageTimers()
            guard !usage.timersMs.isEmpty || !usage.resetAtMs.isEmpty else { return }
            let payload: [String: Any] = [
                "usageTimersMs": usage.timersMs,
                "usageResetAtMs": usage.resetAtMs
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let json = String(data: data, encoding: .utf8)
            else {
                return
            }
            webView.evaluateJavaScript("window.__cbApplyNativeUsage(\(json));", completionHandler: nil)
        }

        private func pushRuleLog() {
            guard let webView, let provider = ruleLogJSON,
                  let json = provider(), !json.isEmpty else { return }
            webView.evaluateJavaScript("window.__cbApplyNativeRuleLog(\(json));", completionHandler: nil)
        }

        public func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "cbBridge",
                  let body = message.body as? [String: Any],
                  let kind = body["kind"] as? String
            else {
                return
            }

            switch kind {
            case "persist-store":
                if let rawStore = body["store"] {
                    store.save(rawStore: rawStore)
                    onStorePersisted?()
                }
            case "run-custom-group":
                if let payload = body["message"] as? [String: Any],
                   let groupID = payload["groupId"] as? String,
                   let source = payload["source"] as? String {
                    onRunCustomGroup?(groupID, source)
                }
            case "fire-snooze-press":
                if let payload = body["message"] as? [String: Any],
                   let groupID = payload["groupId"] as? String {
                    onSnoozePress?(groupID)
                }
            case "custom-panel-event":
                if let payload = body["message"] as? [String: Any],
                   let groupID = payload["groupId"] as? String {
                    var data: [String: String] = [:]
                    for (key, value) in payload where key != "groupId" {
                        data[key] = "\(value)"
                    }
                    onPanelEvent?(groupID, data)
                }
            default:
                break
            }
        }

        // MARK: WKUIDelegate - JS dialogs

        public func webView(
            _ webView: WKWebView,
            runJavaScriptAlertPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping () -> Void
        ) {
            #if os(macOS)
            let alert = NSAlert()
            alert.messageText = message
            alert.addButton(withTitle: "OK")
            alert.runModal()
            #endif
            completionHandler()
        }

        public func webView(
            _ webView: WKWebView,
            runJavaScriptConfirmPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping (Bool) -> Void
        ) {
            #if os(macOS)
            let alert = NSAlert()
            alert.messageText = message
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            let response = alert.runModal()
            completionHandler(response == .alertFirstButtonReturn)
            #else
            completionHandler(true)
            #endif
        }

        public func webView(
            _ webView: WKWebView,
            runJavaScriptTextInputPanelWithPrompt prompt: String,
            defaultText: String?,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping (String?) -> Void
        ) {
            #if os(macOS)
            let alert = NSAlert()
            alert.messageText = prompt
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            input.stringValue = defaultText ?? ""
            alert.accessoryView = input
            let response = alert.runModal()
            completionHandler(response == .alertFirstButtonReturn ? input.stringValue : nil)
            #else
            completionHandler(defaultText)
            #endif
        }
    }
}
#endif
