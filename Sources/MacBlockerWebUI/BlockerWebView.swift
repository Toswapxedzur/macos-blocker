#if canImport(WebKit)
import Foundation
import SwiftUI
import WebKit
import MacBlockerCore

/// Posted (with userInfo `["scene": "vault"|"classifier"|"activity"]`) by a
/// scene's in-web header switch; `BlockerMainView` listens and flips the page.
public extension Notification.Name {
    static let vaultSwitchScene = Notification.Name("VaultSwitchScene")
}

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
    /// Show a system overlay panel (serialized `PanelSnapshot`) on the native side.
    private let onShowSystemPanel: ((String) -> Void)?
    /// Dismiss a system overlay panel by id ("" dismisses all).
    private let onDismissSystemPanel: ((String) -> Void)?
    /// Supplies buffered system-panel events as a JSON array string; polled each second.
    private let systemPanelEventsJSON: (() -> String?)?
    /// Supplies the current app-blocking permission state as JSON
    /// (`{"appBlockingGranted":Bool}`); pushed each second to `window.__cbPermissionState`.
    private let permissionStateJSON: (() -> String?)?
    /// Web requested that we prompt for and open the app-blocking permission.
    private let onRequestAppBlockingPermission: (() -> Void)?
    /// Web requested that we open the permission settings pane.
    private let onOpenPermissionSettings: (() -> Void)?
    /// Supplies the current web-app bridge connection status as JSON; pushed
    /// each second to `window.__cbConnectionState`.
    private let connectionStatusJSON: (() -> String?)?
    /// Supplies current per-group bridge clusters as a JSON array; pushed each
    /// second to `window.__cbClustersState`.
    private let clustersJSON: (() -> String?)?
    /// Web announced this Mac's eligible groups (JSON {program, groups}).
    private let onGroupsAnnounce: ((String) -> Void)?
    /// Web pushed this group's syncable settings (JSON {groupName, groupType, ts, scalars, sites?, apps?, usageMs, usageResetAtMs}).
    private let onGroupSync: ((String) -> Void)?

    public init(
        store: BlockerWebStore = BlockerWebStore(),
        appInventoryJSON: (() -> String?)? = nil,
        ruleLogJSON: (() -> String?)? = nil,
        onStorePersisted: (() -> Void)? = nil,
        onRunCustomGroup: ((String, String) -> Void)? = nil,
        onSnoozePress: ((String) -> Void)? = nil,
        onPanelEvent: ((String, [String: String]) -> Void)? = nil,
        onShowSystemPanel: ((String) -> Void)? = nil,
        onDismissSystemPanel: ((String) -> Void)? = nil,
        systemPanelEventsJSON: (() -> String?)? = nil,
        permissionStateJSON: (() -> String?)? = nil,
        onRequestAppBlockingPermission: (() -> Void)? = nil,
        onOpenPermissionSettings: (() -> Void)? = nil,
        connectionStatusJSON: (() -> String?)? = nil,
        clustersJSON: (() -> String?)? = nil,
        onGroupsAnnounce: ((String) -> Void)? = nil,
        onGroupSync: ((String) -> Void)? = nil
    ) {
        self.store = store
        self.appInventoryJSON = appInventoryJSON
        self.ruleLogJSON = ruleLogJSON
        self.onStorePersisted = onStorePersisted
        self.onRunCustomGroup = onRunCustomGroup
        self.onSnoozePress = onSnoozePress
        self.onPanelEvent = onPanelEvent
        self.onShowSystemPanel = onShowSystemPanel
        self.onDismissSystemPanel = onDismissSystemPanel
        self.systemPanelEventsJSON = systemPanelEventsJSON
        self.permissionStateJSON = permissionStateJSON
        self.onRequestAppBlockingPermission = onRequestAppBlockingPermission
        self.onOpenPermissionSettings = onOpenPermissionSettings
        self.connectionStatusJSON = connectionStatusJSON
        self.clustersJSON = clustersJSON
        self.onGroupsAnnounce = onGroupsAnnounce
        self.onGroupSync = onGroupSync
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(store: store, ruleLogJSON: ruleLogJSON, onStorePersisted: onStorePersisted, onRunCustomGroup: onRunCustomGroup, onSnoozePress: onSnoozePress, onPanelEvent: onPanelEvent, onShowSystemPanel: onShowSystemPanel, onDismissSystemPanel: onDismissSystemPanel, systemPanelEventsJSON: systemPanelEventsJSON, permissionStateJSON: permissionStateJSON, onRequestAppBlockingPermission: onRequestAppBlockingPermission, onOpenPermissionSettings: onOpenPermissionSettings, connectionStatusJSON: connectionStatusJSON, clustersJSON: clustersJSON, onGroupsAnnounce: onGroupsAnnounce, onGroupSync: onGroupSync)
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

        // Ship the localized catalogs and manuals into the page before the
        // popup starts. This keeps localization available even if a WKWebView
        // fetch of a bundled custom-scheme resource is interrupted.
        if let assetBootstrap = Self.nativeAssetBootstrapScript() {
            controller.addUserScript(
                WKUserScript(
                    source: assetBootstrap,
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: true
                )
            )
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
        private let onShowSystemPanel: ((String) -> Void)?
        private let onDismissSystemPanel: ((String) -> Void)?
        private let systemPanelEventsJSON: (() -> String?)?
        private let permissionStateJSON: (() -> String?)?
        private let onRequestAppBlockingPermission: (() -> Void)?
        private let onOpenPermissionSettings: (() -> Void)?
        private let connectionStatusJSON: (() -> String?)?
        private let clustersJSON: (() -> String?)?
        private let onGroupsAnnounce: ((String) -> Void)?
        private let onGroupSync: ((String) -> Void)?

        private var usagePushTimer: Timer?
        // Observes native writes to web-store.json (an MCP tool call, a direct
        // GroupStore.save) so the open editor re-seeds instead of showing a stale
        // tree. Retained so deinit can detach it.
        private var groupStoreObserver: NSObjectProtocol?
        // Starts true so the grant modal is offered exactly once per app launch
        // (when Accessibility is still missing) and never re-shown on reactivation.
        private var promptPermissionOnOpenPending = true

        init(
            store: BlockerWebStore,
            ruleLogJSON: (() -> String?)?,
            onStorePersisted: (() -> Void)?,
            onRunCustomGroup: ((String, String) -> Void)?,
            onSnoozePress: ((String) -> Void)?,
            onPanelEvent: ((String, [String: String]) -> Void)?,
            onShowSystemPanel: ((String) -> Void)?,
            onDismissSystemPanel: ((String) -> Void)?,
            systemPanelEventsJSON: (() -> String?)?,
            permissionStateJSON: (() -> String?)?,
            onRequestAppBlockingPermission: (() -> Void)?,
            onOpenPermissionSettings: (() -> Void)?,
            connectionStatusJSON: (() -> String?)?,
            clustersJSON: (() -> String?)?,
            onGroupsAnnounce: ((String) -> Void)?,
            onGroupSync: ((String) -> Void)?
        ) {
            self.store = store
            self.ruleLogJSON = ruleLogJSON
            self.onStorePersisted = onStorePersisted
            self.onRunCustomGroup = onRunCustomGroup
            self.onSnoozePress = onSnoozePress
            self.onPanelEvent = onPanelEvent
            self.onShowSystemPanel = onShowSystemPanel
            self.onDismissSystemPanel = onDismissSystemPanel
            self.systemPanelEventsJSON = systemPanelEventsJSON
            self.permissionStateJSON = permissionStateJSON
            self.onRequestAppBlockingPermission = onRequestAppBlockingPermission
            self.onOpenPermissionSettings = onOpenPermissionSettings
            self.connectionStatusJSON = connectionStatusJSON
            self.clustersJSON = clustersJSON
            self.onGroupsAnnounce = onGroupsAnnounce
            self.onGroupSync = onGroupSync
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
                self?.pushSystemPanelEvents()
                self?.pushPermissionState()
                self?.pushConnectionState()
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

        private func pushSystemPanelEvents() {
            guard let webView, let provider = systemPanelEventsJSON,
                  let json = provider(), !json.isEmpty else { return }
            webView.evaluateJavaScript("window.__cbSystemPanelEvent(\(json));", completionHandler: nil)
        }

        private func pushPermissionState() {
            guard let webView, let provider = permissionStateJSON,
                  let json = provider(), !json.isEmpty else { return }
            // Keep the Device Control section in sync every tick.
            webView.evaluateJavaScript("window.__cbPermissionState && window.__cbPermissionState(\(json));", completionHandler: nil)

            // Offer the grant modal only on (re)open. We run this after the state
            // push (same webView queue preserves order, so the web side already
            // knows the latest grant state) and only clear the pending flag once
            // the web hook actually exists and ran — so a not-yet-loaded page on
            // first launch doesn't swallow the prompt.
            guard promptPermissionOnOpenPending else { return }
            webView.evaluateJavaScript(
                "(function(){ if (window.__cbPromptPermissionOnOpen) { window.__cbPromptPermissionOnOpen(); return true; } return false; })();"
            ) { [weak self] result, _ in
                if (result as? Bool) == true { self?.promptPermissionOnOpenPending = false }
            }
        }

        private func pushConnectionState() {
            guard let webView, let provider = connectionStatusJSON,
                  let json = provider(), !json.isEmpty else { return }
            webView.evaluateJavaScript(
                "window.__cbConnectionState && window.__cbConnectionState(\(json));",
                completionHandler: nil
            )
        }

        private func pushClusters() {
            guard let webView, let provider = clustersJSON,
                  let json = provider(), !json.isEmpty else { return }
            webView.evaluateJavaScript(
                "window.__cbClustersState && window.__cbClustersState(\(json));",
                completionHandler: nil
            )
        }

        private func messageJSON(_ body: [String: Any]) -> String? {
            guard let payload = body["message"],
                  let data = try? JSONSerialization.data(withJSONObject: payload),
                  let json = String(data: data, encoding: .utf8) else {
                return nil
            }
            return json
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
            case "show-system-panel":
                if let payload = body["message"] as? [String: Any],
                   let snapshot = payload["snapshot"],
                   let data = try? JSONSerialization.data(withJSONObject: snapshot),
                   let json = String(data: data, encoding: .utf8) {
                    onShowSystemPanel?(json)
                }
            case "dismiss-system-panel":
                if let payload = body["message"] as? [String: Any] {
                    let id = (payload["id"] as? String) ?? ""
                    onDismissSystemPanel?(id)
                }
            case "request-app-blocking-permission":
                onRequestAppBlockingPermission?()
            case "open-permission-settings":
                onOpenPermissionSettings?()
            case "connection-status":
                pushConnectionState()
            case "groups-announce":
                if let json = messageJSON(body) { onGroupsAnnounce?(json) }
            case "group-sync":
                if let json = messageJSON(body) { onGroupSync?(json) }
            case "clusters-status":
                pushClusters()
            case "local-folder-status":
                pushLocalFolderStatus()
            case "local-folder-choose":
                chooseLocalFolderNative()
            case "local-folder-revoke":
                LocalFolderGrant.clear()
                pushLocalFolderStatus()
            case "local-folder-reveal":
                revealLocalFolder()
            case "switch-scene":
                #if os(macOS)
                if let scene = (body["message"] as? [String: Any])?["scene"] as? String
                    ?? body["scene"] as? String {
                    NotificationCenter.default.post(name: .vaultSwitchScene, object: nil, userInfo: ["scene": scene])
                }
                #endif
            default:
                break
            }
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

        /// Reveals the user-granted folder in Finder. No-op when none is granted.
        private func revealLocalFolder() {
            #if os(macOS)
            guard let folder = LocalFolderGrant.resolvedFolderURL() else { return }
            let scoped = folder.startAccessingSecurityScopedResource()
            defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
            NSWorkspace.shared.activateFileViewerSelecting([folder])
            #endif
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
