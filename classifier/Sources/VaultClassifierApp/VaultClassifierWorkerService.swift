import Foundation
import VaultClassifierCore
import VaultClassifierBridge

/// Headless host of the production Classifier view-model. Windows and Mac UI
/// share one action dispatcher, state reconciliation, research executor,
/// download manager, local-engine registry and tagging/correction service.
@MainActor
public final class VaultClassifierWorkerService {
    private let model: VaultClassifierViewModel
    private let emit: ([String: Any]) -> Void
    private var activity: VaultClassifierWorkerActivity?

    public init(testingDirectory: URL? = nil, emit: @escaping ([String: Any]) -> Void) throws {
        self.emit = emit
        #if os(Windows)
        SharedHubClient.onHostBroadcast = { operation, body in
            emit(["event": "broadcast", "operation": operation, "body": body])
        }
        #endif
        if let testingDirectory {
            try VaultPrivateFile.createDirectory(at: testingDirectory)
            self.model = try VaultClassifierViewModel(headlessVaultDirectory: testingDirectory)
        } else {
            self.model = VaultClassifierViewModel()
        }
        let directory: URL
        if let testingDirectory { directory = testingDirectory.appendingPathComponent("Activity", isDirectory: true) }
        else { directory = try VaultRuntimeEnvironment.current.classifierSupportDirectoryURL().deletingLastPathComponent().appendingPathComponent("Activity", isDirectory: true) }
        try VaultPrivateFile.createDirectory(at: directory)
        self.activity = VaultClassifierWorkerActivity(directory: directory, model: model, emit: emit)
        model.onWebStateChange = { [weak self] in self?.publishState(); self?.activity?.refresh() }
    }

    public func publishState() { emit(["event": "state", "value": remapResources(model.webSnapshot())]) }

    public func handle(operation: String, data: [String: Any]) throws -> Any {
        switch operation {
        case "snapshot":
            return remapResources(model.webSnapshot())
        case "action":
            guard let action = data["action"] as? String, action.count <= 128,
                  let descriptor = ClassifierWebActionCatalog.descriptor(named: action) else {
                throw WorkerInputError.invalidAction
            }
            _ = descriptor
            guard (data["data"] as? [String: Any] ?? [:]).count <= VaultClassifierPresentation.maximumWebActionDataFields else { throw WorkerInputError.invalidAction }
            let rerender = model.performWebAction(action, data: data["data"] as? [String: Any] ?? [:])
            let snapshot = remapResources(model.webSnapshot())
            if rerender { emit(["event": "state", "value": snapshot]) }
            return ["rerender": rerender, "issue": model.issue ?? NSNull(), "snapshot": snapshot] as [String: Any]
        case "hub":
            guard let sourcePeerID = data["sourcePeerID"] as? String,
                  let requestID = data["requestID"] as? String,
                  let name = data["operation"] as? String,
                  let operation = SharedBrowserBridgeOperation(rawValue: name),
                  SharedBrowserBridgeProtocol.isValidPeerID(sourcePeerID),
                  SharedBrowserBridgeProtocol.isValidRequestID(requestID),
                  let body = data["body"], let bodyData = SharedBrowserBridgeProtocol.bodyData(from: body) else {
                throw WorkerInputError.invalidHubRequest
            }
            let reply = model.handleSharedHubRequest(.init(sourcePeerID: sourcePeerID, requestID: requestID, operation: operation, bodyData: bodyData))
            if let body = reply.body { return ["body": body] }
            return ["error": SharedBrowserBridgeProtocol.safeError(reply.error)]
        case "mcp":
            switch data["kind"] as? String {
            case "actions":
                return ["actions": ClassifierWebActionCatalog.actions.map { ["name": $0.name, "keys": $0.keys, "summary": $0.summary] as [String: Any] }]
            case "action":
                guard let action = data["action"] as? String, ClassifierWebActionCatalog.descriptor(named: action) != nil else { throw WorkerInputError.invalidAction }
                guard (data["data"] as? [String: Any] ?? [:]).count <= VaultClassifierPresentation.maximumWebActionDataFields else { throw WorkerInputError.invalidAction }
                let outcome = model.mcpPerform(action: action, data: data["data"] as? [String: Any] ?? [:])
                if outcome.rerender { publishState() }
                return ["rerender": outcome.rerender, "issue": outcome.issue ?? NSNull()] as [String: Any]
            default:
                guard let snapshot = model.mcpSnapshot(section: data["section"] as? String) else { throw WorkerInputError.invalidSection }
                return snapshot
            }
        case "tagNames":
            let platform = data["platform"] as? String ?? ""
            var seen = Set<String>()
            return model.taxonomy(platformID: platform).flatMap(\.tags).map(\.name).filter { seen.insert($0.lowercased()).inserted }
        case "resource":
            guard let name = data["url"] as? String, name.count <= 512, let url = URL(string: name),
                  url.scheme == SourceIconCache.scheme else { throw WorkerInputError.invalidResource }
            if let image = model.creatorPictures?.response(for: url) {
                return ["contentType": "image/jpeg", "dataBase64": image.base64EncodedString()]
            }
            if let image = model.sourceIconCache?.response(for: url) {
                return ["contentType": image.contentType, "dataBase64": image.data.base64EncodedString()]
            }
            throw WorkerInputError.missingResource
        case "activity":
            return try activity?.handle(data) ?? [:]
        case "hostEvent":
            // Host events cannot bypass the page/MCP action validation.
            if data["kind"] as? String == "flush" {
                _ = try activity?.handle(["kind": "native-flush"])
                LocalStateFile.flushAllPendingWrites()
            }
            return ["ok": true]
        default:
            throw WorkerInputError.invalidOperation
        }
    }
    private func remapResources(_ value: Any) -> Any {
        #if os(Windows)
        if let string = value as? String, string.hasPrefix("vaultclassifiersourceicon://") {
            var components = URLComponents(string: "https://appassets.windowsblocker/worker-resource")!
            components.queryItems = [URLQueryItem(name: "url", value: string)]
            return components.url?.absoluteString ?? string
        }
        if let array = value as? [Any] { return array.map(remapResources) }
        if let object = value as? [String: Any] { return object.mapValues(remapResources) }
        #endif
        return value
    }

}

private enum WorkerInputError: String, Error, LocalizedError {
    case invalidAction = "invalid-classifier-action"
    case invalidHubRequest = "invalid-classifier-request"
    case invalidSection = "invalid-classifier-section"
    case invalidOperation = "invalid-worker-operation"
    case invalidResource = "invalid-classifier-resource"
    case missingResource = "classifier-resource-not-found"
    var errorDescription: String? { rawValue }
}
