#if os(macOS)
import AppKit
import ServiceManagement
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
        // Bring the bridge up at the process level, independent of any window.
        let enabled = BlockerWebStore().loadConnectionServerEnabled()
        if enabled {
            ConnectionHub.shared.start()
        } else {
            ConnectionHub.shared.stop()
        }
        // Only add a login item for users who actually run the bridge; clean it
        // up for those who have turned it off.
        syncLoginItem(enabled: enabled)
    }

    /// Keep the process — and therefore the hub — running after the last editor
    /// window is closed.
    open func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Warn before quitting while web-app bridge links are active: quitting stops
    /// the hub, so linked browsers will see this Mac as offline and shared
    /// changes won't sync until the app is reopened.
    open func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard ConnectionHub.shared.activeClusterCount() > 0 else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit and pause web-app bridge links?"
        alert.informativeText =
            "You have linked groups. Quitting stops the local server, so linked browsers "
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
}
#endif
