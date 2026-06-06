import Foundation
import Combine
import MacBlockerCore
#if os(macOS)
import MacBlockerMacControl
#endif

@MainActor
public final class MacBlockerAppModel: ObservableObject {
    @Published public private(set) var state: BlockerAppState
    @Published public private(set) var decisions: [PolicyDecision] = []
    @Published public private(set) var status: OverlayStatus?
    @Published public private(set) var lastError: String?

    private let store: BlockerStateStore
    private let evaluator = PolicyEvaluator()
    #if os(macOS)
    /// Publishes the compiled block policy to the shared store so the always-on
    /// Endpoint Security extension / daemon can enforce it. The editor itself
    /// never runs the kill sweep (`runTerminationSweep: false`) — terminating
    /// apps is the always-on core's job.
    private let macEnforcement = EndpointSecurityPolicyAdapter(runTerminationSweep: false)
    #endif

    public init(store: BlockerStateStore = BlockerStateStore()) {
        self.store = store
        do {
            self.state = try store.load()
        } catch {
            self.state = BlockerAppState()
            self.lastError = "Could not load saved state: \(error)"
        }
        evaluateSelectedTarget()
    }

    public var selectedGroup: BlockGroup? {
        state.groups.first { $0.id == state.selectedGroupID }
    }

    public var selectedTarget: BlockTarget? {
        allTargets.first { $0.id == state.selectedTargetID }
    }

    public var allTargets: [BlockTarget] {
        let targets = state.groups.flatMap(\.targets) + BlockerAppState.sampleTargets
        var seen = Set<String>()
        return targets.filter { seen.insert($0.id).inserted }
    }

    public func selectGroup(_ groupID: String) {
        mutate {
            $0.selectedGroupID = groupID
            if let firstTarget = $0.groups.first(where: { $0.id == groupID })?.targets.first {
                $0.selectedTargetID = firstTarget.id
            }
        }
    }

    public func selectTarget(_ targetID: String) {
        mutate { $0.selectedTargetID = targetID }
        evaluateSelectedTarget()
    }

    public func addGroup(type: BlockGroupType) {
        let target = allTargets.first ?? BlockerAppState.sampleTargets[0]
        var group = BlockGroup(
            groupType: type,
            name: type == .custom ? "New Custom Rule" : "New Block Group",
            targets: [target]
        )
        if type == .custom {
            group.customRuleSource = BlockerAppState.sampleGroups.last?.customRuleSource ?? ""
        }
        mutate {
            $0.groups.append(group)
            $0.selectedGroupID = group.id
            $0.selectedTargetID = target.id
        }
        evaluateSelectedTarget()
    }

    public func deleteSelectedGroup() {
        guard let selectedGroupID = state.selectedGroupID else {
            return
        }
        mutate {
            $0.groups.removeAll { $0.id == selectedGroupID }
            $0.selectedGroupID = $0.groups.first?.id
            $0.selectedTargetID = $0.groups.first?.targets.first?.id
        }
        evaluateSelectedTarget()
    }

    public func updateSelectedGroup(_ update: (inout BlockGroup) -> Void) {
        guard let index = state.groups.firstIndex(where: { $0.id == state.selectedGroupID }) else {
            return
        }
        mutate {
            update(&$0.groups[index])
        }
        evaluateSelectedTarget()
    }

    public func setUsage(minutes: Int, for groupID: String) {
        mutate {
            $0.usage.usageByGroupSeconds[groupID] = TimeInterval(max(0, minutes) * 60)
        }
        evaluateSelectedTarget()
    }

    public func evaluateSelectedTarget() {
        let context = ActivityContext(
            target: selectedTarget,
            activeTargetIDs: selectedTarget.map { [$0.id] } ?? [],
            platform: currentPlatform()
        )
        let result = evaluator.evaluate(groups: state.groups, usage: state.usage, context: context)
        decisions = result.decisions
        status = result.decisions.compactMap(\.overlayStatus).last
        appendLogEntries(for: result.decisions)
    }

    public func runSelectedCustomRule(eventType: String = "usageThresholdReached") {
        guard let group = selectedGroup else {
            return
        }
        do {
            let runtime = try CustomJavaScriptPolicyRuntime()
            try runtime.load(groupID: group.id, source: group.customRuleSource)
            let result = try runtime.dispatch(
                CustomRuleEvent(
                    type: eventType,
                    groupID: group.id,
                    target: selectedTarget
                )
            )
            decisions = result
            status = result.compactMap(\.overlayStatus).last
            appendLogEntries(for: result)
            lastError = nil
        } catch {
            lastError = "Custom rule failed: \(error)"
            appendLog(
                PolicyApplicationLogEntry(
                    action: .quarantine,
                    groupID: group.id,
                    message: String(describing: error)
                )
            )
        }
    }

    public func resetSampleData() {
        state = BlockerAppState()
        decisions = []
        status = nil
        lastError = nil
        save()
        evaluateSelectedTarget()
    }

    private func mutate(_ update: (inout BlockerAppState) -> Void) {
        update(&state)
        save()
    }

    private func save() {
        do {
            try store.save(state)
            lastError = nil
        } catch {
            lastError = "Could not save state: \(error)"
        }
        publishMacEnforcementPolicy()
    }

    /// Recompiles the current groups into a `GuardPolicy` (honoring each group's
    /// mode/schedule/usage) and writes it to the shared store for the always-on
    /// enforcement core. No-op off macOS.
    private func publishMacEnforcementPolicy() {
        #if os(macOS)
        let groups = state.groups
        let usage = state.usage
        Task { [macEnforcement] in
            try? await macEnforcement.applyGroups(groups, usage: usage)
        }
        #endif
    }

    private func appendLogEntries(for decisions: [PolicyDecision]) {
        for decision in decisions {
            appendLog(
                PolicyApplicationLogEntry(
                    action: decision.action,
                    groupID: decision.groupID,
                    message: decision.reason.isEmpty ? decision.action.rawValue : decision.reason
                )
            )
        }
    }

    private func appendLog(_ entry: PolicyApplicationLogEntry) {
        state.logEntries.insert(entry, at: 0)
        if state.logEntries.count > 200 {
            state.logEntries.removeLast(state.logEntries.count - 200)
        }
        save()
    }

    private func currentPlatform() -> RuntimePlatform {
        #if os(macOS)
        return .macOS
        #elseif os(iOS)
        return .iOS
        #else
        return .iOS
        #endif
    }
}
