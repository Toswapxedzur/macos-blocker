#if os(macOS)
import AppKit
import ServiceManagement
import MacBlockerCore
import MacBlockerWebUI

/// Process-level lifecycle owner for the macOS app.
///
/// Hosting the web-app bridge hub here (rather than inside a SwiftUI view) keeps
/// it alive for the whole app session: it survives closing the editor window,
/// and registering the app as a login item makes it relaunch at login. Surviving
/// an explicit Quit or a crash would require a launchd agent — that is a
/// separate, later step.
open class BlockerAppDelegate: NSObject, NSApplicationDelegate {
    public override init() { super.init() }

    open func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--unregister-login-item") {
            unregisterLoginItemForUninstall()
            NSApp.terminate(nil)
            return
        }

        if VaultRuntimeEnvironment.current == .development {
            do {
                try LocalHubAuthentication.moveProductionSecretToDevelopmentOnce()
            } catch {
                NSLog("[ConnectionHub] development Keychain migration failed: \(error)")
                NSApp.presentError(error)
                NSApp.terminate(nil)
                return
            }
        }

        // Every app instance participates in its environment's authenticated local
        // hub, which may listen on loopback when it wins host election.
        ConnectionHub.shared.start()

        // "Connect your AI tools" defaults to on: register the Vault MCP server
        // into every installed desktop MCP client the user has not explicitly
        // turned off. Explicit disconnects are remembered and never re-registered.
        MCPConnectorRegistry.shared.applyDefaultConnections()

        syncLoginItem(enabled: false)
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

    open func applicationWillTerminate(_ notification: Notification) {
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
