#if canImport(WebKit)
import Foundation
import WebKit

/// Serves the bundled WebAssets over a custom URL scheme so the editor's
/// `fetch()` calls (translation/*.json, manual/*.md) work. WKWebView blocks
/// `fetch()` against `file://` URLs, which is why those silently failed and the
/// UI showed raw i18n keys with no manual. A custom scheme is treated like a
/// network origin, so fetch succeeds — and it's App Store safe (no private
/// `allowFileAccessFromFileURLs` hacks).
public final class WebAssetSchemeHandler: NSObject, WKURLSchemeHandler {
    public static let scheme = "cbasset"
    public static let host = "app"

    /// Base URL of the page loaded through this handler.
    public static var indexURL: URL {
        URL(string: "\(scheme)://\(host)/popup.html")!
    }

    /// Virtual path (not on disk) that serves the installed-application
    /// inventory JSON for the app picker. Served dynamically so we avoid
    /// injecting multi-megabyte icon payloads as a user script.
    public static let inventoryPath = "app-inventory.json"

    private let assetsDirectory: URL
    private let inventoryJSONProvider: (() -> String?)?

    public init(
        assetsDirectory: URL,
        inventoryJSONProvider: (() -> String?)? = nil
    ) {
        self.assetsDirectory = assetsDirectory.standardizedFileURL
        self.inventoryJSONProvider = inventoryJSONProvider
    }

    public func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(Self.error("No URL"))
            return
        }

        // Dynamic virtual resource: the app inventory.
        if url.path == "/\(Self.inventoryPath)" {
            let json = inventoryJSONProvider?() ?? "[]"
            let data = Data(json.utf8)
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": "application/json; charset=utf-8",
                    "Content-Length": String(data.count),
                    "Access-Control-Allow-Origin": "*",
                    "Cache-Control": "no-cache"
                ]
            )!
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
            return
        }

        // Map "cbasset://app/<path>" -> <assetsDirectory>/<path>, defaulting to
        // popup.html. Strip query/fragment so fetches with cache-busting work.
        var relativePath = url.path
        if relativePath.hasPrefix("/") {
            relativePath.removeFirst()
        }
        if relativePath.isEmpty {
            relativePath = "popup.html"
        }

        let fileURL = assetsDirectory
            .appendingPathComponent(relativePath)
            .standardizedFileURL

        // Prevent path traversal outside the assets directory.
        guard fileURL.path.hasPrefix(assetsDirectory.path),
              let data = try? Data(contentsOf: fileURL) else {
            urlSchemeTask.didFailWithError(Self.error("Not found: \(relativePath)"))
            return
        }

        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": Self.mimeType(for: fileURL.pathExtension),
                "Content-Length": String(data.count),
                "Access-Control-Allow-Origin": "*",
                "Cache-Control": "no-cache"
            ]
        )!

        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    public func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // Synchronous handler; nothing to cancel.
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "WebAssetSchemeHandler", code: 404, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        case "md", "markdown", "txt": return "text/plain; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "ttf": return "font/ttf"
        default: return "application/octet-stream"
        }
    }
}
#endif
