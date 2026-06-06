import SwiftUI
import MacBlockerCore

@MainActor
public struct MacBlockerRootView: View {
    @StateObject private var model: MacBlockerAppModel

    public init() {
        _model = StateObject(wrappedValue: MacBlockerAppModel())
    }

    public init(model: MacBlockerAppModel) {
        _model = StateObject(wrappedValue: model)
    }

    public var body: some View {
        NavigationSplitView {
            GroupListView(model: model)
                .navigationTitle("Block Groups")
        } detail: {
            DetailView(model: model)
        }
        .frame(minWidth: 980, minHeight: 640)
    }
}

private struct GroupListView: View {
    @ObservedObject var model: MacBlockerAppModel

    var body: some View {
        VStack(spacing: 0) {
            List(selection: selectedGroupBinding) {
                ForEach(model.state.groups) { group in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(group.name)
                            .font(.headline)
                        Text(summary(for: group))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(group.id)
                    .padding(.vertical, 4)
                }
            }

            Divider()

            VStack(spacing: 8) {
                HStack {
                    Button("Add App Group") {
                        model.addGroup(type: .app)
                    }
                    Button("Add Custom") {
                        model.addGroup(type: .custom)
                    }
                }
                Button("Reset Sample Data", role: .destructive) {
                    model.resetSampleData()
                }
            }
            .padding()
        }
    }

    private var selectedGroupBinding: Binding<String?> {
        Binding(
            get: { model.state.selectedGroupID },
            set: { if let id = $0 { model.selectGroup(id) } }
        )
    }

    private func summary(for group: BlockGroup) -> String {
        let mode = group.mode.rawValue
        let targets = group.targets.map(\.displayName).joined(separator: ", ")
        return "\(group.groupType.rawValue) · \(mode) · \(targets.isEmpty ? "no targets" : targets)"
    }
}

private struct DetailView: View {
    @ObservedObject var model: MacBlockerAppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let group = model.selectedGroup {
                    GroupEditorView(model: model, group: group)
                    StatusCard(model: model)
                    DecisionCard(decisions: model.decisions)
                    LogCard(entries: model.state.logEntries)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "shield")
                            .font(.largeTitle)
                        Text("No Group Selected")
                            .font(.title2.bold())
                        Text("Add or select a block group.")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 360)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(model.selectedGroup?.name ?? "macosBlocker")
    }
}

private struct GroupEditorView: View {
    @ObservedObject var model: MacBlockerAppModel
    var group: BlockGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Editor")
                    .font(.title2.bold())
                Spacer()
                Button("Delete", role: .destructive) {
                    model.deleteSelectedGroup()
                }
            }

            TextField("Group name", text: binding(\.name))
                .textFieldStyle(.roundedBorder)

            Toggle("Enabled", isOn: binding(\.enabled))

            Picker("Mode", selection: binding(\.mode)) {
                Text("Instant").tag(BlockingMode.instant)
                Text("After minutes").tag(BlockingMode.afterMinutes)
                Text("Timer").tag(BlockingMode.timer)
            }
            .pickerStyle(.segmented)

            Stepper(
                "Allowed minutes: \(group.allowedMinutes)",
                value: binding(\.allowedMinutes),
                in: 1...480
            )

            Stepper(
                "Current usage minutes: \(usageMinutes)",
                value: usageBinding,
                in: 0...480
            )

            Picker("Active target", selection: activeTargetBinding) {
                ForEach(model.allTargets) { target in
                    Text(target.displayName).tag(Optional(target.id))
                }
            }

            TextField("Shield/status message", text: binding(\.fallbackMessage), axis: .vertical)
                .textFieldStyle(.roundedBorder)

            if group.groupType == .custom {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Custom JavaScript Policy")
                        .font(.headline)
                    TextEditor(text: binding(\.customRuleSource))
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 220)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(.quaternary)
                        )
                    HStack {
                        Button("Run usageThresholdReached") {
                            model.runSelectedCustomRule(eventType: "usageThresholdReached")
                        }
                        Button("Run scheduleChanged") {
                            model.runSelectedCustomRule(eventType: "scheduleChanged")
                        }
                    }
                }
            }

            HStack {
                Button("Evaluate Selected Target") {
                    model.evaluateSelectedTarget()
                }
                if let error = model.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .padding()
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.quaternary))
    }

    private var usageMinutes: Int {
        Int((model.state.usage.usageByGroupSeconds[group.id] ?? 0) / 60)
    }

    private var usageBinding: Binding<Int> {
        Binding(
            get: { usageMinutes },
            set: { model.setUsage(minutes: $0, for: group.id) }
        )
    }

    private var activeTargetBinding: Binding<String?> {
        Binding(
            get: { model.state.selectedTargetID },
            set: { if let id = $0 { model.selectTarget(id) } }
        )
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<BlockGroup, Value>) -> Binding<Value> {
        Binding(
            get: { group[keyPath: keyPath] },
            set: { newValue in
                model.updateSelectedGroup { $0[keyPath: keyPath] = newValue }
            }
        )
    }
}

private struct StatusCard: View {
    @ObservedObject var model: MacBlockerAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Status Window Replacement")
                .font(.title3.bold())
            if let status = model.status {
                Text(status.title)
                    .font(.headline)
                Text(status.message)
                    .foregroundStyle(.secondary)
            } else {
                Text("No active status. Evaluate or run a custom rule.")
                    .foregroundStyle(.secondary)
            }
            Text("On iOS this maps to shield text/status surfaces. On Mac this maps to a floating status window.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

private struct DecisionCard: View {
    var decisions: [PolicyDecision]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Policy Decisions")
                .font(.title3.bold())
            if decisions.isEmpty {
                Text("No decisions yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(decisions.enumerated()), id: \.offset) { _, decision in
                    HStack(alignment: .top) {
                        Text(decision.action.rawValue)
                            .font(.caption.bold())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.quaternary)
                            .clipShape(Capsule())
                        VStack(alignment: .leading) {
                            Text(decision.reason.isEmpty ? decision.shieldMessage : decision.reason)
                            Text(decision.targetIDs.sorted().joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.quaternary))
    }
}

private struct LogCard: View {
    var entries: [PolicyApplicationLogEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Log")
                .font(.title3.bold())
            if entries.isEmpty {
                Text("No log entries yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(entries.prefix(30).enumerated()), id: \.offset) { _, entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(entry.action.rawValue): \(entry.message)")
                        Text(entry.date.formatted())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Divider()
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.quaternary))
    }
}
