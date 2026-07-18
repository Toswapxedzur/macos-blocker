import Foundation
import VaultClassifierCore

/// The classifier is a client of Mac Vault's existing loopback hub. It never
/// binds a second localhost port and it never sends the shared pairing key
/// beyond the authenticated hello frame.
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
    private var pairingKey = ""

    struct Reply {
        var body: Any?
        var error: String?

        static func success(_ body: Any) -> Reply { .init(body: body, error: nil) }
        static func failure(_ error: String) -> Reply { .init(body: nil, error: error) }
    }

    var hasStoredPairingKey: Bool { SharedHubPairingKeyStore.load() != nil }

    func connectUsingStoredKey() {
        guard let key = SharedHubPairingKeyStore.load() else {
            transition(to: .off, error: "")
            return
        }
        connect(pairingKey: key)
    }

    func connect(pairingKey: String) {
        guard let normalized = SharedHubPairingKeyStore.normalized(pairingKey) else {
            desired = false
            closeSocket()
            transition(to: .error, error: "pairing-key-required")
            return
        }
        self.pairingKey = normalized
        desired = true
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
        send(
            [
                "kind": "hello",
                "v": 2,
                "program": "classifier",
                "pairingKey": normalized,
            ],
            on: task
        ) { [weak self, weak task] error in
            guard let self, let task, self.task === task, let error else { return }
            self.connectionFailed(error.localizedDescription, retry: true)
        }
        receive(on: task)
        handshakeTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self, weak task] _ in
            Task { @MainActor in
                guard let self, let task, self.task === task, self.state != .connected else { return }
                self.connectionFailed("handshake-timeout", retry: true)
            }
        }
    }

    func disconnect() {
        desired = false
        pairingKey = ""
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        handshakeTimer?.invalidate()
        handshakeTimer = nil
        closeSocket()
        transition(to: .off, error: "")
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
        case "welcome":
            guard (object["v"] as? NSNumber)?.intValue == 2,
                  object["hubProgram"] as? String == "macapp" else {
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
            payload["error"] = String(reply.error ?? "classifier-response-invalid").prefix(256)
        }
        send(payload, on: task, completion: nil)
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
        handshakeTimer?.invalidate()
        handshakeTimer = nil
        closeSocket()
        let canRetry = retry && desired
        transition(to: canRetry ? .disconnected : .error, error: reason)
        guard canRetry else { return }
        reconnectTimer?.invalidate()
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.desired else { return }
                self.connect(pairingKey: self.pairingKey)
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
