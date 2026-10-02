import Foundation

/// Resolve app-local SwiftPM resources after a build is relocated. Generated
/// Bundle.module accessors embed the build path and omit macOS app Resources.
/// Use packaged files directly so a missing bundle becomes a normal error.
public enum VaultBundledResources {
    public static func directory(target: String, subdirectory: String) -> URL? {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0], relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)).standardizedFileURL
        let runtimeBundles = Bundle.allBundles.flatMap { [$0.resourceURL, $0.bundleURL, $0.bundleURL.deletingLastPathComponent()] }.compactMap { $0 }
        let roots = [Bundle.main.resourceURL, Bundle.main.bundleURL,
                     Bundle.main.bundleURL.deletingLastPathComponent(),
                     executable.deletingLastPathComponent(),
                     executable.deletingLastPathComponent().deletingLastPathComponent()]
            .compactMap { $0 } + runtimeBundles
        return directory(target: target, subdirectory: subdirectory, roots: roots)
    }

    static func directory(target: String, subdirectory: String, roots: [URL]) -> URL? {
        guard target.range(of: "^[A-Za-z0-9_]+$", options: .regularExpression) != nil,
              subdirectory.range(of: "^[A-Za-z0-9_]+$", options: .regularExpression) != nil else { return nil }
        for root in roots {
            for suffix in ["bundle", "resources"] {
                let directory = root.appendingPathComponent("VaultClassifier_\(target).\(suffix)", isDirectory: true)
                    .appendingPathComponent(subdirectory, isDirectory: true)
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue { return directory }
            }
        }
        return nil
    }
}
