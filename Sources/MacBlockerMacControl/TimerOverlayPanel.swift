import Foundation
import MacBlockerCore

#if canImport(AppKit)
import AppKit
import SwiftUI

/// One line in the floating timer HUD — mirrors the Chrome extension's on-page
/// overlay rows (`Name: HH:MM:SS`).
public struct TimerOverlayRow: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let remainingSeconds: TimeInterval

    public init(id: String, name: String, remainingSeconds: TimeInterval) {
        self.id = id
        self.name = name
        self.remainingSeconds = max(0, remainingSeconds)
    }

    /// HH:MM:SS, matching every other Vault duration.
    public var formattedRemaining: String {
        let total = Int(remainingSeconds.rounded(.up))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
}

@MainActor
final class TimerOverlayModel: ObservableObject {
    @Published var rows: [TimerOverlayRow] = []
}

/// The HUD content uses the extension's fixed light appearance.
struct TimerOverlayView: View {
    @ObservedObject var model: TimerOverlayModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(model.rows) { row in
                Text("\(row.name): \(row.formattedRemaining)")
                    .font(.custom("Arial", size: 13)).monospacedDigit()
                    .foregroundColor(Color(red: 0.122, green: 0.161, blue: 0.216))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white)
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

// MARK: - Panel Overlay (a custom rule's v.panel)

/// SwiftUI view for a single panel control.
struct PanelControlView: View {
    let control: PanelControlSnapshot
    /// (controlId, eventName, value, extra)
    let onEvent: (String, String, String, String) -> Void
    /// All current control values in this panel, for batch sending.
    let allValues: [String: String]

    private var accent: Color {
        Color(red: 0.118, green: 0.227, blue: 0.541)
    }

    var body: some View {
        Group {
            switch control.type {
            case "text", "html":
                // An html control shows its text here (the browser renders the markup).
                Text(control.text ?? control.html.map { $0.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression) } ?? control.label ?? "")
                    .font(.custom("Arial", size: 13))
                    .opacity(0.85)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

            case "button":
                Button(action: {
                    onEvent(control.id, "click", control.action ?? "", "")
                }) {
                    Text(control.label ?? "Button")
                        .font(.custom("Arial", size: 13)).fontWeight(.medium)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(accent)
                .disabled(control.disabled == true)

            case "checkbox":
                PanelToggleControl(
                    control: control,
                    snapshotValue: control.value?.boolValue ?? false,
                    isSwitch: false,
                    onEvent: onEvent
                )

            case "toggle":
                PanelToggleControl(
                    control: control,
                    snapshotValue: control.value?.boolValue ?? false,
                    isSwitch: true,
                    onEvent: onEvent
                )

            case "textInput":
                VStack(alignment: .leading, spacing: 2) {
                    if let label = control.label, !label.isEmpty {
                        Text(label).font(.custom("Arial", size: 11)).fontWeight(.medium).opacity(0.7)
                    }
                    PanelTextFieldControl(
                        control: control,
                        snapshotValue: control.value?.stringValue ?? "",
                        placeholder: control.placeholder ?? "",
                        multiline: false,
                        rows: 0,
                        onEvent: onEvent
                    )
                }

            case "textarea":
                VStack(alignment: .leading, spacing: 2) {
                    if let label = control.label, !label.isEmpty {
                        Text(label).font(.custom("Arial", size: 11)).fontWeight(.medium).opacity(0.7)
                    }
                    PanelTextFieldControl(
                        control: control,
                        snapshotValue: control.value?.stringValue ?? "",
                        placeholder: "",
                        multiline: true,
                        rows: control.rows ?? 3,
                        onEvent: onEvent
                    )
                }

            case "numberInput":
                VStack(alignment: .leading, spacing: 2) {
                    if let label = control.label, !label.isEmpty {
                        Text(label).font(.custom("Arial", size: 11)).fontWeight(.medium).opacity(0.7)
                    }
                    PanelTextFieldControl(
                        control: control,
                        snapshotValue: String(format: "%g", control.value?.doubleValue ?? 0),
                        placeholder: "",
                        multiline: false,
                        rows: 0,
                        onEvent: onEvent
                    )
                }

            case "range":
                PanelSliderControl(
                    control: control,
                    snapshotValue: control.value?.doubleValue ?? 0,
                    label: control.label,
                    lower: control.min ?? 0,
                    upper: control.max ?? 100,
                    step: control.step ?? 1,
                    onEvent: onEvent
                )

            case "select":
                VStack(alignment: .leading, spacing: 2) {
                    if let label = control.label, !label.isEmpty {
                        Text(label).font(.custom("Arial", size: 11)).fontWeight(.medium).opacity(0.7)
                    }
                    PanelSelectControl(
                        control: control,
                        snapshotValue: control.value?.stringValue ?? "",
                        onEvent: onEvent
                    )
                }

            case "radio":
                VStack(alignment: .leading, spacing: 4) {
                    if let label = control.label, !label.isEmpty {
                        Text(label).font(.custom("Arial", size: 11)).fontWeight(.medium).opacity(0.7)
                    }
                    ForEach(control.options ?? [], id: \.value) { opt in
                        HStack(spacing: 6) {
                            Image(systemName: (control.value?.stringValue ?? "") == opt.value ? "largecircle.fill.circle" : "circle")
                                .font(.custom("Arial", size: 14))
                                .foregroundColor(accent)
                                .onTapGesture { onEvent(control.id, "change", opt.value, "") }
                            Text(opt.label).font(.custom("Arial", size: 13))
                        }
                    }
                }
                .disabled(control.disabled == true)

            case "color":
                VStack(alignment: .leading, spacing: 2) {
                    if let label = control.label, !label.isEmpty {
                        Text(label).font(.custom("Arial", size: 11)).fontWeight(.medium).opacity(0.7)
                    }
                    PanelColorControl(
                        control: control,
                        snapshotValue: control.value?.stringValue ?? "#000000",
                        onEvent: onEvent
                    )
                }

            case "section":
                VStack(alignment: .leading, spacing: 6) {
                    if let text = control.text, !text.isEmpty {
                        Text(text)
                            .font(.custom("Arial", size: 12)).fontWeight(.semibold)
                            .opacity(0.7)
                    }
                    ForEach(control.controls ?? [], id: \.id) { child in
                        PanelControlView(control: child, onEvent: onEvent, allValues: allValues)
                    }
                }
                .padding(.leading, 4)

            case "date":
                VStack(alignment: .leading, spacing: 2) {
                    if let label = control.label, !label.isEmpty {
                        Text(label).font(.custom("Arial", size: 11)).fontWeight(.medium).opacity(0.7)
                    }
                    PanelTextFieldControl(
                        control: control,
                        snapshotValue: control.value?.stringValue ?? "",
                        placeholder: "YYYY-MM-DD",
                        multiline: false,
                        rows: 0,
                        onEvent: onEvent
                    )
                }

            case "time":
                VStack(alignment: .leading, spacing: 2) {
                    if let label = control.label, !label.isEmpty {
                        Text(label).font(.custom("Arial", size: 11)).fontWeight(.medium).opacity(0.7)
                    }
                    PanelTextFieldControl(
                        control: control,
                        snapshotValue: control.value?.stringValue ?? "",
                        placeholder: "HH:MM",
                        multiline: false,
                        rows: 0,
                        onEvent: onEvent
                    )
                }

            case "pin":
                VStack(alignment: .leading, spacing: 4) {
                    if let label = control.label, !label.isEmpty {
                        Text(label).font(.custom("Arial", size: 11)).fontWeight(.medium).opacity(0.7)
                    }
                    PanelPinControl(
                        control: control,
                        snapshotValue: control.value?.stringValue ?? "",
                        length: control.length ?? 6,
                        masked: control.masked ?? true,
                        autoSubmit: control.autoSubmit ?? false,
                        onEvent: onEvent
                    )
                }

            default:
                Text(control.label ?? control.text ?? "")
                    .font(.custom("Arial", size: 13))
            }
        }
    }

}

// MARK: - Local-state input controls
//
// Interactive controls keep their in-progress value in local @State instead of
// reading directly from the panel snapshot. The snapshot is a remote source of
// truth that updates asynchronously (native -> JS -> native, throttled), so a
// fully-controlled binding reverts user input during that gap ("bounce back").
// These subviews:
//   - emit a change event only when the local value diverges from the snapshot
//     (avoids echoing the value back to itself), and
//   - adopt an external snapshot value only when the user is NOT actively
//     editing (focused for text, dragging for slider).

private struct PanelTextFieldControl: View {
    let control: PanelControlSnapshot
    let snapshotValue: String
    let placeholder: String
    let multiline: Bool
    let rows: Int
    let onEvent: (String, String, String, String) -> Void

    @State private var text: String
    @State private var suppressEmit = false
    @FocusState private var focused: Bool

    init(control: PanelControlSnapshot,
         snapshotValue: String,
         placeholder: String,
         multiline: Bool,
         rows: Int,
         onEvent: @escaping (String, String, String, String) -> Void) {
        self.control = control
        self.snapshotValue = snapshotValue
        self.placeholder = placeholder
        self.multiline = multiline
        self.rows = rows
        self.onEvent = onEvent
        _text = State(initialValue: snapshotValue)
    }

    var body: some View {
        Group {
            if multiline {
                TextEditor(text: $text)
                    .font(.custom("Arial", size: 13))
                    .frame(height: CGFloat(rows) * 20)
                    .scrollContentBackground(.hidden)
                    .background(Color(red: 0.945, green: 0.961, blue: 0.976))
                    .cornerRadius(8)
            } else {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .padding(7)
                    .background(Color(red: 0.945, green: 0.961, blue: 0.976))
                    .cornerRadius(8)
                    .font(.custom("Arial", size: 13))
            }
        }
        .focused($focused)
        .disabled(control.disabled == true)
        .onChange(of: text) { newValue in
            if suppressEmit { suppressEmit = false; return }
            onEvent(control.id, "change", newValue, "")
        }
        .onChange(of: snapshotValue) { newValue in
            if !focused && newValue != text {
                suppressEmit = true
                text = newValue
            }
        }
    }
}

private struct PanelSliderControl: View {
    let control: PanelControlSnapshot
    let snapshotValue: Double
    let label: String?
    let onEvent: (String, String, String, String) -> Void

    private let range: ClosedRange<Double>
    private let step: Double

    @State private var value: Double
    @State private var editing = false
    @State private var suppressEmit = false

    init(control: PanelControlSnapshot,
         snapshotValue: Double,
         label: String?,
         lower: Double,
         upper: Double,
         step: Double,
         onEvent: @escaping (String, String, String, String) -> Void) {
        self.control = control
        self.snapshotValue = snapshotValue
        self.label = label
        self.onEvent = onEvent
        let safeStep = step > 0 ? step : 1
        let safeUpper = upper > lower ? upper : lower + safeStep
        self.range = lower...safeUpper
        self.step = safeStep
        _value = State(initialValue: min(max(snapshotValue, lower), safeUpper))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let label, !label.isEmpty {
                HStack {
                    Text(label).font(.custom("Arial", size: 11)).fontWeight(.medium).opacity(0.7)
                    Spacer()
                    Text(String(format: "%g", value))
                        .font(.system(size: 11, design: .monospaced)).opacity(0.6)
                }
            }
            Slider(value: $value, in: range, step: step, onEditingChanged: { editing = $0 })
                .disabled(control.disabled == true)
        }
        .onChange(of: value) { newValue in
            if suppressEmit { suppressEmit = false; return }
            onEvent(control.id, "change", String(newValue), "")
        }
        .onChange(of: snapshotValue) { newValue in
            guard !editing else { return }
            let target = min(max(newValue, range.lowerBound), range.upperBound)
            if target != value {
                suppressEmit = true
                value = target
            }
        }
    }
}

private struct PanelToggleControl: View {
    let control: PanelControlSnapshot
    let snapshotValue: Bool
    let isSwitch: Bool
    let onEvent: (String, String, String, String) -> Void

    @State private var value: Bool
    @State private var suppressEmit = false

    init(control: PanelControlSnapshot,
         snapshotValue: Bool,
         isSwitch: Bool,
         onEvent: @escaping (String, String, String, String) -> Void) {
        self.control = control
        self.snapshotValue = snapshotValue
        self.isSwitch = isSwitch
        self.onEvent = onEvent
        _value = State(initialValue: snapshotValue)
    }

    var body: some View {
        Group {
            if isSwitch {
                Toggle(isOn: $value) {
                    Text(control.label ?? "").font(.custom("Arial", size: 13))
                }
                .toggleStyle(.switch)
            } else {
                Toggle(isOn: $value) {
                    Text(control.label ?? "").font(.custom("Arial", size: 13))
                }
                .toggleStyle(.checkbox)
            }
        }
        .disabled(control.disabled == true)
        .onChange(of: value) { newValue in
            if suppressEmit { suppressEmit = false; return }
            onEvent(control.id, "change", newValue ? "true" : "false", "")
        }
        .onChange(of: snapshotValue) { newValue in
            if newValue != value {
                suppressEmit = true
                value = newValue
            }
        }
    }
}

private struct PanelSelectControl: View {
    let control: PanelControlSnapshot
    let snapshotValue: String
    let onEvent: (String, String, String, String) -> Void

    @State private var selection: String
    @State private var suppressEmit = false

    init(control: PanelControlSnapshot,
         snapshotValue: String,
         onEvent: @escaping (String, String, String, String) -> Void) {
        self.control = control
        self.snapshotValue = snapshotValue
        self.onEvent = onEvent
        _selection = State(initialValue: snapshotValue)
    }

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(control.options ?? [], id: \.value) { opt in
                Text(opt.label).tag(opt.value)
            }
        }
        .pickerStyle(.menu)
        .disabled(control.disabled == true)
        .onChange(of: selection) { newValue in
            if suppressEmit { suppressEmit = false; return }
            onEvent(control.id, "change", newValue, "")
        }
        .onChange(of: snapshotValue) { newValue in
            if newValue != selection {
                suppressEmit = true
                selection = newValue
            }
        }
    }
}

private struct PanelColorControl: View {
    let control: PanelControlSnapshot
    let snapshotValue: String
    let onEvent: (String, String, String, String) -> Void

    @State private var color: Color
    @State private var suppressEmit = false

    init(control: PanelControlSnapshot,
         snapshotValue: String,
         onEvent: @escaping (String, String, String, String) -> Void) {
        self.control = control
        self.snapshotValue = snapshotValue
        self.onEvent = onEvent
        _color = State(initialValue: Color(cssHex: snapshotValue) ?? .black)
    }

    var body: some View {
        ColorPicker("", selection: $color)
            .labelsHidden()
            .disabled(control.disabled == true)
            .onChange(of: color) { newValue in
                if suppressEmit { suppressEmit = false; return }
                onEvent(control.id, "change", newValue.hexString, "")
            }
            .onChange(of: snapshotValue) { newValue in
                if newValue != color.hexString {
                    suppressEmit = true
                    color = Color(cssHex: newValue) ?? .black
                }
            }
    }
}

private struct PanelPinControl: View {
    let control: PanelControlSnapshot
    let snapshotValue: String
    let length: Int
    let masked: Bool
    let autoSubmit: Bool
    let onEvent: (String, String, String, String) -> Void

    @State private var pin: String
    @State private var suppressEmit = false
    @FocusState private var focused: Bool

    init(control: PanelControlSnapshot,
         snapshotValue: String,
         length: Int,
         masked: Bool,
         autoSubmit: Bool,
         onEvent: @escaping (String, String, String, String) -> Void) {
        self.control = control
        self.snapshotValue = snapshotValue
        self.length = max(3, min(12, length))
        self.masked = masked
        self.autoSubmit = autoSubmit
        self.onEvent = onEvent
        _pin = State(initialValue: String(snapshotValue.prefix(max(3, min(12, length)))))
    }

    private func boxView(_ index: Int) -> some View {
        let chars = Array(pin)
        let filledIndex = min(chars.count, length - 1)
        let display: String = index < chars.count ? (masked ? "\u{2022}" : String(chars[index])) : ""
        let isActive = focused && index == filledIndex
        return RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.gray.opacity(0.22))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(isActive ? Color.accentColor : Color.gray.opacity(0.4), lineWidth: 1)
            )
            .overlay(Text(display).font(.system(size: 18, weight: .semibold, design: .monospaced)))
            .frame(width: 32, height: 40)
    }

    var body: some View {
        ZStack {
            HStack(spacing: 6) {
                ForEach(0..<length, id: \.self) { boxView($0) }
            }
            // Transparent field that actually captures keyboard input.
            TextField("", text: $pin)
                .textFieldStyle(.plain)
                .foregroundColor(.clear)
                .accentColor(.clear)
                .multilineTextAlignment(.center)
                .focused($focused)
                .frame(width: CGFloat(length) * 38, height: 40)
                .opacity(0.02)
        }
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        .disabled(control.disabled == true)
        .onChange(of: pin) { newValue in
            let filtered = String(newValue.filter { $0.isNumber }.prefix(length))
            if filtered != newValue {
                pin = filtered
                return
            }
            if suppressEmit { suppressEmit = false; return }
            onEvent(control.id, "change", filtered, "")
            if autoSubmit && filtered.count == length {
                onEvent(control.id, "submit", filtered, "")
            }
        }
        .onChange(of: snapshotValue) { newValue in
            let clamped = String(newValue.prefix(length))
            if !focused && clamped != pin {
                suppressEmit = true
                pin = clamped
            }
        }
    }
}

/// View for a complete panel.
struct PanelCardView: View {
    let snapshot: PanelSnapshot
    /// (panelId, controlId, eventName, value, extra)
    let onEvent: (String, String, String, String, String) -> Void

    private func collectValues() -> [String: String] {
        var out: [String: String] = [:]
        func visit(_ controls: [PanelControlSnapshot]?) {
            guard let controls else { return }
            for c in controls {
                switch c.type {
                case "section": visit(c.controls)
                case "button", "text", "html": continue
                default:
                    if let v = c.value { out[c.id] = v.stringValue }
                }
            }
        }
        visit(snapshot.controls)
        return out
    }

    private let bg = Color.white
    private let fg = Color(red: 0.122, green: 0.161, blue: 0.216)

    private var panelWidth: CGFloat {
        switch snapshot.width ?? "" {
        case "small": return 220
        case "medium": return 280
        case "large": return 360
        default:
            if let w = snapshot.width, let n = Double(w.replacingOccurrences(of: "px", with: "")) {
                return CGFloat(max(180, min(520, n)))
            }
            return 300
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = snapshot.title, !title.isEmpty {
                Text(title)
                    .font(.custom("Arial", size: 14)).fontWeight(.bold)
            }
            if let desc = snapshot.description, !desc.isEmpty {
                Text(desc)
                    .font(.custom("Arial", size: 13))
                    .opacity(0.82)
                    .fixedSize(horizontal: false, vertical: true)
            }
            let values = collectValues()
            ForEach(snapshot.controls ?? [], id: \.id) { control in
                PanelControlView(control: control, onEvent: { controlId, eventName, value, _ in
                    let valuesJSON = (try? String(data: JSONSerialization.data(withJSONObject: values), encoding: .utf8)) ?? "{}"
                    onEvent(snapshot.id, controlId, eventName, value, valuesJSON)
                }, allValues: values)
            }
        }
        .padding(12)
        .frame(width: panelWidth, alignment: .leading)
        .background(bg)
        .foregroundColor(fg)
        .cornerRadius(14)
        .shadow(color: .black.opacity(0.12), radius: 14, y: 5)
        .preferredColorScheme(.light)
    }
}

@MainActor
final class PanelOverlayModel: ObservableObject {
    @Published var panels: [PanelSnapshot] = []
    let position: String
    var onEvent: ((String, String, String, String, String, String) -> Void)?

    init(position: String = "bottom-right") {
        self.position = position
    }
}

/// Stack of panels grouped by position.
struct PanelOverlayView: View {
    @ObservedObject var model: PanelOverlayModel

    private var stackAlignment: HorizontalAlignment {
        switch model.position {
        case "top-left", "bottom-left": return .leading
        case "top-right", "bottom-right": return .trailing
        default: return .center
        }
    }

    var body: some View {
        let snapshots = model.panels
        VStack(alignment: stackAlignment, spacing: 8) {
            ForEach(snapshots, id: \.id) { snapshot in
                PanelCardView(snapshot: snapshot) { panelId, controlId, eventName, value, extra in
                    let groupId = snapshot.groupId ?? ""
                    model.onEvent?(groupId, panelId, controlId, eventName, value, extra)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
    }
}

/// Manages floating interactive panel windows. Each screen position
/// (top-left, top-right, bottom-left, bottom-right, center) gets its own
/// NSPanel so panels stack independently in each corner.
@MainActor
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}

@MainActor
public final class PanelOverlayPanelController {
    private final class PositionSlot {
        let model: PanelOverlayModel
        var panel: NSPanel?
        init(model: PanelOverlayModel, panel: NSPanel? = nil) {
            self.model = model
            self.panel = panel
        }
    }
    private var slots: [String: PositionSlot] = [:]
    private let screenInset: CGFloat = 16
    private var eventHandler: ((String, String, String, String, String, String) -> Void)?
    /// Authoritative panel state keyed by groupId. The rendered overlay is
    /// always the merge of every group's panels, so when a group is disabled
    /// or stops reporting a panel, it disappears on the next render.
    private var panelsByGroup: [String: [PanelSnapshot]] = [:]

    public init() {}

    public func setEventHandler(_ handler: @escaping (String, String, String, String, String, String) -> Void) {
        self.eventHandler = handler
        for (_, slot) in slots {
            slot.model.onEvent = handler
        }
    }

    /// Replace the panels for a single group (per-event dispatch). An empty
    /// array removes the group's panels entirely.
    public func update(panels: [PanelSnapshot], forGroup groupID: String) {
        if panels.isEmpty {
            if panelsByGroup.removeValue(forKey: groupID) == nil { return }
        } else {
            if panelsByGroup[groupID] == panels { return }
            panelsByGroup[groupID] = panels
        }
        render()
    }

    /// Replace the entire panel set across all groups at once (tick loop).
    /// Any group not present is treated as having no panels and is cleared.
    public func replaceAll(_ panelsByGroupID: [String: [PanelSnapshot]]) {
        let next = panelsByGroupID.filter { !$0.value.isEmpty }
        if next == panelsByGroup { return }
        panelsByGroup = next
        render()
    }

    /// Immediately drop a group's panels (called when a group is disabled).
    public func removePanels(forGroup groupID: String) {
        if panelsByGroup.removeValue(forKey: groupID) != nil { render() }
    }

    private func render() {
        // Deterministic group ordering so identical state always produces an
        // identical layout (avoids needless re-renders / input churn).
        var byPosition: [String: [PanelSnapshot]] = [:]
        for groupID in panelsByGroup.keys.sorted() {
            for panel in panelsByGroup[groupID] ?? [] {
                let pos = panel.position ?? "bottom-right"
                byPosition[pos, default: []].append(panel)
            }
        }

        let allPositions = Set(byPosition.keys).union(Set(slots.keys))
        for pos in allPositions {
            let snapshots = byPosition[pos] ?? []
            if snapshots.isEmpty {
                if let slot = slots[pos] {
                    slot.panel?.orderOut(nil)
                    slot.model.panels = []
                }
                continue
            }
            let slot = ensureSlot(position: pos)
            let changed = slot.model.panels != snapshots
            if changed {
                slot.model.panels = snapshots
            }
            let panel = slot.panel!
            if changed || !panel.isVisible {
                resizeAndPosition(panel, position: pos)
                if !panel.isVisible {
                    panel.orderFrontRegardless()
                }
                // Schedule a second resize after SwiftUI processes the
                // @Published change — corrects the first-display case
                // where fittingSize measured stale/empty content above.
                if changed {
                    DispatchQueue.main.async { [weak self] in
                        self?.resizeAndPosition(panel, position: pos)
                    }
                }
            }
        }
    }

    public func teardown() {
        panelsByGroup.removeAll()
        for (_, slot) in slots {
            slot.panel?.orderOut(nil)
            slot.model.panels = []
        }
        slots.removeAll()
    }

    private func ensureSlot(position: String) -> PositionSlot {
        if let slot = slots[position] {
            return slot
        }
        let model = PanelOverlayModel(position: position)
        model.onEvent = eventHandler
        let hosting = NSHostingView(rootView: PanelOverlayView(model: model))
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 40),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
        panel.ignoresMouseEvents = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
        hosting.translatesAutoresizingMaskIntoConstraints = true
        panel.contentView = hosting
        let slot = PositionSlot(model: model)
        slot.panel = panel
        slots[position] = slot
        return slot
    }

    private func resizeAndPosition(_ panel: NSPanel, position: String) {
        guard let hosting = panel.contentView else { return }
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        guard let screen = NSScreen.main else {
            panel.setContentSize(size)
            return
        }
        let frame = screen.frame
        let origin: NSPoint
        switch position {
        case "top-left":
            origin = NSPoint(x: frame.minX + screenInset, y: frame.maxY - size.height - screenInset)
        case "top-right":
            origin = NSPoint(x: frame.maxX - size.width - screenInset, y: frame.maxY - size.height - screenInset)
        case "bottom-left":
            origin = NSPoint(x: frame.minX + screenInset, y: frame.minY + screenInset)
        case "center":
            origin = NSPoint(
                x: frame.midX - size.width / 2,
                y: frame.midY - size.height / 2
            )
        default: // bottom-right
            origin = NSPoint(x: frame.maxX - size.width - screenInset, y: frame.minY + screenInset)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }
}

// MARK: - Color helpers

extension Color {
    init?(cssHex hex: String) {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        guard cleaned.count == 6, let val = UInt64(cleaned, radix: 16) else { return nil }
        self.init(
            red: Double((val >> 16) & 0xFF) / 255.0,
            green: Double((val >> 8) & 0xFF) / 255.0,
            blue: Double(val & 0xFF) / 255.0
        )
    }

    var hexString: String {
        guard let components = NSColor(self).usingColorSpace(.sRGB) else { return "#000000" }
        let r = Int(components.redComponent * 255)
        let g = Int(components.greenComponent * 255)
        let b = Int(components.blueComponent * 255)
        return String(format: "#%02x%02x%02x", r, g, b)
    }
}

#endif
