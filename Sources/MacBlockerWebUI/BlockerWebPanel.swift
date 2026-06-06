#if canImport(WebKit)
import SwiftUI
import MacBlockerCore

/// The full ported editor UI, ready to drop into any SwiftUI scene on iOS,
/// iPadOS, or macOS. This is the faithful customBlocker popup running inside a
/// WKWebView, backed by the native policy core.
public struct BlockerWebPanel: View {
    private let store: BlockerWebStore
    private let appInventoryJSON: (() -> String?)?
    private let onStorePersisted: (() -> Void)?
    @State private var lastRunMessage: String?

    public init(
        store: BlockerWebStore = BlockerWebStore(),
        appInventoryJSON: (() -> String?)? = nil,
        onStorePersisted: (() -> Void)? = nil
    ) {
        self.store = store
        self.appInventoryJSON = appInventoryJSON
        self.onStorePersisted = onStorePersisted
    }

    public var body: some View {
        BlockerWebView(
            store: store,
            appInventoryJSON: appInventoryJSON,
            onStorePersisted: onStorePersisted
        ) { groupID, source in
            loadIntoPolicyRuntime(groupID: groupID, source: source)
        }
        .ignoresSafeArea()
    }

    private func loadIntoPolicyRuntime(groupID: String, source: String) {
        // When the user presses Run, also load the rule into the native
        // policy runtime so the same JavaScript drives shield decisions.
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
