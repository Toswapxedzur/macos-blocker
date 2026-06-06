import Foundation
import MacBlockerCore

#if os(macOS)
import AppKit
#endif

/// A single installed macOS application discovered on the local machine.
///
/// Unlike iOS — where `FamilyControls` hands back opaque tokens with no name,
/// bundle id, or icon — macOS lets us read the real application inventory. This
/// is the foundation of the macOS *app* blocker: the user picks from a concrete
/// list of their installed apps, and we shield/hide/terminate by bundle id.
public struct InstalledApplication: Identifiable, Equatable, Sendable, Codable {
    /// Bundle identifier (e.g. `com.apple.Safari`). Stable across launches and
    /// used as the `BlockTarget.id` for app targets.
    public var bundleIdentifier: String
    /// Localized display name (e.g. "Safari").
    public var name: String
    /// Absolute path to the `.app` bundle on disk.
    public var path: String
    /// Whether an instance of this app is currently running.
    public var isRunning: Bool

    public var id: String { bundleIdentifier }

    public init(bundleIdentifier: String, name: String, path: String, isRunning: Bool) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.path = path
        self.isRunning = isRunning
    }

    /// Converts to the core `BlockTarget` model so an app can be assigned to a
    /// block group. The bundle id is the stable identity.
    public func asBlockTarget() -> BlockTarget {
        BlockTarget(
            id: bundleIdentifier,
            kind: .application,
            displayName: name,
            normalizedValue: bundleIdentifier,
            tags: ["mac", "application"]
        )
    }
}

/// Enumerates installed and running applications on macOS.
///
/// No special entitlement is required to *list* applications — these are
/// readable from the standard application directories and `NSWorkspace`.
/// (Reading or controlling another app's *UI* is separate and gated by the
/// Accessibility permission; see `MacAppUIReader`.)
public enum MacApplicationInventory {
    /// Standard locations macOS apps are installed into.
    public static func searchDirectories() -> [URL] {
        #if os(macOS)
        let fm = FileManager.default
        var dirs: [URL] = []
        // System + user "Applications", plus their "Utilities" subfolders.
        dirs += fm.urls(for: .applicationDirectory, in: .localDomainMask)
        dirs += fm.urls(for: .applicationDirectory, in: .userDomainMask)
        dirs += fm.urls(for: .applicationDirectory, in: .systemDomainMask)
        // De-dup while preserving order.
        var seen = Set<String>()
        return dirs.filter { seen.insert($0.standardizedFileURL.path).inserted }
        #else
        return []
        #endif
    }

    /// Returns the set of installed applications, sorted by name. Each entry's
    /// `isRunning` reflects the live `NSWorkspace` state at call time.
    public static func installedApplications() -> [InstalledApplication] {
        #if os(macOS)
        let runningByBundleID = runningBundleIdentifiers()
        var byBundleID: [String: InstalledApplication] = [:]

        for directory in searchDirectories() {
            for appURL in appBundleURLs(in: directory) {
                guard let bundle = Bundle(url: appURL),
                      let bundleID = bundle.bundleIdentifier else {
                    continue
                }
                // First writer wins (local/user domain precedes system), but we
                // only skip exact duplicates by bundle id.
                if byBundleID[bundleID] != nil { continue }

                byBundleID[bundleID] = InstalledApplication(
                    bundleIdentifier: bundleID,
                    name: displayName(for: appURL, bundle: bundle),
                    path: appURL.standardizedFileURL.path,
                    isRunning: runningByBundleID.contains(bundleID)
                )
            }
        }

        return byBundleID.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        #else
        return []
        #endif
    }

    /// Applications that currently have at least one running instance.
    public static func runningApplications() -> [InstalledApplication] {
        #if os(macOS)
        var byBundleID: [String: InstalledApplication] = [:]
        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular,
                  let bundleID = app.bundleIdentifier,
                  byBundleID[bundleID] == nil else {
                continue
            }
            let url = app.bundleURL
            byBundleID[bundleID] = InstalledApplication(
                bundleIdentifier: bundleID,
                name: app.localizedName ?? url?.deletingPathExtension().lastPathComponent ?? bundleID,
                path: url?.standardizedFileURL.path ?? "",
                isRunning: true
            )
        }
        return byBundleID.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        #else
        return []
        #endif
    }

    #if os(macOS)
    /// The app icon for an installed application, if available.
    public static func icon(for app: InstalledApplication) -> NSImage? {
        guard !app.path.isEmpty else { return nil }
        return NSWorkspace.shared.icon(forFile: app.path)
    }

    private static func runningBundleIdentifiers() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
    }

    /// Shallowly lists `.app` bundles directly inside a directory (one level of
    /// nesting for folders like "Utilities").
    private static func appBundleURLs(in directory: URL) -> [URL] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isApplicationKey, .isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var result: [URL] = []
        for entry in entries {
            if entry.pathExtension == "app" {
                result.append(entry)
            } else if (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                // One level deep (e.g. "/Applications/Utilities").
                if let nested = try? fm.contentsOfDirectory(
                    at: entry,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) {
                    result += nested.filter { $0.pathExtension == "app" }
                }
            }
        }
        return result
    }

    private static func displayName(for url: URL, bundle: Bundle) -> String {
        if let display = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
           !display.isEmpty {
            return display
        }
        if let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String,
           !name.isEmpty {
            return name
        }
        return url.deletingPathExtension().lastPathComponent
    }
    #endif
}
