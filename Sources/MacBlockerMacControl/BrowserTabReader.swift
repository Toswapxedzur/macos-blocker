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

    /// Extended tab info with window/tab indices for targeted operations.
    public struct TabDetail: Sendable, Equatable {
        public let url: String
        public let title: String
        public let browserBundleID: String
        public let windowIndex: Int
        public let tabIndex: Int
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

    // MARK: - Enumerate All Tabs

    /// Returns all open tabs across all windows for every running browser.
    /// Expensive (~200-500ms total); call on-demand only, not every tick.
    public static func allTabs() -> [TabDetail] {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        var results: [TabDetail] = []
        for bundleID in knownBrowserBundleIDs where running.contains(bundleID) {
            results.append(contentsOf: allTabs(browserBundleID: bundleID))
        }
        return results
    }

    /// Returns all open tabs for a specific browser.
    public static func allTabs(browserBundleID: String) -> [TabDetail] {
        let appName = appNameForBundleID(browserBundleID)
        guard !appName.isEmpty else { return [] }

        let script: String
        if browserBundleID == "com.apple.Safari" {
            script = """
            tell application "Safari"
                set output to ""
                set wIdx to 0
                repeat with w in windows
                    set wIdx to wIdx + 1
                    set tIdx to 0
                    repeat with t in tabs of w
                        set tIdx to tIdx + 1
                        set tabURL to URL of t
                        set tabName to name of t
                        set output to output & tabURL & "\\t" & tabName & "\\t" & wIdx & "\\t" & tIdx & linefeed
                    end repeat
                end repeat
                return output
            end tell
            """
        } else if browserBundleID == "org.mozilla.firefox" {
            script = """
            tell application "Firefox"
                set output to ""
                set wIdx to 0
                repeat with w in windows
                    set wIdx to wIdx + 1
                    set tIdx to 0
                    repeat with t in tabs of w
                        set tIdx to tIdx + 1
                        set tabURL to URL of t
                        set tabName to name of t
                        set output to output & tabURL & "\\t" & tabName & "\\t" & wIdx & "\\t" & tIdx & linefeed
                    end repeat
                end repeat
                return output
            end tell
            """
        } else {
            script = """
            tell application "\(appName)"
                set output to ""
                set wIdx to 0
                repeat with w in windows
                    set wIdx to wIdx + 1
                    set tIdx to 0
                    repeat with t in tabs of w
                        set tIdx to tIdx + 1
                        set tabURL to URL of t
                        set tabTitle to title of t
                        set output to output & tabURL & "\\t" & tabTitle & "\\t" & wIdx & "\\t" & tIdx & linefeed
                    end repeat
                end repeat
                return output
            end tell
            """
        }

        guard let raw = runAppleScript(script) else { return [] }
        var results: [TabDetail] = []
        for line in raw.components(separatedBy: .newlines) where !line.isEmpty {
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 4,
                  let wIdx = Int(parts[2]),
                  let tIdx = Int(parts[3]) else { continue }
            results.append(TabDetail(
                url: parts[0],
                title: parts[1],
                browserBundleID: browserBundleID,
                windowIndex: wIdx,
                tabIndex: tIdx
            ))
        }
        return results
    }

    /// JSON representation of all tabs for injection into the JS runtime.
    public static func allTabsJSON() -> String {
        let tabs = allTabs()
        let dicts: [[String: Any]] = tabs.map {
            ["url": $0.url, "title": $0.title, "browserBundleID": $0.browserBundleID,
             "windowIndex": $0.windowIndex, "tabIndex": $0.tabIndex]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: dicts),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
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

    // MARK: - Close Specific Tab

    /// Closes a specific tab by window and tab index.
    @discardableResult
    public static func closeTab(browserBundleID: String, windowIndex: Int, tabIndex: Int) -> Bool {
        let appName = appNameForBundleID(browserBundleID)
        guard !appName.isEmpty else { return false }

        let script: String
        if browserBundleID == "com.apple.Safari" {
            script = "tell application \"Safari\" to close tab \(tabIndex) of window \(windowIndex)"
        } else {
            script = "tell application \"\(appName)\" to close tab \(tabIndex) of window \(windowIndex)"
        }
        return runAppleScript(script) != nil
    }

    /// Closes all tabs matching a URL pattern across all running browsers.
    /// Returns the number of tabs closed.
    @discardableResult
    public static func closeTabsMatching(pattern: String) -> Int {
        let normalized = pattern.lowercased()
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "www.", with: "")
        guard !normalized.isEmpty else { return 0 }

        let tabs = allTabs()
        var closed = 0
        // Close in reverse order so indices stay valid.
        for tab in tabs.reversed() {
            let host = URL(string: tab.url)?.host?.lowercased()
                .replacingOccurrences(of: "www.", with: "") ?? ""
            if host == normalized || host.hasSuffix("." + normalized) {
                if closeTab(browserBundleID: tab.browserBundleID,
                            windowIndex: tab.windowIndex, tabIndex: tab.tabIndex) {
                    closed += 1
                }
            }
        }
        return closed
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

    public static func appNameForBundleID(_ bundleID: String) -> String {
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
