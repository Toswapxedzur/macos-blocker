import Foundation
import Network
import VaultClassifierCore

/// A local fallback host for the shared Vault bridge. Mac Vault and Vault
/// Classifier deliberately bind the same loopback address and protocol; only
/// one can host it at a time. When the Classifier is the host, it serves its
/// own bounded browser requests directly rather than opening another relay.
@MainActor
final class SharedHubServer {
    enum State: String {
        case off
        case starting
        case running
        case error
    }

    private final class Peer {
        let id = UUID().uuidString
        let connection: NWConnection
        var program = ""
        var authenticated = false

        init(connection: NWConnection) {
            self.connection = connection
        }
    }

    private static let maximumMessageBytes = 1_048_576
    private static let browserPrograms: Set<String> = [
        "chrome", "edge", "firefox", "safari", "opera", "browser",
    ]

    var onRequest: ((SharedHubClient.Request) -> SharedHubClient.Reply)?
    var onStateChange: (() -> Void)?

    private(set) var state: State = .off { didSet { onStateChange?() } }
    private(set) var error = "" { didSet { onStateChange?() } }
    private var listener: NWListener?
    private var peers: [ObjectIdentifier: Peer] = [:]
    private let queue = DispatchQueue(label: "vault-classifier.SharedHubServer")

    var isHosting: Bool { state == .running || state == .starting }

    func start(pairingKey: String) {
        guard let key = SharedHubPairingKeyStore.normalized(pairingKey) else {
            transition(to: .error, error: "pairing-key-required")
            return
        }
        guard listener == nil else { return }

        let parameters = NWParameters.tcp
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        parameters.allowLocalEndpointReuse = true
        parameters.requiredInterfaceType = .loopback

        guard let port = NWEndpoint.Port(rawValue: 8787) else {
            transition(to: .error, error: "invalid-port")
            return
        }
        do {
            let listener = try NWListener(using: parameters, on: port)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection, pairingKey: key) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in self?.handleListenerState(state) }
            }
            self.listener = listener
            transition(to: .starting, error: "")
            listener.start(queue: queue)
        } catch {
            transition(to: .error, error: error.localizedDescription)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        let connections = peers.values.map(\.connection)
        peers.removeAll()
        connections.forEach { $0.cancel() }
        transition(to: .off, error: "")
    }

    private func handleListenerState(_ listenerState: NWListener.State) {
        switch listenerState {
        case .ready:
            transition(to: .running, error: "")
        case .failed(let failure):
            listener = nil
            transition(to: .error, error: failure.localizedDescription)
        case .cancelled:
            if state != .off { transition(to: .off, error: "") }
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection, pairingKey: String) {
        let key = ObjectIdentifier(connection)
        peers[key] = Peer(connection: connection)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let connection else { return }
            if case .failed = state {
                Task { @MainActor in self?.removePeer(key, connection: connection) }
            } else if case .cancelled = state {
                Task { @MainActor in self?.removePeer(key, connection: connection) }
            }
        }
        connection.start(queue: queue)
        receive(connection, key: key, pairingKey: pairingKey)
        Task { @MainActor [weak self, weak connection] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self, let connection,
                  let peer = self.peers[key],
                  !peer.authenticated else { return }
            self.rejectAndClose(connection, reason: "authentication-timeout")
        }
    }

    private func receive(_ connection: NWConnection, key: ObjectIdentifier, pairingKey: String) {
        connection.receiveMessage { [weak self, weak connection] data, _, _, receiveError in
            guard let connection else { return }
            Task { @MainActor in
                guard let self else { return }
                if let data, !data.isEmpty {
                    if data.count > Self.maximumMessageBytes {
                        connection.cancel()
                    } else {
                        self.handle(data, from: connection, key: key, pairingKey: pairingKey)
                    }
                }
                if receiveError == nil {
                    self.receive(connection, key: key, pairingKey: pairingKey)
                } else {
                    self.removePeer(key, connection: connection)
                }
            }
        }
    }

    private func handle(_ data: Data, from connection: NWConnection, key: ObjectIdentifier, pairingKey: String) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = object["kind"] as? String,
              let peer = peers[key] else {
            rejectAndClose(connection, reason: "invalid-message")
            return
        }
        guard !peer.authenticated else {
            handleAuthenticated(kind: kind, object: object, peer: peer)
            return
        }
        guard kind == "hello" else {
            rejectAndClose(connection, reason: "authentication-required")
            return
        }
        guard helloRejectionReason(object, pairingKey: pairingKey) == nil,
              let program = object["program"] as? String else {
            rejectAndClose(connection, reason: "pairing-key-rejected")
            return
        }
        peer.program = program
        peer.authenticated = true
        send(connection, object: [
            "kind": "welcome",
            "v": 2,
            "hubProgram": "classifier",
            "peers": peers.values.filter(\.authenticated).map {
                ["id": $0.id, "program": $0.program, "connected": true]
            },
        ])
    }

    private func handleAuthenticated(kind: String, object: [String: Any], peer: Peer) {
        switch kind {
        case "classifier-request":
            routeClassifierRequest(object, from: peer)
        case "ping":
            send(peer.connection, object: ["kind": "pong", "t": object["t"] as? Double ?? 0])
        default:
            break
        }
    }

    private func routeClassifierRequest(_ object: [String: Any], from peer: Peer) {
        guard Self.browserPrograms.contains(peer.program),
              let requestID = object["requestID"] as? String,
              let rawOperation = object["operation"] as? String,
              let operation = SharedBrowserBridgeOperation(rawValue: rawOperation),
              let body = object["body"] as? [String: Any],
              SharedBrowserBridgeProtocol.isValidRequestID(requestID),
              SharedBrowserBridgeProtocol.isValidBody(body),
              let bodyData = SharedBrowserBridgeProtocol.bodyData(from: body) else {
            rejectAndClose(peer.connection, reason: "invalid-classifier-request")
            return
        }
        let reply = onRequest?(SharedHubClient.Request(
            sourcePeerID: peer.id,
            requestID: requestID,
            operation: operation,
            bodyData: bodyData
        )) ?? .failure("classifier-unavailable")
        var response: [String: Any] = [
            "kind": "classifier-response",
            "requestID": requestID,
            "operation": rawOperation,
        ]
        if let body = reply.body, SharedBrowserBridgeProtocol.isValidBody(body) {
            response["body"] = body
        } else {
            response["error"] = String(reply.error ?? "classifier-response-invalid").prefix(256)
        }
        send(peer.connection, object: response)
    }

    private func helloRejectionReason(_ object: [String: Any], pairingKey: String) -> String? {
        guard (object["v"] as? NSNumber)?.intValue == 2,
              let program = object["program"] as? String,
              Self.browserPrograms.contains(program),
              let suppliedKey = object["pairingKey"] as? String,
              secureEquals(
                suppliedKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                pairingKey
              ) else {
            return "pairing-key-rejected"
        }
        return nil
    }

    private func secureEquals(_ left: String, _ right: String) -> Bool {
        guard left.utf8.count == right.utf8.count else { return false }
        return zip(left.utf8, right.utf8).reduce(0) { $0 | Int($1.0 ^ $1.1) } == 0
    }

    private func send(_ connection: NWConnection, object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }

    private func rejectAndClose(_ connection: NWConnection, reason: String) {
        send(connection, object: ["kind": "rejected", "reason": reason])
        Task { @MainActor [weak connection] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            connection?.cancel()
        }
    }

    private func removePeer(_ key: ObjectIdentifier, connection: NWConnection) {
        guard peers.removeValue(forKey: key) != nil else { return }
        connection.cancel()
    }

    private func transition(to newState: State, error newError: String) {
        state = newState
        error = newError
    }
}
