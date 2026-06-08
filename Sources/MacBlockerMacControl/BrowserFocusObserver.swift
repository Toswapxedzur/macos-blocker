#if os(macOS)
import AppKit
import Combine

/// Observes browser focus transitions and fires a callback immediately when:
///   1. A browser becomes the frontmost app (app activation)
///   2. The user switches tabs within a browser (URL change detection via polling delta)
///
/// This provides "chokepoint" events with near-zero latency compared to
/// relying solely on the 1-second enforcement tick.
public final class BrowserFocusObserver {

    public struct FocusEvent {
        public let browserBundleID: String
        public let tab: BrowserTabReader.TabInfo?
        public let trigger: Trigger
    }

    public enum Trigger {
        case appActivated
        case urlChanged
    }

    /// Callback invoked on the main thread when a browser focus event occurs.
    public var onFocusEvent: ((FocusEvent) -> Void)?

    private var workspaceObserver: Any?
    private var pollTimer: Timer?
    private var lastTabInfo: BrowserTabReader.TabInfo?
    private let pollInterval: TimeInterval

    public init(pollInterval: TimeInterval = 0.3) {
        self.pollInterval = pollInterval
    }

    public func start() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObserver = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleAppActivation(notification)
        }

        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.pollCurrentTab()
        }
    }

    public func stop() {
        if let observer = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            workspaceObserver = nil
        }
        pollTimer?.invalidate()
        pollTimer = nil
        lastTabInfo = nil
    }

    deinit {
        stop()
    }

    // MARK: - Private

    private func handleAppActivation(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleID = app.bundleIdentifier,
              BrowserTabReader.isBrowser(bundleID)
        else {
            lastTabInfo = nil
            return
        }
        let tab = BrowserTabReader.currentTab(browserBundleID: bundleID)
        lastTabInfo = tab
        onFocusEvent?(FocusEvent(browserBundleID: bundleID, tab: tab, trigger: .appActivated))
    }

    private func pollCurrentTab() {
        guard let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              BrowserTabReader.isBrowser(frontmost)
        else {
            lastTabInfo = nil
            return
        }
        let tab = BrowserTabReader.currentTab(browserBundleID: frontmost)
        if tab != lastTabInfo {
            lastTabInfo = tab
            onFocusEvent?(FocusEvent(browserBundleID: frontmost, tab: tab, trigger: .urlChanged))
        }
    }
}
#endif
