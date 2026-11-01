import AppKit
import Sparkle
import SwiftUI

/// Sparkle owns the update preference and installer. The CLI development shell
/// has no app bundle, so it must never query the public production feed.
@MainActor
final class MacVaultUpdates: ObservableObject {
    static let shared = MacVaultUpdates()
    #if arch(arm64)
    private static let feedURL = "https://customblocker.com/downloads/updates/mac/arm64/appcast.xml"
    #else
    private static let feedURL = "https://customblocker.com/downloads/updates/mac/x86_64/appcast.xml"
    #endif

    @Published private(set) var autoInstall = false
    @Published private(set) var available = false
    @Published private(set) var requiresMove = false
    private var controller: SPUStandardUpdaterController?

    private init() {}

    func startIfBundled() {
        guard controller == nil, !available,
              Bundle.main.bundleURL.pathExtension == "app",
              Bundle.main.bundleIdentifier == "com.adamancia.vault.mac",
              Bundle.main.object(forInfoDictionaryKey: "VaultEnvironment") as? String == "production",
              Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String == Self.feedURL else { return }
        // A disk image cannot be replaced in place. Keep the manual action
        // available so it can explain the move, but never schedule a download
        // that Sparkle could not install from this location.
        if (try? Bundle.main.bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) == true {
            requiresMove = true
            available = true
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        available = true
        // Both Info.plist defaults are NO. Sparkle persists later changes.
        autoInstall = controller.updater.automaticallyChecksForUpdates && controller.updater.automaticallyDownloadsUpdates
    }

    func setAutoInstall(_ enabled: Bool) {
        guard let updater = controller?.updater else { return }
        if enabled {
            updater.automaticallyChecksForUpdates = true
            updater.automaticallyDownloadsUpdates = true
        } else {
            // Sparkle only permits changing automatic downloads while
            // automatic checks are enabled.
            updater.automaticallyDownloadsUpdates = false
            updater.automaticallyChecksForUpdates = false
        }
        autoInstall = updater.automaticallyChecksForUpdates && updater.automaticallyDownloadsUpdates
    }

    func checkManually() {
        if requiresMove {
            let alert = NSAlert()
            alert.messageText = "Move Mac Vault to Applications"
            alert.informativeText = "Quit Mac Vault, copy it to the Applications folder, then open that copy and check for updates again."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        controller?.checkForUpdates(nil)
    }
}
