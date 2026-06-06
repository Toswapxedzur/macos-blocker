import Foundation

#if os(iOS)
import FamilyControls

/// Thin wrapper around FamilyControls authorization. Call `requestIndividual()`
/// before showing the picker or applying shields. On the App Store this
/// requires the approved Family Controls (Distribution) entitlement.
public enum ScreenTimeAuthorization {
    public static var isAuthorized: Bool {
        AuthorizationCenter.shared.authorizationStatus == .approved
    }

    @discardableResult
    public static func requestIndividual() async throws -> Bool {
        try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
        return isAuthorized
    }

    public static func revoke() {
        AuthorizationCenter.shared.revokeAuthorization { _ in }
    }
}
#endif
