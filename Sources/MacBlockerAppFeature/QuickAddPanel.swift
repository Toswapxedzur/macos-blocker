#if os(macOS)
import AppKit
import MacBlockerCore
import MacBlockerMacControl

/// The tiny floating "+" at the bottom right of the screen (owner 2026-09-25):
/// one click appends the frontmost application to the group the user chose
/// by selecting its card in the editor. Off by default; the editor's Settings
/// switch (`globalSettings.quickAddEnabled`) and the chosen group
/// (`quickAddGroupId`) live in the shared web store, so the browser's "+" and
/// this one follow the same choice. The panel never activates, so the app
/// that was in front stays in front and is the one that gets added.
@MainActor
public final class QuickAddPanel {
    public static let shared = QuickAddPanel()

    private var panel: NSPanel?
    private var groupID = ""
    private var groupName = ""
    private var button: NSButton?
    private var feedbackRevision = 0
    private let store = GroupStore()

    private init() {
        NotificationCenter.default.addObserver(
            forName: GroupStore.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.position() }
        }
    }

    /// What the store says: the "+" is shown only when the switch is on and the
    /// chosen group still exists (and is not a custom rule).
    static func target(in document: WebStoreDocument) -> String? {
        let settings = document.raw["globalSettings"] as? [String: Any] ?? [:]
        guard settings["quickAddEnabled"] as? Bool == true,
              let groupID = document.raw["quickAddGroupId"] as? String, !groupID.isEmpty else { return nil }
        // "+" is an edit, and a locked group takes no edits (as in the editor) —
        // locked here or on a linked device.
        guard let group = document.publicGroup(id: groupID),
              (group["groupType"] as? String) != "custom",
              group["locked"] as? Bool != true else { return nil }
        return groupID
    }

    /// Re-read the store and show or hide the panel accordingly.
    public func reload() {
        let document = store.load()
        if let target = Self.target(in: document) {
            if groupID != target {
                feedbackRevision += 1
                button?.title = "+"
            }
            groupID = target
            groupName = document.publicGroup(id: target)?["name"] as? String ?? target
            show()
            button?.toolTip = "Add the front app to \(groupName)"
            button?.setAccessibilityLabel("Add the front app to \(groupName)")
        } else {
            groupID = ""
            groupName = ""
            feedbackRevision += 1
            panel?.orderOut(nil)
        }
    }

    private func show() {
        if panel == nil { panel = makePanel() }
        position()
        panel?.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let size: CGFloat = 18
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: size, height: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let button = NSButton(frame: NSRect(x: 0, y: 0, width: size, height: size))
        button.title = "+"
        button.font = NSFont(name: "Arial-BoldMT", size: 14)
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor(calibratedRed: 0.933, green: 0.949, blue: 1, alpha: 1).cgColor
        button.layer?.cornerRadius = size / 2
        button.contentTintColor = NSColor(calibratedRed: 0.118, green: 0.227, blue: 0.541, alpha: 1)
        button.toolTip = "Add the front app to \(groupName)"
        button.target = self
        button.action = #selector(addFrontmostApplication)
        panel.contentView = button
        self.button = button
        return panel
    }

    private func position() {
        guard let panel, let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let inset: CGFloat = 8
        panel.setFrameOrigin(NSPoint(
            x: frame.maxX - panel.frame.width - inset,
            y: frame.minY + inset
        ))
    }

    @objc private func addFrontmostApplication() {
        guard !groupID.isEmpty,
              let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier,
              GuardPolicy.canBlock(bundleID) else {
            showFeedback(success: false) // Apple's apps, browsers and Vault are never blocked
            return
        }
        do {
            try store.mutate { try $0.addApplication(id: groupID, bundleID: bundleID, name: app.localizedName) }
            showFeedback(success: true)
        } catch {
            showFeedback(success: false)
        }
    }

    private func showFeedback(success: Bool) {
        feedbackRevision += 1
        let revision = feedbackRevision
        button?.title = success ? "✓" : "!"
        let message = success ? "Added to \(groupName)" : "Could not add the front app to \(groupName)"
        button?.toolTip = message
        button?.setAccessibilityLabel(message)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, self.feedbackRevision == revision else { return }
            self.button?.title = "+"
            let label = "Add the front app to \(self.groupName)"
            self.button?.toolTip = label
            self.button?.setAccessibilityLabel(label)
        }
    }
}
#endif
