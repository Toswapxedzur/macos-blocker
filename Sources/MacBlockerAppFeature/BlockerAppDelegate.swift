#if os(macOS)
import AppKit
import ServiceManagement
import notify
import MacBlockerCore
import MacBlockerWebUI
import VaultClassifierApp

/// Process-level lifecycle owner for the macOS app.
///
/// Hosting the web-app bridge hub here (rather than inside a SwiftUI view) keeps
/// it alive for the whole app session: it survives closing the editor window,
/// and registering the app as a login item makes it relaunch at login. Surviving
/// an explicit Quit or a crash would require a launchd agent — that is a
/// separate, later step.
open class BlockerAppDelegate: NSObject, NSApplicationDelegate {
    public override init() { super.init() }

    /// Retains the running MCP server for the app session.
    private var mcpServer: VaultMCPHTTPServer?

    /// Records app-usage time into the local Activity log (opt-in per category).
    private var activityRecorder: ActivityRecorderService?

    open func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--unregister-login-item") {
            unregisterLoginItemForUninstall()
            NSApp.terminate(nil)
            return
        }

        // Every app instance participates in its environment's authenticated local
        // hub, which may listen on loopback when it wins host election.
        ConnectionHub.shared.start()

        // The Vault Classifier is a component of this app. Starting its tagging
        // service here — not when its page is first opened — keeps tags flowing
        // to the browser for the whole session, including after the window is
        // closed (the process stays alive; see below). Mac Vault's ConnectionHub
        // (started above) is the sole hub host; the classifier never hosts, it
        // only joins as a client (see SharedHubClient).
        MainActor.assumeIsolated {
            // The classifier's in-page header switch asks the shell to change
            // scenes through this hook (mirrors the Vault/Activity web headers).
            VaultClassifierPage.hostNavigationHandler = { scene in
                NotificationCenter.default.post(name: .vaultSwitchScene, object: nil, userInfo: ["scene": scene])
            }
            VaultClassifierPage.shared.start()
        }

        // App blocking runs for the whole session, window open or not; only
        // quitting the app stops it.
        MainActor.assumeIsolated { MacEnforcementBridge.shared.start() }
        registerDevelopmentCloseWindowsTrigger()

        // The floating quick-add "+" (off by default; follows the editor's switch).
        MainActor.assumeIsolated { QuickAddPanel.shared.reload() }

        // The Activity log records app-usage time (native) and browser activity
        // (flushed by the extension over the hub). One store is shared by the
        // recorder and the hub; each category records only while enabled (default
        // off), and the store is the backstop.
        let activityStore = ActivityStore.standard()
        ConnectionHub.shared.activityStore = activityStore
        MainActor.assumeIsolated { ActivityPage.shared.configure(store: activityStore) }
        let activityRecorder = ActivityRecorderService(store: activityStore)
        activityRecorder.start()
        self.activityRecorder = activityRecorder

        // MCP go-live. Start the loopback MCP server gated by a bearer token
        // derived from the hub secret, tell the connector registry to write that
        // token into each tool's config, and enable launch auto-connect so the
        // registered tools point at a live, authenticated endpoint. Fail closed:
        // if the token is unavailable we do not expose an unauthenticated server.
        if let token = LocalHubAuthentication.mcpBearerToken() {
            let mcpServer = VaultMCPHTTPServer.vault(token: token, additionalTools: ClassifierMCPTools.tools() + ExtensionMCPTools.tools())
            mcpServer.start()
            self.mcpServer = mcpServer
            MCPConnectorRegistry.shared.authTokenProvider = { LocalHubAuthentication.mcpBearerToken() }
            MCPConnectorRegistry.isLaunchAutoConnectEnabled = true
        }

        // "Connect your AI tools" defaults to on: register the Vault MCP server
        // into every installed desktop MCP client the user has not explicitly
        // turned off. Explicit disconnects are remembered and never re-registered.
        MCPConnectorRegistry.shared.applyDefaultConnections()

        // Relaunch at login so tag blocking (and the hub) resume after a reboot
        // without the user reopening the app — otherwise protection silently
        // stays off until they do. Production, bundled builds only; a user can
        // still turn it off in System Settings ▸ Login Items.
        syncLoginItem(enabled: true)
    }

    /// Keep the process — and therefore the hub — running after the last editor
    /// window is closed.
    open func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Warn before quitting while web-app bridge links are active: quitting
    /// disconnects this client, so linked browsers will see this Mac as offline and shared
    /// changes won't sync until the app is reopened.
    open func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard ConnectionHub.shared.activeClusterCount() > 0 else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit and pause shared Vault links?"
        alert.informativeText =
            "You have linked groups. Quitting disconnects Mac Vault, so linked browsers "
            + "will show this Mac as offline and shared changes won't sync until you reopen the app."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    /// DEVELOPMENT BUILDS ONLY (test scaffolding). Posting
    /// `notifyutil -p com.adamancia.vault.development.close-windows` closes the
    /// app's titled windows exactly as the user closing them would, so a remote
    /// test host can prove the app keeps working with its window closed —
    /// without screen-automation permissions. Never registered in production.
    private var closeWindowsToken: Int32 = 0
    private func registerDevelopmentCloseWindowsTrigger() {
        guard VaultRuntimeEnvironment.current == .development else { return }
        notify_register_dispatch("com.adamancia.vault.development.close-windows", &closeWindowsToken, .main) { _ in
            MainActor.assumeIsolated {
                for window in NSApp.windows where window.isVisible && window.styleMask.contains(.titled) {
                    window.performClose(nil)
                }
            }
        }
    }

    open func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { MacEnforcementBridge.shared.stop() }
        activityRecorder?.stop()
        MainActor.assumeIsolated { VaultClassifierPage.shared.flushPendingWrites() }
        ConnectionHub.shared.stop()
    }

    /// Registers (or removes) the app as a login item so the bridge is available
    /// across reboots without the user re-opening the app.
    private func syncLoginItem(enabled: Bool) {
        guard VaultRuntimeEnvironment.current == .production else { return }
        guard #available(macOS 13.0, *) else { return }
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            // Non-fatal: an un-bundled dev build (e.g. `swift run`) cannot
            // register, and the user may have overridden the item in System
            // Settings ▸ Login Items.
            NSLog("[ConnectionHub] login-item sync failed: \(error)")
        }
    }

    private func unregisterLoginItemForUninstall() {
        guard #available(macOS 13.0, *) else { return }
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("[ConnectionHub] uninstall login-item unregister failed: \(error)")
        }
    }
}
#endif
