#if canImport(WebKit)
import SwiftUI
import MacBlockerCore

/// The full ported editor UI, ready to drop into any SwiftUI scene on iOS,
/// iPadOS, or macOS. This is the faithful customBlocker popup running inside a
/// WKWebView, backed by the native policy core.
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
    private let permissionStateJSON: (() -> String?)?
    private let onRequestAppBlockingPermission: (() -> Void)?
    private let onOpenPermissionSettings: (() -> Void)?
    private let connectionStatusJSON: (() -> String?)?
    private let clustersJSON: (() -> String?)?
    private let groupRejectionJSON: (() -> String?)?
    private let onGroupsAnnounce: ((String) -> Void)?
    private let onGroupConnect: ((String) -> Void)?
    private let onGroupDisconnect: ((String) -> Void)?
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
        permissionStateJSON: (() -> String?)? = nil,
        onRequestAppBlockingPermission: (() -> Void)? = nil,
        onOpenPermissionSettings: (() -> Void)? = nil,
        connectionStatusJSON: (() -> String?)? = nil,
        clustersJSON: (() -> String?)? = nil,
        groupRejectionJSON: (() -> String?)? = nil,
        onGroupsAnnounce: ((String) -> Void)? = nil,
        onGroupConnect: ((String) -> Void)? = nil,
        onGroupDisconnect: ((String) -> Void)? = nil,
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
        self.permissionStateJSON = permissionStateJSON
        self.onRequestAppBlockingPermission = onRequestAppBlockingPermission
        self.onOpenPermissionSettings = onOpenPermissionSettings
        self.connectionStatusJSON = connectionStatusJSON
        self.clustersJSON = clustersJSON
        self.groupRejectionJSON = groupRejectionJSON
        self.onGroupsAnnounce = onGroupsAnnounce
        self.onGroupConnect = onGroupConnect
        self.onGroupDisconnect = onGroupDisconnect
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
            permissionStateJSON: permissionStateJSON,
            onRequestAppBlockingPermission: onRequestAppBlockingPermission,
            onOpenPermissionSettings: onOpenPermissionSettings,
            connectionStatusJSON: connectionStatusJSON,
            clustersJSON: clustersJSON,
            groupRejectionJSON: groupRejectionJSON,
            onGroupsAnnounce: onGroupsAnnounce,
            onGroupConnect: onGroupConnect,
            onGroupDisconnect: onGroupDisconnect,
            onGroupSync: onGroupSync
        )
        .ignoresSafeArea()
    }
}
#endif
