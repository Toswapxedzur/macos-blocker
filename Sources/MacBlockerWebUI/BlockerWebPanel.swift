#if canImport(WebKit)
import SwiftUI
import MacBlockerCore

/// The full editor UI: the customBlocker popup running inside a WKWebView,
/// backed by the native policy core.
public struct BlockerWebPanel: View {
    private let store: BlockerWebStore
    private let appInventoryJSON: (() -> String?)?
    private let ruleLogJSON: (() -> String?)?
    private let onStorePersisted: (() -> Void)?
    private let onRunCustomGroup: ((String, String) -> Void)?
    private let onSnoozePress: ((String) -> Void)?
    private let onPanelEvent: ((String, [String: String]) -> Void)?
    private let onShowSystemPanel: ((String) -> Void)?
    private let onDismissSystemPanel: ((String) -> Void)?
    private let systemPanelEventsJSON: (() -> String?)?
    private let clustersJSON: (() -> String?)?
    private let onGroupSync: ((String) -> Void)?

    public init(
        store: BlockerWebStore = BlockerWebStore(),
        appInventoryJSON: (() -> String?)? = nil,
        ruleLogJSON: (() -> String?)? = nil,
        onStorePersisted: (() -> Void)? = nil,
        onRunCustomGroup: ((String, String) -> Void)? = nil,
        onSnoozePress: ((String) -> Void)? = nil,
        onPanelEvent: ((String, [String: String]) -> Void)? = nil,
        onShowSystemPanel: ((String) -> Void)? = nil,
        onDismissSystemPanel: ((String) -> Void)? = nil,
        systemPanelEventsJSON: (() -> String?)? = nil,
        clustersJSON: (() -> String?)? = nil,
        onGroupSync: ((String) -> Void)? = nil
    ) {
        self.store = store
        self.appInventoryJSON = appInventoryJSON
        self.ruleLogJSON = ruleLogJSON
        self.onStorePersisted = onStorePersisted
        self.onRunCustomGroup = onRunCustomGroup
        self.onSnoozePress = onSnoozePress
        self.onPanelEvent = onPanelEvent
        self.onShowSystemPanel = onShowSystemPanel
        self.onDismissSystemPanel = onDismissSystemPanel
        self.systemPanelEventsJSON = systemPanelEventsJSON
        self.clustersJSON = clustersJSON
        self.onGroupSync = onGroupSync
    }

    public var body: some View {
        BlockerWebView(
            store: store,
            appInventoryJSON: appInventoryJSON,
            ruleLogJSON: ruleLogJSON,
            onStorePersisted: onStorePersisted,
            onRunCustomGroup: onRunCustomGroup,
            onSnoozePress: onSnoozePress,
            onPanelEvent: onPanelEvent,
            onShowSystemPanel: onShowSystemPanel,
            onDismissSystemPanel: onDismissSystemPanel,
            systemPanelEventsJSON: systemPanelEventsJSON,
            clustersJSON: clustersJSON,
            onGroupSync: onGroupSync
        )
        .ignoresSafeArea()
    }
}
#endif
