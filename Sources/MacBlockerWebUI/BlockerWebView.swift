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
    /// Invoked (on the main thread) right after the editor's store has been
    /// persisted, so the host can recompile/enforce the policy immediately.
    private let onStorePersisted: (() -> Void)?

    public init(
        store: BlockerWebStore = BlockerWebStore(),
        appInventoryJSON: (() -> String?)? = nil,
        onStorePersisted: (() -> Void)? = nil,
        onRunCustomGroup: ((String, String) -> Void)? = nil
    ) {
        self.store = store
        self.appInventoryJSON = appInventoryJSON
        self.onStorePersisted = onStorePersisted
        self.onRunCustomGroup = onRunCustomGroup
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(store: store, onStorePersisted: onStorePersisted, onRunCustomGroup: onRunCustomGroup)
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
        context.coordinator.webView = webView

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

    public final class Coordinator: NSObject, WKScriptMessageHandler {
        weak var webView: WKWebView?
        var schemeHandler: WebAssetSchemeHandler?
        private let store: BlockerWebStore
        private let onStorePersisted: (() -> Void)?
        private let onRunCustomGroup: ((String, String) -> Void)?

        init(
            store: BlockerWebStore,
            onStorePersisted: (() -> Void)?,
            onRunCustomGroup: ((String, String) -> Void)?
        ) {
            self.store = store
            self.onStorePersisted = onStorePersisted
            self.onRunCustomGroup = onRunCustomGroup
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
            default:
                break
            }
        }
    }
}
#endif
