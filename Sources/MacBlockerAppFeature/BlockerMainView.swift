import SwiftUI
import MacBlockerWebUI
#if os(macOS)
import AppKit
import MacBlockerMacControl
import VaultClassifierApp
#endif

/// Top-level app surface. Hosts the ported customBlocker editor in a WKWebView
/// with macOS enforcement wired up, and — on macOS — the Vault Classifier as a
/// second page of the same window.
@MainActor
public struct BlockerMainView: View {
    @StateObject private var enforcement = MacEnforcementBridge()
    #if os(macOS)
    @StateObject private var permission = AppBlockingPermissionModel()
    // The hub is owned at the app-delegate (process) level, not by this view, so
    // it outlives any single editor window. The view only reads its status for
    // contextual per-group availability.
    private let connection = ConnectionHub.shared
    #endif

    #if os(macOS)
    /// The window's pages. All stay alive while hidden, so switching never
    /// reloads the editor, the classifier, or the activity dashboard.
    fileprivate enum Page: String, Hashable, CaseIterable {
        case vault, classifier, activity
    }
    @State private var page: Page = .vault
    #endif

    public init() {}

    public var body: some View {
        #if os(macOS)
        // The three scenes share one window; each scene's own web header carries
        // the Vault/Classifier/Activity switch, which posts a notification the
        // shell listens for. All stay alive while hidden, so switching never
        // reloads the editor, the classifier, or the activity dashboard.
        ZStack {
            // WKWebViews don't reliably honor SwiftUI .opacity, so the active
            // page is also brought to front with zIndex: an opaque, full-bleed
            // web view on top covers the (still-alive) hidden ones.
            editorContent
                .opacity(page == .vault ? 1 : 0)
                .allowsHitTesting(page == .vault)
                .zIndex(page == .vault ? 1 : 0)
            ClassifierPageView()
                .opacity(page == .classifier ? 1 : 0)
                .allowsHitTesting(page == .classifier)
                .zIndex(page == .classifier ? 1 : 0)
            ActivityPageView()
                .opacity(page == .activity ? 1 : 0)
                .allowsHitTesting(page == .activity)
                .zIndex(page == .activity ? 1 : 0)
        }
        .onAppear { enforcement.start() }
        .onDisappear { enforcement.stop() }
        .onReceive(NotificationCenter.default.publisher(for: .vaultSwitchScene)) { note in
            guard let raw = note.userInfo?["scene"] as? String, let next = Page(rawValue: raw) else { return }
            page = next
        }
        #else
        VStack(spacing: 0) {
            editorContent
        }
        #endif
    }

    private var editorContent: some View {
        #if canImport(WebKit)
        #if os(macOS)
        return BlockerWebPanel(
            store: enforcement.webStore,
            appInventoryJSON: { MacAppInventoryJSON.make() },
            ruleLogJSON: { [weak enforcement] in enforcement?.drainLogJSON() },
            onStorePersisted: { enforcement.refresh() },
            onRunCustomGroup: { [weak enforcement] groupID, _ in enforcement?.runRule(groupID: groupID) },
            onSnoozePress: { [weak enforcement] groupID in enforcement?.fireSnoozePress(groupID: groupID) },
            onPanelEvent: { [weak enforcement] groupID, data in enforcement?.firePanelEvent(groupID: groupID, data: data) },
            onShowSystemPanel: { [weak enforcement] json in enforcement?.showSystemPanel(json: json) },
            onDismissSystemPanel: { [weak enforcement] id in enforcement?.dismissSystemPanel(id: id) },
            systemPanelEventsJSON: { [weak enforcement] in enforcement?.drainSystemPanelEventsJSON() },
            permissionStateJSON: { "{\"appBlockingGranted\":\(MacPermissionState.current().accessibilityTrusted)}" },
            onRequestAppBlockingPermission: { [weak permission] in permission?.requestGrant() },
            onOpenPermissionSettings: { [weak permission] in permission?.openSettings() },
            connectionStatusJSON: { [weak connection] in connection?.currentStatusJSON() },
            clustersJSON: { [weak connection] in connection?.clustersJSON() },
            groupRejectionJSON: { [weak connection] in connection?.takeLocalRejectionJSON() },
            onGroupsAnnounce: { [weak connection] json in connection?.announceFromBridge(json: json) },
            onGroupConnect: { [weak connection] json in connection?.connectFromBridge(json: json) },
            onGroupDisconnect: { [weak connection] json in connection?.disconnectFromBridge(json: json) },
            onGroupSync: { [weak connection] json in connection?.syncFromBridge(json: json) }
        )
        #else
        return BlockerWebPanel()
        #endif
        #else
        return Text("WebKit is unavailable on this platform.")
        #endif
    }
}

#if os(macOS)
/// The Vault Classifier page. The classifier component owns one live web view
/// per process (started by the app delegate at launch); this only embeds it.
private struct ClassifierPageView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        VaultClassifierPage.shared.makeView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// The Activity dashboard page (configured with the shared store at launch).
private struct ActivityPageView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        ActivityPage.shared.makeView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Backs the web grant modal / Device Control settings actions. It owns no UI
/// state: the modal is shown on app open (driven natively in BlockerWebView)
/// and the Device Control section is kept in sync by the per-tick state push.
@MainActor
final class AppBlockingPermissionModel: ObservableObject {
    /// Requests Accessibility through macOS, then reveals the exact settings
    /// pane where the user can grant it if it is still unavailable.
    func requestGrant() {
        let permission = MacPermissionState.current(promptForAccessibility: true)
        guard !permission.accessibilityTrusted else { return }
        openSettings()
    }

    /// Opens the Accessibility privacy pane in System Settings.
    func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
#endif
