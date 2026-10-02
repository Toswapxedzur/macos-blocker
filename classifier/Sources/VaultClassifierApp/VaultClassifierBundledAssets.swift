import Foundation
import VaultClassifierCore

public enum VaultClassifierBundledAssets {
    public static var directory: URL? {
        VaultBundledResources.directory(target: "VaultClassifierApp", subdirectory: "WebAssets")
    }

    public static func url(named name: String, extension fileExtension: String) -> URL? {
        guard name.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil,
              fileExtension.range(of: "^[A-Za-z0-9]+$", options: .regularExpression) != nil,
              let directory else { return nil }
        let file = directory.appendingPathComponent(name + "." + fileExtension)
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }
}
