import AppKit
import WebKit
import VaultClassifierBridge
import VaultClassifierCore

/// The one public surface of the classifier component. Its host (Mac Vault)
/// starts the tagging service once per process and runs the page as a scene of
/// its own web view; everything else in this module stays internal.
@MainActor
public final class VaultClassifierPage {
    public static let shared = VaultClassifierPage()

    private var model: VaultClassifierViewModel?
    private var webShell: VaultClassifierWebShell?
    private var pageVisible = true

    private init() {}

    public func start() {
        guard model == nil else { return }
        // A packaged production app registers its browser helper itself (there is
        // no installer); a no-op in development and for un-bundled builds.
        NativeMessagingHostRegistration.registerBundledHost()
        model = VaultClassifierViewModel()
    }

    // MARK: The page, as a scene of the host's web view

    /// The page's web files (app.js, app.css, strings.js); the host serves
    /// them to its document.
    public static var webAssetsDirectory: URL? { VaultClassifierWebShell.webAssetsDirectory }

    /// Before the host creates its web view: the page's message handler and
    /// URL scheme.
    public func install(in configuration: WKWebViewConfiguration) {
        start()
        guard let model else { return }
        let shell = webShell ?? VaultClassifierWebShell(model: model)
        webShell = shell
        shell.install(in: configuration)
        shell.setPresentationVisible(pageVisible)
    }

    /// The host's web view, where the page runs.
    public func attach(_ webView: WKWebView) {
        webShell?.attach(webView)
    }

    /// The host reloaded its page after the web content process died.
    public func pageReloaded() {
        webShell?.pageReloaded()
    }

    /// The host reports whether the page is in front. While hidden, the page
    /// skips building and pushing its web snapshot (≈150 ms of main-thread work
    /// per classification burst) and catches up once when shown again.
    /// `VAULT_SNAPSHOT_ALWAYS=1` keeps the old always-render behaviour for
    /// latency comparisons.
    public func setPageVisible(_ visible: Bool) {
        pageVisible = visible || ProcessInfo.processInfo.environment["VAULT_SNAPSHOT_ALWAYS"] == "1"
        webShell?.setPresentationVisible(pageVisible)
    }

    // MARK: MCP surface (parity with the page: same snapshot, same actions)

    /// The web actions a process may run, with the data keys each reads.
    public nonisolated static var mcpActionCatalog: [ClassifierWebActionDescriptor] { ClassifierWebActionCatalog.actions }

    /// The page's state: nil section = compact overview, "all" = the whole
    /// snapshot, a section name = that part. nil result = unknown section.
    public func mcpSnapshot(section: String?) -> [String: Any]? {
        start()
        return model?.mcpSnapshot(section: section)
    }

    /// A platform's tag names (the editor's tag suggestions), each once.
    public func tagNames(platformID: String) -> [String] {
        start()
        var seen = Set<String>()
        return (model?.taxonomy(platformID: platformID) ?? []).flatMap(\.tags).map(\.name)
            .filter { seen.insert($0.lowercased()).inserted }
    }

    /// What the classifier knows about watched videos (Mac Vault's Activity):
    /// watched key ("youtube:<id>" / "bilibili:<BV id>") → its author's name and
    /// its tags (id, name, colour), for the keys it has seen. JSON-ready.
    public func watchedFacts(keys: [String]) -> [String: Any] {
        start()
        return model?.watchedFacts(keys: keys) ?? [:]
    }

    /// Runs one page action with the page's own validation; returns the issue
    /// the page would show (nil = success) and whether it would re-render.
    public func mcpPerform(action: String, data: [String: Any]) -> ClassifierMCPActionOutcome {
        start()
        guard let model else { return .init(rerender: false, issue: "classifier not started") }
        let outcome = model.mcpPerform(action: action, data: data)
        // The page's own buttons trigger a re-render through the web shell; an
        // MCP-driven change must reach the open page the same way.
        if outcome.rerender { model.onWebStateChange?() }
        return outcome
    }

    /// State writes are coalesced onto a background queue; the host calls this
    /// on a clean quit so the newest write is never dropped.
    public func flushPendingWrites() {
        LocalStateFile.flushAllPendingWrites()
    }
}
