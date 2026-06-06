import Foundation

public struct PolicyEvaluator: Sendable {
    public init() {}

    public func evaluate(
        groups: [BlockGroup],
        usage: UsageSnapshot,
        context: ActivityContext,
        calendar: Calendar = .current
    ) -> EvaluationResult {
        var decisions: [PolicyDecision] = []
        var timerItems: [TimerDisplayItem] = []

        for group in groups.reversed() {
            guard group.isActive(at: context.now, calendar: calendar) else {
                continue
            }
            guard !isSnoozed(groupID: group.id, usage: usage, at: context.now) else {
                continue
            }

            let matchingTargets = matchingTargetIDs(in: group, context: context)
            guard !matchingTargets.isEmpty || group.groupType == .custom else {
                continue
            }

            switch group.mode {
            case .instant:
                decisions.append(shieldDecision(for: group, targetIDs: matchingTargets))
            case .afterMinutes, .timer:
                let usedSeconds = usage.usageByGroupSeconds[group.id] ?? 0
                let allowedSeconds = TimeInterval(max(0, group.allowedMinutes) * 60)
                let remaining = max(0, allowedSeconds - usedSeconds)
                timerItems.append(
                    TimerDisplayItem(
                        groupID: group.id,
                        name: group.name,
                        remainingSeconds: remaining
                    )
                )
                if remaining <= 0 {
                    decisions.append(shieldDecision(for: group, targetIDs: matchingTargets))
                } else {
                    decisions.append(statusDecision(for: group, targetIDs: matchingTargets, remainingSeconds: remaining))
                }
            }
        }

        return EvaluationResult(decisions: decisions, visibleTimerItems: timerItems)
    }

    private func isSnoozed(groupID: String, usage: UsageSnapshot, at date: Date) -> Bool {
        usage.snoozesByGroup[groupID]?.phase(at: date) == .active
    }

    private func matchingTargetIDs(in group: BlockGroup, context: ActivityContext) -> Set<String> {
        let candidates = Set(group.targets.map(\.id))
        if candidates.isEmpty {
            return []
        }

        if let target = context.target, candidates.contains(target.id) {
            return [target.id]
        }

        let activeMatches = candidates.intersection(context.activeTargetIDs)
        return activeMatches.isEmpty ? [] : activeMatches
    }

    private func shieldDecision(for group: BlockGroup, targetIDs: Set<String>) -> PolicyDecision {
        let message = group.fallbackMessage.isEmpty ? "\(group.name) is blocked." : group.fallbackMessage
        return PolicyDecision(
            action: .shield,
            groupID: group.id,
            targetIDs: targetIDs,
            reason: message,
            shieldMessage: message,
            overlayStatus: OverlayStatus(
                title: group.name,
                message: message,
                timerGroupID: group.id
            )
        )
    }

    private func statusDecision(
        for group: BlockGroup,
        targetIDs: Set<String>,
        remainingSeconds: TimeInterval
    ) -> PolicyDecision {
        let message = "\(group.name): \(Int(ceil(remainingSeconds / 60))) minutes remaining."
        return PolicyDecision(
            action: .showStatus,
            groupID: group.id,
            targetIDs: targetIDs,
            reason: message,
            overlayStatus: OverlayStatus(
                title: group.name,
                message: message,
                timerGroupID: group.id
            )
        )
    }
}
