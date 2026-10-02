import Foundation

public enum VaultClassifierBundledAssets {
    public static func url(named name: String, extension fileExtension: String) -> URL? {
        Bundle.module.url(forResource: name, withExtension: fileExtension, subdirectory: "WebAssets")
    }
}
