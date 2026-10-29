import Foundation

/// SwiftPM's generated Bundle.module accessor omits a packaged Mac app's
/// Contents/Resources and fatally traps when its original build folder is gone.
/// Prefer the running test package during XCTest; otherwise resolve deployed
/// resources without depending on the original build folder.
public enum MacBundledResources {
    public static func directory(target: String, subdirectory: String) -> URL? {
        // XCTest can load an installed Vault app bundle before the package's
        // resource bundle. Its copy may be older than the code under test.
        let runningTestRoots = Bundle.allBundles
            .filter { $0.bundleURL.pathExtension == "xctest" }
            .map { $0.bundleURL.deletingLastPathComponent() }
        let roots = [Bundle.main.resourceURL, Bundle.main.bundleURL,
                     Bundle.main.executableURL?.deletingLastPathComponent()]
            .compactMap { $0 }
        let testRoots = Bundle.allBundles.flatMap { [$0.resourceURL, $0.bundleURL.deletingLastPathComponent()] }.compactMap { $0 }
        return directory(target: target, subdirectory: subdirectory, roots: runningTestRoots + roots + testRoots)
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
