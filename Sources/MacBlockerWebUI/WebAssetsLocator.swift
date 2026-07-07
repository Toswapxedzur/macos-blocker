import Foundation

public enum WebAssetsLocator {
    public static var assetsDirectory: URL? {
        let bundleName = "macosBlocker_MacBlockerWebUI.bundle"
        for baseURL in runtimeResourceBaseURLs() {
            let url = baseURL
                .appendingPathComponent(bundleName, isDirectory: true)
                .appendingPathComponent("WebAssets", isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return Bundle.module.resourceURL?.appendingPathComponent("WebAssets", isDirectory: true)
    }

    public static var popupURL: URL? {
        guard let dir = assetsDirectory else {
            return nil
        }
        let url = dir.appendingPathComponent("popup.html", isDirectory: false)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func runtimeResourceBaseURLs() -> [URL] {
        var urls: [URL] = []
        if let resourceURL = Bundle.main.resourceURL {
            urls.append(resourceURL)
        }
        urls.append(Bundle.main.bundleURL)
        if let executableURL = Bundle.main.executableURL {
            urls.append(executableURL.deletingLastPathComponent())
        }
        return urls
    }
}
