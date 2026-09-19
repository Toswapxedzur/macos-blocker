import AppKit
import VaultClassifierApp

/// Standalone development window around the classifier page. The product
/// surface is Mac Vault, which hosts the same `VaultClassifierPage`; this shell
/// exists for headless rigs and for working on the page without Mac Vault.
@main
private enum VaultClassifierShellMain {
    static func main() {
        let application = NSApplication.shared
        let delegate = VaultClassifierShellDelegate()
        application.setActivationPolicy(.regular)
        application.delegate = delegate
        application.run()
    }
}

private final class VaultClassifierShellDelegate: NSObject, NSApplicationDelegate {
    private var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor [weak self] in
            self?.showClassifierWindow()
        }
    }

    @MainActor
    private func showClassifierWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_180, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Vault Classifier"
        window.minSize = NSSize(width: 980, height: 650)
        window.collectionBehavior.insert(.fullScreenPrimary)
        // No ConnectionHub here, so this shell hosts its own local hub. Opt in
        // before building the page (which starts the hub client).
        VaultClassifierPage.shared.allowOwnHubHosting()
        window.contentView = VaultClassifierPage.shared.makeView()
        window.center()
        window.makeKeyAndOrderFront(nil)
        mainWindow = window
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { VaultClassifierPage.shared.flushPendingWrites() }
    }
}
