#if canImport(WebKit)
import SwiftUI
import MacBlockerCore

/// The full editor UI: the customBlocker popup running inside a WKWebView,
/// backed by the native policy core; Mac Vault's other scenes share it.
public struct BlockerWebPanel: View {
    private let store: BlockerWebStore
    private let appInventoryJSON: (() -> String?)?
    private let ruleLogJSON: (() -> String?)?
    private let onClearRuleLog: ((String) -> Void)?
    private let onStorePersisted: (() -> Void)?
    private let onRunCustomGroup: ((String, String) -> [String: Any])?
    private let onSnoozePress: ((String) -> Void)?
    private let clustersJSON: (() -> String?)?
    private let onLinkRequest: ((String, [String: Any]) -> String?)?
    private let tagNames: ((String) -> [String])?
    private let scenes: [WebScene]

    public init(
        store: BlockerWebStore = BlockerWebStore(),
        appInventoryJSON: (() -> String?)? = nil,
        ruleLogJSON: (() -> String?)? = nil,
        onClearRuleLog: ((String) -> Void)? = nil,
        onStorePersisted: (() -> Void)? = nil,
        onRunCustomGroup: ((String, String) -> [String: Any])? = nil,
        onSnoozePress: ((String) -> Void)? = nil,
        clustersJSON: (() -> String?)? = nil,
        onLinkRequest: ((String, [String: Any]) -> String?)? = nil,
        tagNames: ((String) -> [String])? = nil,
        scenes: [WebScene] = []
    ) {
        self.store = store
        self.appInventoryJSON = appInventoryJSON
        self.ruleLogJSON = ruleLogJSON
        self.onClearRuleLog = onClearRuleLog
        self.onStorePersisted = onStorePersisted
        self.onRunCustomGroup = onRunCustomGroup
        self.onSnoozePress = onSnoozePress
        self.clustersJSON = clustersJSON
        self.onLinkRequest = onLinkRequest
        self.tagNames = tagNames
        self.scenes = scenes
    }

    public var body: some View {
        BlockerWebView(
            store: store,
            appInventoryJSON: appInventoryJSON,
            ruleLogJSON: ruleLogJSON, onClearRuleLog: onClearRuleLog,
            onStorePersisted: onStorePersisted,
            onRunCustomGroup: onRunCustomGroup,
            onSnoozePress: onSnoozePress,
            clustersJSON: clustersJSON,
            onLinkRequest: onLinkRequest,
            tagNames: tagNames,
            scenes: scenes
        )
        .ignoresSafeArea()
    }
}
#endif
