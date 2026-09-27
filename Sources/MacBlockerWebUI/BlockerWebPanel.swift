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
    private let clustersJSON: (() -> String?)?
    private let onLinkRequest: ((String, [String: Any]) -> String?)?
    private let tagNames: ((String) -> [String])?

    public init(
        store: BlockerWebStore = BlockerWebStore(),
        appInventoryJSON: (() -> String?)? = nil,
        ruleLogJSON: (() -> String?)? = nil,
        onStorePersisted: (() -> Void)? = nil,
        onRunCustomGroup: ((String, String) -> Void)? = nil,
        onSnoozePress: ((String) -> Void)? = nil,
        clustersJSON: (() -> String?)? = nil,
        onLinkRequest: ((String, [String: Any]) -> String?)? = nil,
        tagNames: ((String) -> [String])? = nil
    ) {
        self.store = store
        self.appInventoryJSON = appInventoryJSON
        self.ruleLogJSON = ruleLogJSON
        self.onStorePersisted = onStorePersisted
        self.onRunCustomGroup = onRunCustomGroup
        self.onSnoozePress = onSnoozePress
        self.clustersJSON = clustersJSON
        self.onLinkRequest = onLinkRequest
        self.tagNames = tagNames
    }

    public var body: some View {
        BlockerWebView(
            store: store,
            appInventoryJSON: appInventoryJSON,
            ruleLogJSON: ruleLogJSON,
            onStorePersisted: onStorePersisted,
            onRunCustomGroup: onRunCustomGroup,
            onSnoozePress: onSnoozePress,
           
            clustersJSON: clustersJSON,
            onLinkRequest: onLinkRequest,
            tagNames: tagNames
        )
        .ignoresSafeArea()
    }
}
#endif
