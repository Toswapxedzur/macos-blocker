import SwiftUI
import MacBlockerAppFeature
import MacBlockerWebUI
import MacBlockerCore
import Sparkle

#if os(macOS)
import AppKit

/// A SwiftPM executable is launched as a background "agent" process, so AppKit
/// never shows the window or a Dock icon. Promoting the activation policy to
/// `.regular` and activating makes the panel window appear.
///
/// Inherits the process-level lifecycle (bridge hub ownership + login item +
/// keep-running-after-last-window-close) from `BlockerAppDelegate`.
final class PanelAppDelegate: BlockerAppDelegate {
    override func applicationDidFinishLaunching(_ notification: Notification) {
        MacVaultUpdates.shared.startIfBundled()
        VaultUpdaterBridge.handle = { action, enabled in
            let updates = MacVaultUpdates.shared
            switch action {
            case "set": if let enabled { updates.setAutoInstall(enabled) }
            case "check": updates.checkManually()
            default: break
            }
            return ["available": updates.available, "autoInstall": updates.autoInstall]
        }
        if let url = MacBundledResources.directory(target: "MacBlockerPanel", subdirectory: "Resources")?.appendingPathComponent("mac-vault-master.png"),
           let image = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = image
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        super.applicationDidFinishLaunching(notification)
    }
}
#endif

@main
struct MacBlockerPanelApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(PanelAppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        WindowGroup("Mac Vault") {
            BlockerMainView()
                .frame(minWidth: 720, minHeight: 560)
        }
        #if os(macOS)
        .defaultSize(width: 1100, height: 760)
        #endif

    }
}
