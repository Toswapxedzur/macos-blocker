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
    private var controller: SPUStandardUpdaterController?

    private init() {}

    func startIfBundled() {
        guard controller == nil,
              Bundle.main.bundleURL.pathExtension == "app",
              Bundle.main.bundleIdentifier == "com.adamancia.vault.mac",
              Bundle.main.object(forInfoDictionaryKey: "VaultEnvironment") as? String == "production",
              Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String == Self.feedURL else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        available = true
        // Both Info.plist defaults are NO. Sparkle persists later changes.
        autoInstall = controller.updater.automaticallyChecksForUpdates && controller.updater.automaticallyDownloadsUpdates
    }

    func setAutoInstall(_ enabled: Bool) {
        guard let updater = controller?.updater else { return }
        updater.automaticallyChecksForUpdates = enabled
        updater.automaticallyDownloadsUpdates = enabled
        autoInstall = enabled
    }

    func checkManually() {
        controller?.checkForUpdates(nil)
    }
}

struct MacVaultUpdateSettings: View {
    @ObservedObject private var updates = MacVaultUpdates.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Updates").font(.title2.bold())
            Toggle("Auto install updates", isOn: Binding(
                get: { updates.autoInstall },
                set: { updates.setAutoInstall($0) }
            ))
            .disabled(!updates.available)
            Button("Check for updates") { updates.checkManually() }
                .disabled(!updates.available)
        }
        .frame(width: 360, alignment: .leading)
        .padding(20)
    }
}
