#if canImport(WebKit)
import Foundation
import WebKit

/// Posted (userInfo `["scene": "vault"|"classifier"|"activity"]`) when the page
/// shows a scene. Mac Vault has one web view and one document; the switch
/// happens inside the page (scenes.js), and the native side only follows along
/// (the Classifier pauses its snapshots while hidden, Activity refreshes).
public extension Notification.Name {
    static let vaultSceneShown = Notification.Name("VaultSceneShown")
}

/// A scene that shares the editor's web view and document (Mac Vault's
/// Classifier and Activity). The host installs its message handlers and URL
/// schemes before the web view exists, serves its web files under
/// `assetsPrefix`, and hands it the web view once created.
@MainActor
public struct WebScene {
    /// Its web files, served at "cbasset://app/<assetsPrefix>/…" (nil = the
    /// scene's files are part of the editor's own assets).
    public let assetsPrefix: String?
    public let assetsDirectory: URL?
    public let install: @MainActor (WKWebViewConfiguration) -> Void
    public let attach: @MainActor (WKWebView) -> Void
    /// The page was reloaded after its web content process died.
    public let reloaded: @MainActor () -> Void

    public init(
        assetsPrefix: String? = nil,
        assetsDirectory: URL? = nil,
        install: @escaping @MainActor (WKWebViewConfiguration) -> Void,
        attach: @escaping @MainActor (WKWebView) -> Void,
        reloaded: @escaping @MainActor () -> Void = {}
    ) {
        self.assetsPrefix = assetsPrefix
        self.assetsDirectory = assetsDirectory
        self.install = install
        self.attach = attach
        self.reloaded = reloaded
    }
}
#endif
