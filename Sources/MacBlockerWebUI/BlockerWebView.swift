#if canImport(WebKit)
import Foundation
import SwiftUI
import WebKit
import MacBlockerCore

import AppKit

/// Hosts the ported customBlocker editor (`popup.html`) inside a WKWebView and
/// bridges its chrome.storage snapshot to a native file via `BlockerWebStore`.
/// Mac Vault's other scenes (`WebScene`) share this one web view and document.
public struct BlockerWebView: NSViewRepresentable {
    private let store: BlockerWebStore
    private let scenes: [WebScene]
    private let onRunCustomGroup: ((String, String) -> [String: Any])?
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
    /// Supplies the links and every program's groups (JSON {clusters, rosters});
    /// pushed each second to `window.__cbClustersState`.
    private let clustersJSON: (() -> String?)?
    /// The editor's Link / Unlink ("group-link" | "group-unlink", its message);
    /// returns the refusal, or nil.
    private let onLinkRequest: ((String, [String: Any]) -> String?)?
    private let tagNames: ((String) -> [String])?

    public init(
        store: BlockerWebStore = BlockerWebStore(),
        appInventoryJSON: (() -> String?)? = nil,
        ruleLogJSON: (() -> String?)? = nil,
        onStorePersisted: (() -> Void)? = nil,
        onRunCustomGroup: ((String, String) -> [String: Any])? = nil,
        onSnoozePress: ((String) -> Void)? = nil,
        clustersJSON: (() -> String?)? = nil,
        onLinkRequest: ((String, [String: Any]) -> String?)? = nil,
        tagNames: ((String) -> [String])? = nil,
        scenes: [WebScene] = []
    ) {
        self.store = store
        self.scenes = scenes
        self.appInventoryJSON = appInventoryJSON
        self.ruleLogJSON = ruleLogJSON
        self.onStorePersisted = onStorePersisted
        self.onRunCustomGroup = onRunCustomGroup
        self.onSnoozePress = onSnoozePress
        self.clustersJSON = clustersJSON
        self.onLinkRequest = onLinkRequest
        self.tagNames = tagNames
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(store: store, ruleLogJSON: ruleLogJSON, onStorePersisted: onStorePersisted, onRunCustomGroup: onRunCustomGroup, onSnoozePress: onSnoozePress, clustersJSON: clustersJSON, onLinkRequest: onLinkRequest, tagNames: tagNames, scenes: scenes)
    }

    @MainActor
    private func makeWebView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "cbBridge")
        Self.addUserScripts(to: controller, store: store)

        let config = WKWebViewConfiguration()
        config.userContentController = controller
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        for scene in scenes { scene.install(config) }

        // Serve assets over a custom scheme so the editor's fetch() of
        // translation/*.json, manual/*.md, and the app inventory works
        // (WKWebView blocks fetch on file:// URLs). The handler must be
        // registered before the WKWebView is created. The app inventory is
        // served dynamically here rather than injected, because with real
        // icons it is multi-megabyte and too large for a user script.
        if let assetsDir = WebAssetsLocator.assetsDirectory {
            var componentDirectories: [String: URL] = [:]
            for scene in scenes {
                if let prefix = scene.assetsPrefix, let directory = scene.assetsDirectory {
                    componentDirectories[prefix] = directory
                }
            }
            let handler = WebAssetSchemeHandler(
                assetsDirectory: assetsDir,
                componentDirectories: componentDirectories,
                inventoryJSONProvider: appInventoryJSON
            )
            config.setURLSchemeHandler(handler, forURLScheme: WebAssetSchemeHandler.scheme)
            context.coordinator.schemeHandler = handler
        }

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.uiDelegate = context.coordinator
        webView.navigationDelegate = context.coordinator
        // Every scene is designed on the fixed light theme.
        webView.appearance = NSAppearance(named: .aqua)
        context.coordinator.webView = webView
        context.coordinator.startUsagePush()
        for scene in scenes { scene.attach(webView) }

        if WebAssetsLocator.assetsDirectory != nil {
            webView.load(URLRequest(url: WebAssetSchemeHandler.indexURL))
        } else {
            webView.loadHTMLString(Self.missingAssetsHTML, baseURL: nil)
        }
        return webView
    }

    /// The document-start scripts: the store seed and the bundled catalogs.
    /// Added again, with a fresh seed, before a reload.
    static func addUserScripts(to controller: WKUserContentController, store: BlockerWebStore) {
        // Seed the editor's storage from the native snapshot before any
        // extension script reads chrome.storage. At document start the shim
        // has not loaded yet (it is a body script), so the seed is parked on
        // `window` and the shim picks it up as it starts — calling
        // __cbApplyNativeStore here threw, the shim fell back to its stale
        // localStorage copy and wrote that back over the file (bug fixed
        // 2026-09-25).
        if let seed = store.loadRawJSON() {
            let escaped = javaScriptStringLiteral(seed)
            let js = "window.__cbNativeStoreSeed = \(escaped);"
            let userScript = WKUserScript(
                source: js,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
            controller.addUserScript(userScript)
        }

        // Ship the localized catalogs and manuals into the page before the
        // popup starts. This keeps localization available even if a WKWebView
        // fetch of a bundled custom-scheme resource is interrupted.
        if let assetBootstrap = nativeAssetBootstrapScript() {
            controller.addUserScript(
                WKUserScript(
                    source: assetBootstrap,
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: true
                )
            )
        }
    }

    private static func javaScriptStringLiteral(_ value: String) -> String {
        let data = (try? JSONEncoder().encode(value)) ?? Data("\"\"".utf8)
        return String(data: data, encoding: .utf8) ?? "\"\""
    }

    private static func nativeAssetBootstrapScript() -> String? {
        guard let assetsDirectory = WebAssetsLocator.assetsDirectory else {
            return nil
        }

        var statements: [String] = []
        if let catalogs = jsonObjects(in: assetsDirectory.appendingPathComponent("translation")),
           let json = jsonString(catalogs) {
            statements.append("window.CUSTOM_BLOCKER_INLINE_MESSAGES = \(json);")
        }
        if let manuals = textFiles(in: assetsDirectory.appendingPathComponent("manual")),
           let json = jsonString(manuals) {
            statements.append("window.CUSTOM_BLOCKER_INLINE_MANUALS = \(json);")
        }
        return statements.isEmpty ? nil : statements.joined(separator: "\n")
    }

    private static func jsonObjects(in directory: URL) -> [String: Any]? {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return nil
        }
        var result: [String: Any] = [:]
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let dictionary = object as? [String: Any] else {
                continue
            }
            result[file.deletingPathExtension().lastPathComponent] = dictionary
        }
        return result.isEmpty ? nil : result
    }

    private static func textFiles(in directory: URL) -> [String: String]? {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return nil
        }
        var result: [String: String] = [:]
        for file in files where file.pathExtension == "md" {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else {
                continue
            }
            result[file.deletingPathExtension().lastPathComponent] = text
        }
        return result.isEmpty ? nil : result
    }

    private static func jsonString(_ object: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text
    }

    private static let missingAssetsHTML = """
    <html><body style="font-family:-apple-system;padding:24px">
    <h2>Web assets missing</h2>
    <p>Could not locate WebAssets/popup.html in the bundle.</p>
    </body></html>
    """

    // MARK: NSViewRepresentable

    public func makeNSView(context: Context) -> WKWebView {
        makeWebView(context: context)
    }

    public func updateNSView(_ nsView: WKWebView, context: Context) {}

    // MARK: Coordinator

    public final class Coordinator: NSObject, WKScriptMessageHandler, WKUIDelegate, WKNavigationDelegate {
        weak var webView: WKWebView?
        var schemeHandler: WebAssetSchemeHandler?
        private let store: BlockerWebStore
        private let ruleLogJSON: (() -> String?)?
        private let onStorePersisted: (() -> Void)?
        private let onRunCustomGroup: ((String, String) -> [String: Any])?
        private let onSnoozePress: ((String) -> Void)?
        private let clustersJSON: (() -> String?)?
        private let onLinkRequest: ((String, [String: Any]) -> String?)?
        private let tagNames: ((String) -> [String])?
        private let scenes: [WebScene]

        private var usagePushTimer: Timer?
        // Observes native writes to web-store.json (an MCP tool call, a direct
        // GroupStore.save) so the open editor re-seeds instead of showing a stale
        // tree. Retained so deinit can detach it.
        private var groupStoreObserver: NSObjectProtocol?

        init(
            store: BlockerWebStore,
            ruleLogJSON: (() -> String?)?,
            onStorePersisted: (() -> Void)?,
            onRunCustomGroup: ((String, String) -> [String: Any])?,
            onSnoozePress: ((String) -> Void)?,
            clustersJSON: (() -> String?)?,
            onLinkRequest: ((String, [String: Any]) -> String?)?,
            tagNames: ((String) -> [String])?,
            scenes: [WebScene]
        ) {
            self.store = store
            self.scenes = scenes
            self.ruleLogJSON = ruleLogJSON
            self.onStorePersisted = onStorePersisted
            self.onRunCustomGroup = onRunCustomGroup
            self.onSnoozePress = onSnoozePress
            self.clustersJSON = clustersJSON
            self.onLinkRequest = onLinkRequest
            self.tagNames = tagNames
        }

        deinit {
            usagePushTimer?.invalidate()
            if let observer = groupStoreObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            if let wv = webView {
                wv.configuration.userContentController.removeScriptMessageHandler(forName: "cbBridge")
            }
        }

        func startUsagePush() {
            usagePushTimer?.invalidate()
            let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.pushUsage()
                self?.pushRuleLog()
                self?.pushClusters()
            }
            usagePushTimer = timer

            // Re-seed the editor when a native writer (MCP tool, direct save)
            // mutates the store out-of-band. The notification can fire on the MCP
            // server's thread, so hop to main for evaluateJavaScript.
            if groupStoreObserver == nil {
                groupStoreObserver = NotificationCenter.default.addObserver(
                    forName: GroupStore.didChangeNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    self?.pushNativeStore()
                }
            }
        }

        /// Push the current on-disk store into the open editor so it repaints
        /// after a native mutation. Mirrors the load-time seed: the shim receives
        /// a JSON string, JSON.parses it, and fires change listeners WITHOUT
        /// persisting (no write-back echo).
        private func pushNativeStore() {
            guard let webView, let raw = store.loadRawJSON() else { return }
            let escaped = BlockerWebView.javaScriptStringLiteral(raw)
            webView.evaluateJavaScript("window.__cbApplyNativeStore(\(escaped));", completionHandler: nil)
        }

        private func pushClusters() {
            guard let webView, let provider = clustersJSON,
                  let json = provider(), !json.isEmpty else { return }
            webView.evaluateJavaScript(
                "window.__cbClustersState && window.__cbClustersState(\(json));",
                completionHandler: nil
            )
        }

        private func pushUsage() {
            guard let webView else { return }
            let usage = store.loadUsageTimers()
            guard !usage.timersMs.isEmpty || !usage.resetAtMs.isEmpty else { return }
            let payload: [String: Any] = [
                "usageTimersMs": usage.timersMs,
                "usageResetAtMs": usage.resetAtMs,
                "usageBucketsMs": usage.bucketsMs.mapValues { UsageBudget.bucketJSON($0) }
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
                if let changes = body["changes"] as? [String: Any] {
                    store.merge(changes: changes)
                    onStorePersisted?()
                }
            case "run-custom-group":
                // Run: the rule loads in Mac Vault's engine; the editor gets the result.
                let payload = body["message"] as? [String: Any] ?? [:]
                let loadResult = onRunCustomGroup?(payload["groupId"] as? String ?? "", payload["source"] as? String ?? "")
                    ?? ["ok": false, "error": "rules-not-running"]
                nativeReply(body, ["ok": true, "loadResult": loadResult])
            case "vault-classifier-tag-names":
                // The editor's tag suggestions, from Mac Vault's own classifier.
                let platform = (body["message"] as? [String: Any])?["platform"] as? String ?? ""
                let names = tagNames?(platform) ?? []
                nativeReply(body, ["ok": true, "names": Array(names.prefix(200))])
            case "reset-group-runtime":
                if let payload = body["message"] as? [String: Any], let groupID = payload["groupId"] as? String {
                    store.resetRuntime(groupID: groupID)
                }
            case "fire-snooze-press":
                if let payload = body["message"] as? [String: Any],
                   let groupID = payload["groupId"] as? String {
                    onSnoozePress?(groupID)
                }
            case "clusters-status":
                pushClusters()
            case "group-link", "group-unlink":
                let message = body["message"] as? [String: Any] ?? [:]
                if let refusal = onLinkRequest?(kind, message),
                   let data = try? JSONSerialization.data(withJSONObject: [refusal]),
                   let json = String(data: data, encoding: .utf8) {
                    webView?.evaluateJavaScript("window.__cbLinkRefused && window.__cbLinkRefused(\(json)[0]);", completionHandler: nil)
                }
                pushClusters()
            case "local-folder-status":
                pushLocalFolderStatus()
            case "local-folder-choose":
                chooseLocalFolderNative()
            case "local-folder-revoke":
                LocalFolderGrant.clear()
                pushLocalFolderStatus()
            case "scene-shown":
                if let scene = body["scene"] as? String, scene.count <= 32 {
                    NotificationCenter.default.post(name: .vaultSceneShown, object: nil, userInfo: ["scene": scene])
                }
            default:
                break
            }
        }

        /// Answers a request the editor made with `nativeRequest` (its requestId).
        private func nativeReply(_ body: [String: Any], _ reply: [String: Any]) {
            guard let id = body["requestId"] as? String,
                  let data = try? JSONSerialization.data(withJSONObject: [id, reply] as [Any]),
                  let json = String(data: data, encoding: .utf8) else { return }
            webView?.evaluateJavaScript("window.__cbNativeReply && window.__cbNativeReply.apply(null, \(json));", completionHandler: nil)
        }

        /// Native folder-grant picker (macOS has no web directory picker). Mirrors
        /// the browser extension's "Choose folder": the user grants one folder,
        /// stored as a security-scoped bookmark, and custom-rule file I/O is rooted
        /// there. Nothing is available until a folder is chosen.
        private func chooseLocalFolderNative() {
            #if os(macOS)
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.message = "Grant a folder for custom rules to read and write .txt, .csv, and .json files."
            guard panel.runModal() == .OK, let url = panel.url else { return }
            if let bookmark = try? url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                LocalFolderGrant.store(bookmark: bookmark)
            }
            pushLocalFolderStatus()
            #endif
        }

        /// Pushes the current grant state to the Settings panel so it can render
        /// Choose / Revoke and the connected folder's name.
        private func pushLocalFolderStatus() {
            guard let webView else { return }
            let connected = LocalFolderGrant.isConnected
            let payload: [String: Any] = [
                "connected": connected,
                "name": connected ? LocalFolderGrant.folderName : ""
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let json = String(data: data, encoding: .utf8) else { return }
            webView.evaluateJavaScript(
                "window.__cbLocalFolderStatus && window.__cbLocalFolderStatus(\(json));",
                completionHandler: nil
            )
        }

        // MARK: WKNavigationDelegate

        /// The page (all scenes) died with its web content process: load it
        /// again and let each scene catch up.
        public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            let controller = webView.configuration.userContentController
            controller.removeAllUserScripts()
            BlockerWebView.addUserScripts(to: controller, store: store)
            webView.reload()
            MainActor.assumeIsolated {
                for scene in scenes { scene.reloaded() }
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
