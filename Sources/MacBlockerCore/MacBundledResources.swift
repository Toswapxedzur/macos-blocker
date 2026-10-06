import Foundation

/// SwiftPM's generated Bundle.module accessor omits a packaged Mac app's
/// Contents/Resources and fatally traps when its original build folder is gone.
/// Resolve deployed resources first, without depending on that build folder.
public enum MacBundledResources {
    public static func directory(target: String, subdirectory: String) -> URL? {
        let roots = [Bundle.main.resourceURL, Bundle.main.bundleURL,
                     Bundle.main.executableURL?.deletingLastPathComponent()]
            .compactMap { $0 }
        let testRoots = Bundle.allBundles.flatMap { [$0.resourceURL, $0.bundleURL.deletingLastPathComponent()] }.compactMap { $0 }
        return directory(target: target, subdirectory: subdirectory, roots: roots + testRoots)
    }

    static func directory(target: String, subdirectory: String, roots: [URL]) -> URL? {
        for root in roots {
            let url = root.appendingPathComponent("macosBlocker_\(target).bundle", isDirectory: true)
                .appendingPathComponent(subdirectory, isDirectory: true)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return url
            }
        }
        return nil
    }
}
