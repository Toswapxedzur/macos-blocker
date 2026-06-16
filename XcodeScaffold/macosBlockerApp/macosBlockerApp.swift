import SwiftUI
import MacBlockerAppFeature
import MacBlockerCore

@main
struct macosBlockerApp: App {
    #if os(macOS)
    // Owns the web-app bridge hub at the process level so it survives closing
    // the window, and registers the app as a login item.
    @NSApplicationDelegateAdaptor(BlockerAppDelegate.self) private var appDelegate
    #endif

    init() {
        // App and extensions must agree on the App Group before any store use.
        AppGroup.identifier = AppGroupIdentifier.value
    }

    var body: some Scene {
        WindowGroup {
            BlockerMainView()
                .task {
                    await refreshScreenTime()
                }
        }
    }

    /// On foreground: approve pending snooze requests, rebuild monitoring from
    /// the latest enforcement plan, and apply currently-active shields.
    private func refreshScreenTime() async {
        ScreenTimeRefresher.refresh()
    }
}
