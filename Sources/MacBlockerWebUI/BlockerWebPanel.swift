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
    private let onSnoozePress: ((String) -> Void)?
    private let onPanelEvent: ((String, [String: String]) -> Void)?
    @State private var lastRunMessage: String?

    public init(
        store: BlockerWebStore = BlockerWebStore(),
        appInventoryJSON: (() -> String?)? = nil,
        ruleLogJSON: (() -> String?)? = nil,
        onStorePersisted: (() -> Void)? = nil,
        onSnoozePress: ((String) -> Void)? = nil,
        onPanelEvent: ((String, [String: String]) -> Void)? = nil
    ) {
        self.store = store
        self.appInventoryJSON = appInventoryJSON
        self.ruleLogJSON = ruleLogJSON
        self.onStorePersisted = onStorePersisted
        self.onSnoozePress = onSnoozePress
        self.onPanelEvent = onPanelEvent
    }

    public var body: some View {
        BlockerWebView(
            store: store,
            appInventoryJSON: appInventoryJSON,
            ruleLogJSON: ruleLogJSON,
            onStorePersisted: onStorePersisted,
            onRunCustomGroup: { groupID, source in
                loadIntoPolicyRuntime(groupID: groupID, source: source)
            },
            onSnoozePress: onSnoozePress,
            onPanelEvent: onPanelEvent
        )
        .ignoresSafeArea()
    }

    private func loadIntoPolicyRuntime(groupID: String, source: String) {
        do {
            let runtime = try CustomJavaScriptPolicyRuntime()
            try runtime.load(groupID: groupID, source: source)
            lastRunMessage = "Loaded rule for \(groupID)."
        } catch {
            lastRunMessage = "Rule load failed: \(error)"
        }
    }
}
#endif
