import Foundation

public struct SnoozeApprovalResult: Equatable, Sendable {
    public var approvedGroupIDs: [String]
    public var rejectedGroupIDs: [String]
    public var unmatchedRequestIDs: [String]

    public init(
        approvedGroupIDs: [String] = [],
        rejectedGroupIDs: [String] = [],
        unmatchedRequestIDs: [String] = []
    ) {
        self.approvedGroupIDs = approvedGroupIDs
        self.rejectedGroupIDs = rejectedGroupIDs
        self.unmatchedRequestIDs = unmatchedRequestIDs
    }
}

/// Approves shield-tap snooze requests against each group's snooze rules and
/// returns an updated usage snapshot with the snooze windows applied. Runs in
/// the main app (extensions only record requests).
public enum SnoozeApprovalService {
    public static func process(
        requests: [SnoozeRequest],
        groups: [BlockGroup],
        usage: UsageSnapshot,
        now: Date = Date()
    ) -> (usage: UsageSnapshot, result: SnoozeApprovalResult) {
        var updatedUsage = usage
        var result = SnoozeApprovalResult()

        let groupsByID = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // Count requests per group so snoozeConfirmations can require multiple
        // presses before a snooze activates.
        var requestCountByGroup: [String: Int] = [:]
        for request in requests {
            guard let groupID = request.groupID else {
                result.unmatchedRequestIDs.append(request.id)
                continue
            }
            requestCountByGroup[groupID, default: 0] += 1
        }

        for (groupID, count) in requestCountByGroup {
            guard let group = groupsByID[groupID] else {
                result.rejectedGroupIDs.append(groupID)
                continue
            }

            let requiredPresses = max(1, group.snoozeConfirmations)
            let existing = updatedUsage.snoozesByGroup[groupID]
            let phase = existing?.phase(at: now) ?? .none

            let eligible = group.allowSnooze
                && group.groupType != .custom
                && count >= requiredPresses
                && (phase == .none)

            guard eligible else {
                result.rejectedGroupIDs.append(groupID)
                continue
            }

            updatedUsage.snoozesByGroup[groupID] = makeSnooze(for: group, now: now)
            updatedUsage.totalSnoozedSecondsByGroup[groupID, default: 0] +=
                TimeInterval(max(0, group.snoozeMinutes) * 60)
            result.approvedGroupIDs.append(groupID)
        }

        result.approvedGroupIDs.sort()
        result.rejectedGroupIDs.sort()
        return (updatedUsage, result)
    }

    private static func makeSnooze(for group: BlockGroup, now: Date) -> SnoozeState {
        let activationDelay = TimeInterval(max(0, group.snoozeActivationDelayMinutes) * 60)
        let duration = TimeInterval(max(0, group.snoozeMinutes) * 60)
        let cooldown = TimeInterval(max(0, group.snoozeCooldownMinutes) * 60)

        let startsAt = now.addingTimeInterval(activationDelay)
        let until = startsAt.addingTimeInterval(duration)
        let cooldownUntil = until.addingTimeInterval(cooldown)

        return SnoozeState(
            startsAt: activationDelay > 0 ? startsAt : nil,
            until: until,
            cooldownUntil: cooldown > 0 ? cooldownUntil : nil,
            justification: "Approved from shield"
        )
    }
}
