import Foundation

/// Shared App Group configuration. The real Xcode app and its Screen Time
/// extensions must use the same identifier so they can read/write the same
/// store. Set `AppGroup.identifier` once at launch (e.g. from an Info.plist
/// value) before any store access. Replace the placeholder with your real
/// App Group when you create the Xcode targets.
public enum AppGroup {
    public static let placeholderIdentifier = "group.com.adamancia.vault"

    /// Mutable so the app can override it at launch. Defaults to the
    /// placeholder used throughout the scaffold entitlements.
    public static var identifier: String = placeholderIdentifier

    /// The App Group shared container, when the entitlement is present.
    public static func containerURL(identifier: String = AppGroup.identifier) -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    /// Base directory for all shared files. Uses the App Group container when
    /// available (real app + extensions), and falls back to Application
    /// Support so the SwiftPM panel and unit tests still work without an
    /// entitlement.
    public static func baseDirectory(identifier: String = AppGroup.identifier) -> URL {
        let root: URL
        if let container = containerURL(identifier: identifier) {
            root = container
        } else {
            root = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        }
        return root.appendingPathComponent("macosBlocker", isDirectory: true)
    }
}
