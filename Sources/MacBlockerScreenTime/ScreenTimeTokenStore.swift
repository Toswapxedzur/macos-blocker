import Foundation
import MacBlockerCore

#if os(iOS)
import FamilyControls
import ManagedSettings

/// The opaque FamilyControls tokens, keyed by the `BlockTarget.id` values the
/// core uses. Tokens are `Codable` but only meaningful on the same device and
/// account that produced them.
public struct ScreenTimeTokenSet: Codable, Sendable {
    public var applications: [String: ApplicationToken]
    public var categories: [String: ActivityCategoryToken]
    public var webDomains: [String: WebDomainToken]

    public init(
        applications: [String: ApplicationToken] = [:],
        categories: [String: ActivityCategoryToken] = [:],
        webDomains: [String: WebDomainToken] = [:]
    ) {
        self.applications = applications
        self.categories = categories
        self.webDomains = webDomains
    }

    public var isEmpty: Bool {
        applications.isEmpty && categories.isEmpty && webDomains.isEmpty
    }
}

/// Persists the FamilyControls token set in the App Group container so both the
/// app and the extensions can resolve `BlockTarget` IDs into tokens.
public final class ScreenTimeTokenStore: @unchecked Sendable {
    public static let fileName = "screentime-tokens.json"

    private let store: SharedAppGroupStore

    public init(store: SharedAppGroupStore = SharedAppGroupStore()) {
        self.store = store
    }

    public func load() -> ScreenTimeTokenSet {
        store.readJSON(ScreenTimeTokenSet.self, from: Self.fileName) ?? ScreenTimeTokenSet()
    }

    public func save(_ tokens: ScreenTimeTokenSet) {
        store.writeJSON(tokens, to: Self.fileName)
    }

    /// Derives a stable target ID for a token by base64-encoding its `Codable`
    /// representation. The same app/category/domain therefore yields the same
    /// `BlockTarget.id` across launches.
    public static func stableID<T: Encodable>(for token: T) -> String {
        let data = (try? SharedAppGroupStore.encoder.encode(token)) ?? Data()
        return data.base64EncodedString()
    }

    /// Converts a picker selection into both the token set (for enforcement)
    /// and `BlockTarget`s (for the core model / editor). Display names are
    /// generic because labels require ManagedSettingsUI; the editor can rename.
    public func makeTargets(
        from selection: FamilyActivitySelection
    ) -> (targets: [BlockTarget], tokens: ScreenTimeTokenSet) {
        var tokens = ScreenTimeTokenSet()
        var targets: [BlockTarget] = []

        for (index, token) in selection.applicationTokens.enumerated() {
            let id = Self.stableID(for: token)
            tokens.applications[id] = token
            targets.append(
                BlockTarget(
                    id: id,
                    kind: .application,
                    displayName: "App \(index + 1)",
                    normalizedValue: id,
                    tags: ["screenTime", "application"]
                )
            )
        }

        for (index, token) in selection.categoryTokens.enumerated() {
            let id = Self.stableID(for: token)
            tokens.categories[id] = token
            targets.append(
                BlockTarget(
                    id: id,
                    kind: .category,
                    displayName: "Category \(index + 1)",
                    normalizedValue: id,
                    tags: ["screenTime", "category"]
                )
            )
        }

        for (index, token) in selection.webDomainTokens.enumerated() {
            let id = Self.stableID(for: token)
            tokens.webDomains[id] = token
            targets.append(
                BlockTarget(
                    id: id,
                    kind: .webDomain,
                    displayName: "Web domain \(index + 1)",
                    normalizedValue: id,
                    tags: ["screenTime", "webDomain"]
                )
            )
        }

        return (targets, tokens)
    }

    /// The set of target IDs that currently have tokens, for authorization
    /// checks in `ScreenTimePolicyAdapter`.
    public func authorizedTargets() -> AuthorizedScreenTimeTargets {
        let tokens = load()
        return AuthorizedScreenTimeTargets(
            applicationTargetIDs: Set(tokens.applications.keys),
            categoryTargetIDs: Set(tokens.categories.keys),
            webDomainTargetIDs: Set(tokens.webDomains.keys)
        )
    }
}

/// Backs `ScreenTimePolicyAdapter` with the persisted token set.
public struct TokenBackedTargetProvider: AuthorizedScreenTimeTargetProviding {
    private let tokenStore: ScreenTimeTokenStore

    public init(tokenStore: ScreenTimeTokenStore = ScreenTimeTokenStore()) {
        self.tokenStore = tokenStore
    }

    public func authorizedTargets() async throws -> AuthorizedScreenTimeTargets {
        tokenStore.authorizedTargets()
    }
}
#endif
