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

    public init(
        store: BlockerWebStore = BlockerWebStore(),
        appInventoryJSON: (() -> String?)? = nil,
        ruleLogJSON: (() -> String?)? = nil,
        onStorePersisted: (() -> Void)? = nil,
        onRunCustomGroup: ((String, String) -> Void)? = nil,
        onSnoozePress: ((String) -> Void)? = nil,
        onPanelEvent: ((String, [String: String]) -> Void)? = nil
    ) {
        self.store = store
        self.appInventoryJSON = appInventoryJSON
        self.ruleLogJSON = ruleLogJSON
        self.onStorePersisted = onStorePersisted
        self.onRunCustomGroup = onRunCustomGroup
        self.onSnoozePress = onSnoozePress
        self.onPanelEvent = onPanelEvent
    }

    public var body: some View {
        BlockerWebView(
            store: store,
            appInventoryJSON: appInventoryJSON,
            ruleLogJSON: ruleLogJSON,
            onStorePersisted: onStorePersisted,
            onRunCustomGroup: onRunCustomGroup,
            onSnoozePress: onSnoozePress,
            onPanelEvent: onPanelEvent
        )
        .ignoresSafeArea()
    }
}
#endif
