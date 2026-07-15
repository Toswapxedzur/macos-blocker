import SwiftUI
import MacBlockerWebUI
#if os(macOS)
import AppKit
import MacBlockerMacControl
#endif

/// Top-level app surface. Hosts the ported customBlocker editor in a WKWebView
/// with macOS enforcement wired up.
@MainActor
public struct BlockerMainView: View {
    @StateObject private var enforcement = MacEnforcementBridge()
    #if os(macOS)
    @StateObject private var permission = AppBlockingPermissionModel()
    // The hub is owned at the app-delegate (process) level, not by this view, so
    // it outlives any single editor window. The view only reads its status and
    // drives the user-initiated start/stop toggle.
    private let connection = ConnectionHub.shared
    #endif

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            editorContent
        }
        #if os(macOS)
        .onAppear { enforcement.start() }
        .onDisappear { enforcement.stop() }
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
            onConnectionServerStart: { [weak connection] _ in connection?.start() },
            onConnectionServerStop: { [weak connection] in connection?.stop() },
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
