import MacBlockerCore
import ManagedSettings
import UIKit

final class ShieldActionExtension: ShieldActionDelegate {
    private let sharedStore = SharedAppGroupStore()

    override init() {
        AppGroup.identifier = AppGroupIdentifier.value
        super.init()
    }

    override func handle(
        action: ShieldAction,
        for application: ApplicationToken,
        completionHandler: @escaping (ShieldActionResponse) -> Void
    ) {
        handle(action: action, kind: .application, completionHandler: completionHandler)
    }

    override func handle(
        action: ShieldAction,
        for webDomain: WebDomainToken,
        completionHandler: @escaping (ShieldActionResponse) -> Void
    ) {
        handle(action: action, kind: .webDomain, completionHandler: completionHandler)
    }

    override func handle(
        action: ShieldAction,
        for category: ActivityCategoryToken,
        completionHandler: @escaping (ShieldActionResponse) -> Void
    ) {
        handle(action: action, kind: .category, completionHandler: completionHandler)
    }

    private func handle(
        action: ShieldAction,
        kind: SnoozeRequest.TargetKind,
        completionHandler: @escaping (ShieldActionResponse) -> Void
    ) {
        switch action {
        case .primaryButtonPressed:
            // "Open macosBlocker" — keep the shield up; the user can open the app
            // from the home screen. (Extensions can't open URLs directly.)
            completionHandler(.defer)
        case .secondaryButtonPressed:
            // "Request Snooze" — record the request for the app to approve
            // against the group's snooze rules, and keep the shield visible.
            sharedStore.appendSnoozeRequest(SnoozeRequest(targetKind: kind))
            completionHandler(.defer)
        @unknown default:
            completionHandler(.none)
        }
    }
}
