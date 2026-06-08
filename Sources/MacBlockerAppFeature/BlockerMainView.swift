import SwiftUI
import MacBlockerWebUI
#if os(macOS)
import MacBlockerMacControl
#endif

/// Top-level app surface. The primary tab is the faithful ported customBlocker
/// editor (running in a WKWebView); the second tab is the native policy/status
/// panel that shows how decisions map onto Screen Time / Mac controls.
@MainActor
public struct BlockerMainView: View {
    @StateObject private var enforcement = MacEnforcementBridge()

    public init() {}

    public var body: some View {
        TabView {
            editorTab
            statusTab
        }
        #if os(macOS)
        .onAppear { enforcement.start() }
        .onDisappear { enforcement.stop() }
        #endif
    }

    private var editorTab: some View {
        #if canImport(WebKit)
        #if os(macOS)
        return BlockerWebPanel(
            store: enforcement.webStore,
            appInventoryJSON: { MacAppInventoryJSON.make() },
            ruleLogJSON: { [weak enforcement] in enforcement?.drainLogJSON() },
            onStorePersisted: { enforcement.refresh() }
        )
        .tabItem {
            Label("Editor", systemImage: "slider.horizontal.3")
        }
        #else
        return BlockerWebPanel()
            .tabItem {
                Label("Editor", systemImage: "slider.horizontal.3")
            }
        #endif
        #else
        return Text("WebKit is unavailable on this platform.")
            .tabItem {
                Label("Editor", systemImage: "slider.horizontal.3")
            }
        #endif
    }

    private var statusTab: some View {
        MacBlockerRootView()
            .tabItem {
                Label("Status", systemImage: "shield")
            }
    }
}
