#if os(macOS)
import Foundation
import AppKit
import CoreServices
import MacBlockerCore
import MacBlockerMacControl

/// Candidate recognition determines where an older browser needs an upgrade;
/// it never establishes the actual browser identity used for usage overlap.
/// Recognition is bounded to known IDs and installed HTTP+HTTPS handlers. It
/// cannot prove the absence of an arbitrary unregistered browser application.
enum BrowserIdentityBudgetPolicy {
    static func affects(_ scalars: [String: Any], scopes: [[String: Any]], browserBundleIDs: Set<String>) -> Bool {
        guard (scalars["groupType"] as? String) != "custom",
              (scalars["mode"] as? String) == BlockingMode.afterMinutes.rawValue,
              scopes.contains(where: canCountBrowserUsage) else { return false }
        return scopes.contains { line in
            guard line["surface"] as? String == "apps", (line["action"] as? String ?? "block") == "block" else { return false }
            let listed = Set((line["apps"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String })
            if line["appsExcept"] as? Bool == true {
                return browserBundleIDs.contains { !BlockGroup.lists(listed, $0) }
            }
            return browserBundleIDs.contains { BlockGroup.lists(listed, $0) }
        }
    }

    private static func canCountBrowserUsage(_ line: [String: Any]) -> Bool {
        let surface = line["surface"] as? String ?? ""
        guard surface == "site" else { return ["items", "pages", "home", "shelf"].contains(surface) }
        // Empty blocklists match no page; empty allowlists cover the whole web.
        // Use the shared scope normalizer instead of inventing a native host
        // grammar. Both block and pause page actions consume the same budget.
        if line["sitesExcept"] as? Bool == true { return true }
        return (line["sites"] as? [Any] ?? []).contains { site in
            guard let normalized = GroupActionsRuntime.shared.call("normalizeSiteInput", [site], module: "CBGroupScopes") as? String else { return false }
            return !normalized.isEmpty
        }
    }

    private static let cacheLock = NSLock()
    private static var cachedIDs: Set<String> = []
    private static var refreshAt = Date.distantPast

    /// Read-only LaunchServices metadata, refreshed while the hub is active so
    /// installing, removing or registering a browser updates the pause policy.
    static func recognizedBrowserBundleIDs(now: Date = Date()) -> Set<String> {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if now < refreshAt { return cachedIDs }
        var ids = Set(BlockedProcesses.browserBundleIdentifiers.map { $0.lowercased() })
        ids.formUnion(["org.chromium.chromium", "com.google.chrome.for.testing"])
        func handlers(_ scheme: String) -> Set<String> {
            let values = LSCopyAllHandlersForURLScheme(scheme as CFString)?.takeRetainedValue() as? [String] ?? []
            return Set(values.map { $0.lowercased() })
        }
        for handler in handlers("http").intersection(handlers("https")) {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: handler),
                  let actual = Bundle(url: url)?.bundleIdentifier?.lowercased(), actual == handler else { continue }
            ids.insert(actual)
        }
        cachedIDs = ids
        refreshAt = now.addingTimeInterval(10)
        return ids
    }
}
#endif
