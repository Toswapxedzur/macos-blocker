#if os(macOS)
import AppKit
import MacBlockerCore

/// The tiny floating "+" at the bottom right of the screen (owner 2026-09-25):
/// one click appends the frontmost application to the group the user chose
/// by its "+" badge in the editor. Off by default; the editor's Settings
/// switch (`globalSettings.quickAddEnabled`) and the chosen group
/// (`quickAddGroupId`) live in the shared web store, so the browser's "+" and
/// this one follow the same choice. The panel never activates, so the app
/// that was in front stays in front and is the one that gets added.
@MainActor
public final class QuickAddPanel {
    public static let shared = QuickAddPanel()

    private var panel: NSPanel?
    private var groupID = ""
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
    static func target(in raw: [String: Any]) -> String? {
        let settings = raw["globalSettings"] as? [String: Any] ?? [:]
        guard settings["quickAddEnabled"] as? Bool == true,
              let groupID = raw["quickAddGroupId"] as? String, !groupID.isEmpty else { return nil }
        let groups = raw["blockedGroups"] as? [[String: Any]] ?? []
        guard let group = groups.first(where: { ($0["id"] as? String) == groupID }),
              (group["groupType"] as? String) != "custom" else { return nil }
        return groupID
    }

    /// Re-read the store and show or hide the panel accordingly.
    public func reload() {
        if let target = Self.target(in: store.load().raw) {
            groupID = target
            show()
        } else {
            groupID = ""
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
        button.font = NSFont.boldSystemFont(ofSize: 12)
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor(calibratedRed: 0.06, green: 0.09, blue: 0.16, alpha: 0.75).cgColor
        button.layer?.cornerRadius = size / 2
        button.contentTintColor = .white
        button.toolTip = "Add the front app to the chosen group"
        button.target = self
        button.action = #selector(addFrontmostApplication)
        panel.contentView = button
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
              bundleID != Bundle.main.bundleIdentifier else { return }
        do {
            try store.mutate { try $0.addApplication(id: groupID, bundleID: bundleID, name: app.localizedName) }
        } catch {
            NSSound.beep()
        }
    }
}
#endif
