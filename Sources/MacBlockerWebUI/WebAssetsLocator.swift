import Foundation

public enum WebAssetsLocator {
    public static var assetsDirectory: URL? {
        Bundle.module.resourceURL?.appendingPathComponent("WebAssets", isDirectory: true)
    }

    public static var popupURL: URL? {
        guard let dir = assetsDirectory else {
            return nil
        }
        let url = dir.appendingPathComponent("popup.html", isDirectory: false)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
