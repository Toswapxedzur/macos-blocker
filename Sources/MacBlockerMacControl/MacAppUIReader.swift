import Foundation
import MacBlockerCore

#if os(macOS)
import AppKit
import ApplicationServices
#endif

/// A snapshot of what we can read from another application's UI via the
/// Accessibility API. This is the macOS capability that has no iOS equivalent:
/// with the Accessibility permission granted we can inspect (and drive) other
/// apps' window trees — e.g. read the frontmost browser's current tab URL,
/// which is what enables true web-vs-app distinction inside native browsers.
public struct AppUISnapshot: Equatable, Sendable {
    public var bundleIdentifier: String
    public var focusedWindowTitle: String?
    public var windowTitles: [String]
    /// Best-effort current document/tab URL (browsers expose `AXDocument` or a
    /// URL field). Nil for apps that don't surface a URL.
    public var focusedURL: String?

    public init(
        bundleIdentifier: String,
        focusedWindowTitle: String? = nil,
        windowTitles: [String] = [],
        focusedURL: String? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.focusedWindowTitle = focusedWindowTitle
        self.windowTitles = windowTitles
        self.focusedURL = focusedURL
    }
}

public enum MacAppUIReaderError: Error, Equatable {
    case accessibilityNotTrusted
    case appNotRunning
}

/// Reads UI metadata from running applications using the Accessibility API.
public enum MacAppUIReader {
    /// Whether this process is trusted for Accessibility. Reading other apps'
    /// UI requires this to be `true` (System Settings → Privacy & Security →
    /// Accessibility).
    public static var isAccessibilityTrusted: Bool {
        MacPermissionState.current().accessibilityTrusted
    }

    /// Reads a UI snapshot for the first running instance of `bundleIdentifier`.
    public static func snapshot(forBundleIdentifier bundleIdentifier: String) throws -> AppUISnapshot {
        #if os(macOS)
        guard isAccessibilityTrusted else { throw MacAppUIReaderError.accessibilityNotTrusted }

        let running = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .first
        guard let app = running else { throw MacAppUIReaderError.appNotRunning }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        let windows = axArray(appElement, kAXWindowsAttribute)
        let titles = windows.compactMap { axString($0, kAXTitleAttribute) }

        let focusedWindow = axElement(appElement, kAXFocusedWindowAttribute)
        let focusedTitle = focusedWindow.flatMap { axString($0, kAXTitleAttribute) }
        let focusedURL = focusedWindow.flatMap { documentURL($0) }

        return AppUISnapshot(
            bundleIdentifier: bundleIdentifier,
            focusedWindowTitle: focusedTitle,
            windowTitles: titles,
            focusedURL: focusedURL
        )
        #else
        throw MacAppUIReaderError.appNotRunning
        #endif
    }

    #if os(macOS)
    /// Tries to read a URL from a window. Browsers commonly expose `AXDocument`
    /// on the window (a file/URL string); some expose it on a descendant
    /// element. This is best-effort and returns nil when nothing is found.
    private static func documentURL(_ window: AXUIElement) -> String? {
        if let doc = axString(window, kAXDocumentAttribute), !doc.isEmpty {
            return doc
        }
        // Shallow descent: scan the window's children for an AXDocument.
        for child in axArray(window, kAXChildrenAttribute) {
            if let doc = axString(child, kAXDocumentAttribute), !doc.isEmpty {
                return doc
            }
        }
        return nil
    }

    private static func axCopy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return result == .success ? value : nil
    }

    private static func axString(_ element: AXUIElement, _ attribute: String) -> String? {
        axCopy(element, attribute) as? String
    }

    private static func axElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = axCopy(element, attribute) else { return nil }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func axArray(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        guard let value = axCopy(element, attribute) as? [AnyObject] else { return [] }
        return value.compactMap { item in
            guard CFGetTypeID(item) == AXUIElementGetTypeID() else { return nil }
            return (item as! AXUIElement)
        }
    }
    #endif
}
