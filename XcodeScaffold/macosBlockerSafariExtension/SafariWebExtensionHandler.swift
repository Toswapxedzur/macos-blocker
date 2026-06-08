import Foundation
import MacBlockerCore

#if canImport(SafariServices)
import SafariServices
#endif

/// Native messaging endpoint for the Safari Web Extension.
///
/// The Safari build of customBlocker is a thin client: default and platform
/// groups run entirely in the extension, but custom-rule groups forward each
/// `event-sandbox-request` here over `browser.runtime.sendNativeMessage`. This
/// handler runs the rule in JavaScriptCore via `SafariCustomRuleBridge` and
/// returns the same `{ ok, result }` shape the in-browser sandbox produces, so
/// the extension's DOM/redirect intent application is unchanged.
///
/// Add this file to a "macosBlocker Safari Extension" app-extension target in
/// Xcode (created by `xcrun safari-web-extension-converter`), link it against
/// `MacBlockerCore`, and add `Shared/AppGroupIdentifier.swift` so the bridge
/// can rehydrate/persist state in the shared App Group container.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {

    /// One bridge per handler process. Safari keeps the handler alive across
    /// messages, so registered handlers / timers / persistence survive between
    /// requests. It is rebuilt lazily if Safari tears the process down.
    private static var sharedBridge: SafariCustomRuleBridge?

    private static func bridge() throws -> SafariCustomRuleBridge {
        if let existing = sharedBridge { return existing }
        let created = try SafariCustomRuleBridge()
        sharedBridge = created
        return created
    }

    func beginRequest(with context: NSExtensionContext) {
        AppGroup.identifier = AppGroupIdentifier.value

        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: handle(message: incomingMessage(from: context))]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }

    // MARK: - Message handling

    private func incomingMessage(from context: NSExtensionContext) -> [String: Any] {
        guard let item = context.inputItems.first as? NSExtensionItem,
              let message = item.userInfo?[SFExtensionMessageKey] as? [String: Any]
        else {
            return [:]
        }
        return message
    }

    private func handle(message: [String: Any]) -> [String: Any] {
        guard let type = message["type"] as? String else {
            return ["ok": false, "error": "missing message type"]
        }

        switch type {
        case "event-sandbox-request":
            return handleSandboxRequest(payload: message["payload"])
        case "ping":
            return ["ok": true, "result": ["pong": true]]
        default:
            return ["ok": false, "error": "unsupported message type: \(type)"]
        }
    }

    private func handleSandboxRequest(payload: Any?) -> [String: Any] {
        guard let payload,
              JSONSerialization.isValidJSONObject(payload),
              let payloadData = try? JSONSerialization.data(withJSONObject: payload),
              let payloadJSON = String(data: payloadData, encoding: .utf8)
        else {
            return ["ok": false, "error": "invalid payload"]
        }

        do {
            let bridge = try Self.bridge()
            let resultJSON = try bridge.handle(payloadJSON: payloadJSON)
            let result = (try? JSONSerialization.jsonObject(
                with: Data(resultJSON.utf8)
            )) ?? NSNull()
            return ["ok": true, "result": result]
        } catch {
            // Reset the bridge so the next request starts from a clean engine.
            Self.sharedBridge = nil
            return ["ok": false, "error": "\(error)"]
        }
    }
}
