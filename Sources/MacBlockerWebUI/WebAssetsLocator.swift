import Foundation
import MacBlockerCore

public enum WebAssetsLocator {
    public static var assetsDirectory: URL? {
        MacBundledResources.directory(target: "MacBlockerWebUI", subdirectory: "WebAssets")
    }
}
