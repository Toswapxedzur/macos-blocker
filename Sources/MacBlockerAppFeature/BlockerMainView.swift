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
    /// The process-wide engine: it runs from launch to quit, not with this
    /// window (closing the window keeps blocking; quitting stops it).
    @ObservedObject private var enforcement = MacEnforcementBridge.shared
    #if os(macOS)
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
        .onAppear {
            enforcement.start()
            VaultClassifierPage.shared.setPageVisible(page == .classifier)
        }
        .onReceive(NotificationCenter.default.publisher(for: .vaultSwitchScene)) { note in
            guard let raw = note.userInfo?["scene"] as? String, let next = Page(rawValue: raw) else { return }
            page = next
            // The hidden classifier page stops rebuilding its web snapshot.
            VaultClassifierPage.shared.setPageVisible(next == .classifier)
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
            onStorePersisted: { enforcement.refresh(); QuickAddPanel.shared.reload() },
            onRunCustomGroup: { [weak enforcement] groupID, _ in enforcement?.runRule(groupID: groupID) },
            onSnoozePress: { [weak enforcement] groupID in enforcement?.fireSnoozePress(groupID: groupID) },
            onPanelEvent: { [weak enforcement] groupID, data in enforcement?.firePanelEvent(groupID: groupID, data: data) },
            onShowSystemPanel: { [weak enforcement] json in enforcement?.showSystemPanel(json: json) },
            onDismissSystemPanel: { [weak enforcement] id in enforcement?.dismissSystemPanel(id: id) },
            systemPanelEventsJSON: { [weak enforcement] in enforcement?.drainSystemPanelEventsJSON() },
            clustersJSON: { [weak connection] in connection?.clustersJSON() },
            onGroupsAnnounce: { [weak connection] json in connection?.announceFromBridge(json: json) },
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

#endif
