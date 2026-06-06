import SwiftUI
import MacBlockerAppFeature
import MacBlockerCore

@main
struct macosBlockerApp: App {
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
