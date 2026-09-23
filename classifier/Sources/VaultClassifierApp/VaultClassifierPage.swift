import AppKit
import WebKit
import VaultClassifierBridge
import VaultClassifierCore

/// The one public surface of the classifier component. Its host (Mac Vault, or
/// the standalone development shell) starts the tagging service once per
/// process and embeds the page's view wherever it wants it; everything else in
/// this module stays internal.
@MainActor
public final class VaultClassifierPage {
    public static let shared = VaultClassifierPage()

    private var model: VaultClassifierViewModel?
    private var webShell: VaultClassifierWebShell?
    private var webView: WKWebView?
    private var pageVisible = true

    /// Installed by the host (Mac Vault) so the classifier's in-page header
    /// switch can ask it to show another scene. The argument is the requested
    /// scene name (e.g. "vault", "activity"); the classifier is otherwise
    /// unaware of the host's other pages. Nil in the standalone/test contexts.
    public static var hostNavigationHandler: ((String) -> Void)?

    private init() {}

    public func start() {
        guard model == nil else { return }
        // A packaged production app registers its browser helper itself (there is
        // no installer); a no-op in development and for un-bundled builds.
        NativeMessagingHostRegistration.registerBundledHost()
        model = VaultClassifierViewModel()
    }

    /// The page. One web view exists per process; each call hands it to a fresh
    /// container, so a host that rebuilds its view hierarchy re-parents the same
    /// live page instead of reloading it.
    public func makeView() -> NSView {
        start()
        if webView == nil, let model {
            let shell = VaultClassifierWebShell(model: model)
            let view = shell.makeWebView()
            // The page is designed on Mac Vault's light working surface.
            view.appearance = NSAppearance(named: .aqua)
            shell.setPresentationVisible(pageVisible)
            webShell = shell
            webView = view
        }
        let container = NSView()
        guard let webView else { return container }
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
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

    /// State writes are coalesced onto a background queue; the host calls this
    /// on a clean quit so the newest write is never dropped.
    public func flushPendingWrites() {
        LocalStateFile.flushAllPendingWrites()
    }
}
