import SwiftUI
import MacBlockerWebUI
#if os(macOS)
import MacBlockerMacControl
#endif

/// Top-level app surface. Hosts the ported customBlocker editor in a WKWebView
/// with macOS enforcement wired up.
@MainActor
public struct BlockerMainView: View {
    @StateObject private var enforcement = MacEnforcementBridge()
    #if os(macOS)
    @State private var permissionState = MacPermissionState.current()
    #endif

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            if !permissionState.accessibilityTrusted {
                PermissionBanner(
                    message: "Accessibility permission is required for browser tab control and app blocking.",
                    buttonTitle: "Grant Access"
                ) {
                    permissionState = MacPermissionState.current(promptForAccessibility: true)
                }
            }
            #endif
            editorContent
        }
        #if os(macOS)
        .onAppear {
            permissionState = MacPermissionState.current(promptForAccessibility: true)
            enforcement.start()
        }
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
            onPanelEvent: { [weak enforcement] groupID, data in enforcement?.firePanelEvent(groupID: groupID, data: data) }
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
private struct PermissionBanner: View {
    let message: String
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(.primary)
            Spacer()
            Button(buttonTitle) { action() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.1))
    }
}
#endif
