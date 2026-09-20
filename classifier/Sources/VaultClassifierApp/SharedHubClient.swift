import Foundation
import VaultClassifierCore
import VaultClassifierBridge

/// The classifier joins the fixed local Vault hub and becomes its lightweight
/// classifier host when Mac Vault is not open.
@MainActor
final class SharedHubClient {
    enum State: String {
        case off
        case connecting
        case connected
        case disconnected
        case error
    }

    struct Request {
        let sourcePeerID: String
        let requestID: String
        let operation: SharedBrowserBridgeOperation
        let bodyData: Data
    }

    var onRequest: ((Request) -> Reply)?
    var onStateChange: (() -> Void)?

    private(set) var state: State = .off { didSet { onStateChange?() } }
    private(set) var error = "" { didSet { onStateChange?() } }
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var reconnectTimer: Timer?
    private var handshakeTimer: Timer?
    private var desired = false

    struct Reply {
        var body: Any?
        var error: String?

        static func success(_ body: Any) -> Reply { .init(body: body, error: nil) }
        static func failure(_ error: String) -> Reply { .init(body: nil, error: error) }
    }

    func connect() {
        desired = true
        attemptJoin()
    }

    /// Joins the local hub as a client. The classifier never hosts: it runs only
    /// as a component of Mac Vault, whose ConnectionHub is the sole host (it owns
    /// activity + MCP + group-sync). The socket below joins only after the hub's
    /// welcome identifies Mac Vault (or another classifier) as the local hub.
    private func attemptJoin() {
        guard desired else { return }
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        handshakeTimer?.invalidate()
        handshakeTimer = nil
        closeSocket()
        transition(to: .connecting, error: "")

        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: URL(string: SharedBrowserBridgeProtocol.address)!)
        self.session = session
        self.task = task
        task.resume()
        receive(on: task)
        handshakeTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self, weak task] _ in
            Task { @MainActor in
                guard let self, let task, self.task === task, self.state != .connected else { return }
                self.connectionFailed("handshake-timeout", retry: true)
            }
        }
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self, weak task] result in
            Task { @MainActor in
                guard let self, let task, self.task === task else { return }
                switch result {
                case .success(let message):
                    switch message {
                    case .string(let text): self.handle(text)
                    case .data(let data): self.handle(data)
                    @unknown default: break
                    }
                    if self.task === task { self.receive(on: task) }
                case .failure(let error):
                    self.connectionFailed(error.localizedDescription, retry: self.desired)
                }
            }
        }
    }

    private func handle(_ text: String) {
        handle(Data(text.utf8))
    }

    private func handle(_ data: Data) {
        guard data.count <= 1_048_576,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = object["kind"] as? String else {
            connectionFailed("invalid-message", retry: true)
            return
        }
        switch kind {
        case "challenge":
            guard (object["v"] as? NSNumber)?.intValue == SharedBrowserBridgeProtocol.version,
                  let challenge = object["challenge"] as? String,
                  let proof = try? LocalHubAuthentication.makeProof(program: "classifier", challenge: challenge) else {
                connectionFailed("authentication-unavailable", retry: true)
                return
            }
            send(
                [
                    "kind": "hello",
                    "v": SharedBrowserBridgeProtocol.version,
                    "program": "classifier",
                    "challenge": challenge,
                    "proof": proof,
                ],
                on: task
            ) { [weak self, weak task] error in
                guard let self, let task, self.task === task, let error else { return }
                self.connectionFailed(error.localizedDescription, retry: true)
            }
        case "welcome":
            guard (object["v"] as? NSNumber)?.intValue == SharedBrowserBridgeProtocol.version,
                  let hubProgram = object["hubProgram"] as? String,
                  SharedBrowserBridgeProtocol.isAcceptedHubProgram(hubProgram) else {
                connectionFailed("protocol-mismatch", retry: false)
                return
            }
            handshakeTimer?.invalidate()
            handshakeTimer = nil
            transition(to: .connected, error: "")
        case "rejected":
            connectionFailed((object["reason"] as? String) ?? "rejected", retry: false)
        case "classifier-request":
            handleClassifierRequest(object)
        default:
            break
        }
    }

    private func handleClassifierRequest(_ object: [String: Any]) {
        guard state == .connected,
              let sourcePeerID = object["sourcePeerID"] as? String,
              let requestID = object["requestID"] as? String,
              let rawOperation = object["operation"] as? String,
              let operation = SharedBrowserBridgeOperation(rawValue: rawOperation),
              let body = object["body"],
              SharedBrowserBridgeProtocol.isValidPeerID(sourcePeerID),
              SharedBrowserBridgeProtocol.isValidRequestID(requestID),
              let bodyData = SharedBrowserBridgeProtocol.bodyData(from: body) else {
            connectionFailed("invalid-classifier-request", retry: true)
            return
        }
        let reply = onRequest?(Request(
            sourcePeerID: sourcePeerID,
            requestID: requestID,
            operation: operation,
            bodyData: bodyData
        )) ?? .failure("classifier-unavailable")
        var payload: [String: Any] = [
            "kind": "classifier-response",
            "sourcePeerID": sourcePeerID,
            "requestID": requestID,
            "operation": rawOperation,
        ]
        if let body = reply.body, SharedBrowserBridgeProtocol.isValidBody(body) {
            payload["body"] = body
        } else {
            payload["error"] = SharedBrowserBridgeProtocol.safeError(reply.error)
        }
        send(payload, on: task, completion: nil)
    }

    /// Unsolicited push to the hub, relayed to every connected browser peer.
    /// Fire-and-forget: broadcasts carry freshly resolved state (e.g. completed
    /// video classifications), so a drop only means the browser falls back to
    /// its next pull.
    func broadcast(operation: String, body: Any) {
        guard state == .connected, SharedBrowserBridgeProtocol.isValidBody(body) else { return }
        send(["kind": "classifier-broadcast", "operation": operation, "body": body], on: task, completion: nil)
    }

    private func send(_ object: [String: Any], on task: URLSessionWebSocketTask?, completion: ((Error?) -> Void)?) {
        guard let task,
              JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              data.count <= 1_048_576,
              let text = String(data: data, encoding: .utf8) else {
            completion?(SharedHubClientError.invalidFrame)
            return
        }
        task.send(.string(text)) { error in
            Task { @MainActor in completion?(error) }
        }
    }

    private func connectionFailed(_ reason: String, retry: Bool) {
        // A drop after we were connected reconnects fast (the host likely just
        // restarted); a failure to connect at all backs off longer.
        let wasConnected = state == .connected
        handshakeTimer?.invalidate()
        handshakeTimer = nil
        closeSocket()
        let canRetry = retry && desired
        transition(to: canRetry ? .disconnected : .error, error: reason)
        guard canRetry else { return }
        reconnectTimer?.invalidate()
        let delay = wasConnected ? 0.25 : 2.0
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.desired else { return }
                self.attemptJoin()
            }
        }
    }

    private func closeSocket() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    private func transition(to state: State, error: String) {
        self.state = state
        self.error = error
    }
}

private enum SharedHubClientError: Error {
    case invalidFrame
}
