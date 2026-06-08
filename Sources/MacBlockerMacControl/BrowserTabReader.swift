#if os(macOS)
import AppKit

/// Reads the current browser tab URL and title via AppleScript, and can
/// close the active tab. Supports Safari, Chrome, Arc, Brave, Edge, Firefox.
public enum BrowserTabReader {

    public struct TabInfo: Sendable, Equatable {
        public let url: String
        public let title: String
        public let browserBundleID: String
    }

    // MARK: - Known Browsers

    private static let browserScripts: [(bundleID: String, urlScript: String, titleScript: String, closeScript: String)] = [
        (
            "com.apple.Safari",
            "tell application \"Safari\" to get URL of current tab of front window",
            "tell application \"Safari\" to get name of current tab of front window",
            "tell application \"Safari\" to close current tab of front window"
        ),
        (
            "com.google.Chrome",
            "tell application \"Google Chrome\" to get URL of active tab of front window",
            "tell application \"Google Chrome\" to get title of active tab of front window",
            "tell application \"Google Chrome\" to close active tab of front window"
        ),
        (
            "company.thebrowser.Browser",
            "tell application \"Arc\" to get URL of active tab of front window",
            "tell application \"Arc\" to get title of active tab of front window",
            "tell application \"Arc\" to close active tab of front window"
        ),
        (
            "com.brave.Browser",
            "tell application \"Brave Browser\" to get URL of active tab of front window",
            "tell application \"Brave Browser\" to get title of active tab of front window",
            "tell application \"Brave Browser\" to close active tab of front window"
        ),
        (
            "com.microsoft.edgemac",
            "tell application \"Microsoft Edge\" to get URL of active tab of front window",
            "tell application \"Microsoft Edge\" to get title of active tab of front window",
            "tell application \"Microsoft Edge\" to close active tab of front window"
        ),
        (
            "org.mozilla.firefox",
            "tell application \"Firefox\" to get URL of active tab of front window",
            "tell application \"Firefox\" to get name of active tab of front window",
            "tell application \"Firefox\" to close active tab of front window"
        ),
    ]

    private static let knownBrowserBundleIDs: Set<String> = Set(browserScripts.map(\.bundleID))

    /// Whether the given bundle ID is a known browser we can read tabs from.
    public static func isBrowser(_ bundleID: String) -> Bool {
        knownBrowserBundleIDs.contains(bundleID)
    }

    // MARK: - Read Current Tab

    /// Reads the active tab of the specified browser. Returns nil if the
    /// browser isn't running or AppleScript fails (permission denied, no window).
    public static func currentTab(browserBundleID: String) -> TabInfo? {
        guard let entry = browserScripts.first(where: { $0.bundleID == browserBundleID }) else {
            return nil
        }
        guard let url = runAppleScript(entry.urlScript), !url.isEmpty else {
            return nil
        }
        let title = runAppleScript(entry.titleScript) ?? ""
        return TabInfo(url: url, title: title, browserBundleID: browserBundleID)
    }

    // MARK: - Close Active Tab

    /// Closes the active tab of the specified browser via AppleScript.
    @discardableResult
    public static func closeActiveTab(browserBundleID: String) -> Bool {
        guard let entry = browserScripts.first(where: { $0.bundleID == browserBundleID }) else {
            return false
        }
        return runAppleScript(entry.closeScript) != nil
    }

    // MARK: - Navigate (redirect the current tab)

    /// Navigates the active tab to a new URL. Useful for showing a block page.
    @discardableResult
    public static func navigateActiveTab(browserBundleID: String, to url: String) -> Bool {
        let escaped = url.replacingOccurrences(of: "\"", with: "\\\"")
        let script: String
        switch browserBundleID {
        case "com.apple.Safari":
            script = "tell application \"Safari\" to set URL of current tab of front window to \"\(escaped)\""
        case "com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser.Browser":
            let appName = appNameForBundleID(browserBundleID)
            script = "tell application \"\(appName)\" to set URL of active tab of front window to \"\(escaped)\""
        case "org.mozilla.firefox":
            script = "tell application \"Firefox\" to set URL of active tab of front window to \"\(escaped)\""
        default:
            return false
        }
        return runAppleScript(script) != nil
    }

    // MARK: - Helpers

    @discardableResult
    private static func runAppleScript(_ source: String) -> String? {
        let script = NSAppleScript(source: source)
        var error: NSDictionary?
        let result = script?.executeAndReturnError(&error)
        guard error == nil else { return nil }
        return result?.stringValue
    }

    private static func appNameForBundleID(_ bundleID: String) -> String {
        switch bundleID {
        case "com.apple.Safari": return "Safari"
        case "com.google.Chrome": return "Google Chrome"
        case "company.thebrowser.Browser": return "Arc"
        case "com.brave.Browser": return "Brave Browser"
        case "com.microsoft.edgemac": return "Microsoft Edge"
        case "org.mozilla.firefox": return "Firefox"
        default: return ""
        }
    }
}
#endif
