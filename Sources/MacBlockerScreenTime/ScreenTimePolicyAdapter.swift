import Foundation
import MacBlockerCore

public struct AuthorizedScreenTimeTargets: Codable, Equatable, Sendable {
    public var applicationTargetIDs: Set<String>
    public var categoryTargetIDs: Set<String>
    public var webDomainTargetIDs: Set<String>

    public init(
        applicationTargetIDs: Set<String> = [],
        categoryTargetIDs: Set<String> = [],
        webDomainTargetIDs: Set<String> = []
    ) {
        self.applicationTargetIDs = applicationTargetIDs
        self.categoryTargetIDs = categoryTargetIDs
        self.webDomainTargetIDs = webDomainTargetIDs
    }

    public var allTargetIDs: Set<String> {
        applicationTargetIDs
            .union(categoryTargetIDs)
            .union(webDomainTargetIDs)
    }
}

public protocol AuthorizedScreenTimeTargetProviding: Sendable {
    func authorizedTargets() async throws -> AuthorizedScreenTimeTargets
}

public actor ScreenTimePolicyAdapter: PolicyApplying {
    public let capabilities: PlatformCapabilities
    private let targetProvider: AuthorizedScreenTimeTargetProviding
    private var activeShieldedTargetIDs: Set<String> = []
    private var latestStatus: OverlayStatus?

    public init(
        platform: RuntimePlatform,
        targetProvider: AuthorizedScreenTimeTargetProviding
    ) {
        self.capabilities = platform == .iPadOS ? .iPadOS : .iOS
        self.targetProvider = targetProvider
    }

    public func apply(_ decisions: [PolicyDecision]) async throws {
        let authorized = try await targetProvider.authorizedTargets()

        for decision in decisions {
            switch decision.action {
            case .shield:
                try authorize(decision.targetIDs, authorized: authorized)
                activeShieldedTargetIDs.formUnion(decision.targetIDs)
                latestStatus = decision.overlayStatus
            case .unshield, .allow:
                try authorize(decision.targetIDs, authorized: authorized)
                activeShieldedTargetIDs.subtract(decision.targetIDs)
            case .showStatus:
                latestStatus = decision.overlayStatus
            case .requestSnooze, .log, .quarantine:
                continue
            }
        }

        // The Xcode app target should translate activeShieldedTargetIDs into
        // FamilyControls tokens and write them to ManagedSettingsStore:
        // store.shield.applications = selectedApplicationTokens
        // store.shield.applicationCategories = .specific(selectedCategoryTokens)
        // store.shield.webDomains = selectedWebDomainTokens
    }

    public func currentShieldedTargetIDs() -> Set<String> {
        activeShieldedTargetIDs
    }

    public func currentStatus() -> OverlayStatus? {
        latestStatus
    }

    private func authorize(
        _ targetIDs: Set<String>,
        authorized: AuthorizedScreenTimeTargets
    ) throws {
        for targetID in targetIDs where !authorized.allTargetIDs.contains(targetID) {
            throw PolicyApplicationError.unauthorizedTarget(targetID)
        }
    }
}
