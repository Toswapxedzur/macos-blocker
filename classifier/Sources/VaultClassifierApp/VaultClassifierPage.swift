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

    private init() {}

    /// Opt this process in to hosting the local hub. The classifier defaults to
    /// NOT hosting so that, embedded in Mac Vault, it never races ConnectionHub
    /// (the sole host, which owns activity + MCP handling) for the fixed port —
    /// it only joins as a client. The standalone development shell, which has no
    /// ConnectionHub, calls this before building the page so it hosts its own
    /// hub. Must be called before `start()`/`makeView()`.
    public func allowOwnHubHosting() {
        LocalClassifierHub.shared.allowHosting()
    }

    /// Back-compat no-op-ish suppressor. Hosting is already off by default;
    /// Mac Vault need not call this, but doing so stays safe (it also tears down
    /// any listener that somehow started).
    public func suppressOwnHubHosting() {
        LocalClassifierHub.shared.suppressHosting()
    }

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

    /// State writes are coalesced onto a background queue; the host calls this
    /// on a clean quit so the newest write is never dropped.
    public func flushPendingWrites() {
        LocalStateFile.flushAllPendingWrites()
    }
}
