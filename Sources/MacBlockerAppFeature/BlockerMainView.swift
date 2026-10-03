import SwiftUI
import MacBlockerWebUI
#if os(macOS)
import AppKit
import MacBlockerMacControl
import VaultClassifierApp
#endif

/// Top-level app surface: one WKWebView, one document. The ported customBlocker
/// editor (the Vault scene) with macOS enforcement wired up, and — on macOS —
/// the Classifier and Activity scenes beside it in the same page.
@MainActor
public struct BlockerMainView: View {
    /// The process-wide engine: it runs from launch to quit, not with this
    /// window (closing the window keeps blocking; quitting stops it).
    @ObservedObject private var enforcement = MacEnforcementBridge.shared
    #if os(macOS)
    // The hub is owned at the app-delegate (process) level, not by this view, so
    // it outlives any single editor window. The view only reads its status for
    // contextual per-group availability.
    private let connection = ConnectionHub.shared
    #endif

    public init() {}

    public var body: some View {
        #if os(macOS)
        // The scenes switch inside the page (scenes.js); the native side only
        // follows: the Classifier builds snapshots only while it shows, and
        // Activity refreshes when it comes to the front.
        editorContent
            .onAppear {
                enforcement.start()
                VaultClassifierPage.shared.setPageVisible(false)
            }
            .onReceive(NotificationCenter.default.publisher(for: .vaultSceneShown)) { note in
                let scene = note.userInfo?["scene"] as? String
                VaultClassifierPage.shared.setPageVisible(scene == "classifier" || scene == "settings")
                if scene == "activity" { ActivityPage.shared.sceneShown() }
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
            onClearRuleLog: { [weak enforcement] groupID in enforcement?.clearRuleLog(groupID: groupID) },
            onStorePersisted: { enforcement.refresh(); QuickAddPanel.shared.reload() },
            onRunCustomGroup: { [weak enforcement] groupID, source in enforcement?.runRule(groupID: groupID, source: source) ?? ["ok": false] },
            onSnoozePress: { [weak enforcement] groupID in enforcement?.fireSnoozePress(groupID: groupID) },
            clustersJSON: { [weak connection] in connection?.clustersJSON() },
            onLinkRequest: { [weak connection] kind, message in
                guard let connection else { return "macapp-unavailable" }
                let groupId = (message["groupId"] as? String) ?? ""
                return kind == "group-link"
                    ? connection.linkGroups(program: ConnectionHub.localProgram, groupId: groupId,
                                            targetProgram: (message["targetProgram"] as? String) ?? "",
                                            targetGroupId: (message["targetGroupId"] as? String) ?? "")
                    : connection.unlinkGroup(program: ConnectionHub.localProgram, groupId: groupId)
            },
            tagNames: { platform in MainActor.assumeIsolated { VaultClassifierPage.shared.tagNames(platformID: platform) } },
            scenes: [
                WebScene(
                    assetsPrefix: "classifier",
                    assetsDirectory: VaultClassifierPage.webAssetsDirectory,
                    install: { VaultClassifierPage.shared.install(in: $0) },
                    attach: { VaultClassifierPage.shared.attach($0) },
                    reloaded: { VaultClassifierPage.shared.pageReloaded() }
                ),
                ActivityPage.shared.scene,
            ]
        )
        #else
        return BlockerWebPanel()
        #endif
        #else
        return Text("WebKit is unavailable on this platform.")
        #endif
    }
}

