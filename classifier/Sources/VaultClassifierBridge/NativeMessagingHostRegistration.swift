import Foundation
import VaultClassifierCore

/// Registers the bundled production Native Messaging host — the helper that
/// hands the browser extension the local-hub secret — with the Chromium-family
/// browsers the host trusts. Mac Vault ships as a drag-to-Applications app with
/// no installer, so the app does this itself on launch; it is idempotent and
/// follows the app if it is moved. Development builds use
/// `scripts/install-dev-native-host.sh` and a separate host name instead.
public enum NativeMessagingHostRegistration {
    static let hostExecutableName = "VaultLocalHubNativeHost"

    /// Each browser's profile root under `~/Library/Application Support`. A
    /// manifest is written only where the root exists (the browser is installed).
    static let browserRoots = [
        "Google/Chrome",
        "Microsoft Edge",
        "Chromium",
        "BraveSoftware/Brave-Browser",
        "com.operasoftware.Opera",
    ]

    static func manifestData(hostName: String, hostPath: String, origin: String) throws -> Data {
        let manifest: [String: Any] = [
            "name": hostName,
            "description": "Adamancia Vault local-hub authentication",
            "path": hostPath,
            "type": "stdio",
            "allowed_origins": [origin],
        ]
        return try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
    }

    /// Returns the manifests written (empty when nothing had to change, when not
    /// in production, or when this process has no bundled host — e.g. `swift run`).
    @discardableResult
    public static func registerBundledHost(
        environment: VaultRuntimeEnvironment = .current,
        bundle: Bundle = .main,
        applicationSupport: URL? = nil,
        fileManager: FileManager = .default
    ) -> [URL] {
        guard environment == .production else { return [] }
        let host = bundle.bundleURL
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent(hostExecutableName)
        guard fileManager.isExecutableFile(atPath: host.path),
              let support = applicationSupport
                ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
              let data = try? manifestData(
                hostName: environment.nativeMessagingHostName,
                hostPath: host.path,
                origin: environment.chromeExtensionOrigin
              )
        else { return [] }

        var written: [URL] = []
        for root in browserRoots {
            let browser = support.appendingPathComponent(root, isDirectory: true)
            guard fileManager.fileExists(atPath: browser.path) else { continue }
            let directory = browser.appendingPathComponent("NativeMessagingHosts", isDirectory: true)
            let manifest = directory.appendingPathComponent("\(environment.nativeMessagingHostName).json")
            if let existing = try? Data(contentsOf: manifest), existing == data { continue }
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: manifest, options: .atomic)
                written.append(manifest)
            } catch {
                continue
            }
        }
        return written
    }
}
