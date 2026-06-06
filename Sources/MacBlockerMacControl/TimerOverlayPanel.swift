import Foundation

#if canImport(AppKit)
import AppKit
import SwiftUI

/// One line in the floating timer HUD — mirrors the Chrome extension's on-page
/// overlay rows (`Name: MM:SS`).
public struct TimerOverlayRow: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let remainingSeconds: TimeInterval

    public init(id: String, name: String, remainingSeconds: TimeInterval) {
        self.id = id
        self.name = name
        self.remainingSeconds = max(0, remainingSeconds)
    }

    /// `H:MM:SS` once an hour is involved, otherwise `M:SS` — matching the
    /// extension overlay's duration formatting.
    public var formattedRemaining: String {
        let total = Int(remainingSeconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

@MainActor
final class TimerOverlayModel: ObservableObject {
    @Published var rows: [TimerOverlayRow] = []
}

/// The HUD content. Styled to match the extension's overlay: a dark, rounded,
/// translucent card with monospace white text.
struct TimerOverlayView: View {
    @ObservedObject var model: TimerOverlayModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(model.rows) { row in
                Text("\(row.name): \(row.formattedRemaining)")
                    .font(.system(size: 13, weight: .regular, design: .monospaced))
                    .foregroundColor(Color(red: 0.973, green: 0.980, blue: 0.988))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(red: 0.059, green: 0.090, blue: 0.165).opacity(0.86))
        )
        .fixedSize()
    }
}

/// Owns a borderless, non-activating, always-on-top `NSPanel` that renders the
/// timer HUD above every Space — including other applications running in
/// full-screen — without ever stealing focus. This is the macOS equivalent of
/// the Chrome extension's in-page overlay: the pixels float *over* whatever app
/// is frontmost; nothing is injected into the other process.
@MainActor
public final class TimerOverlayPanelController {
    private let model = TimerOverlayModel()
    private var panel: NSPanel?
    private let screenInset: CGFloat = 16

    public init() {}

    /// Replaces the visible rows. An empty array hides the HUD.
    public func update(rows: [TimerOverlayRow]) {
        guard !rows.isEmpty else {
            hide()
            return
        }
        if model.rows != rows {
            model.rows = rows
        }
        let panel = ensurePanel()
        resizeAndPosition(panel)
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    public func hide() {
        panel?.orderOut(nil)
    }

    public func teardown() {
        panel?.orderOut(nil)
        panel = nil
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let hosting = NSHostingView(rootView: TimerOverlayView(model: model))
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 40),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // High enough to clear other apps' full-screen windows, and present on
        // every Space so it follows the user across full-screen apps.
        panel.level = .screenSaver
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
        hosting.translatesAutoresizingMaskIntoConstraints = true
        panel.contentView = hosting
        self.panel = panel
        return panel
    }

    private func resizeAndPosition(_ panel: NSPanel) {
        guard let hosting = panel.contentView else { return }
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        guard let screen = NSScreen.main else {
            panel.setContentSize(size)
            return
        }
        let frame = screen.frame
        let origin = NSPoint(
            x: frame.minX + screenInset,
            y: frame.maxY - size.height - screenInset
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }
}
#endif
