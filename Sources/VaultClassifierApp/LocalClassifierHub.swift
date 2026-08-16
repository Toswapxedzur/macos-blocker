import Foundation
import Network
import VaultClassifierCore

/// Minimal local hub used only while Vault Classifier owns the fixed loopback
/// address. Mac Vault takes over the listener when it opens, because it is the
/// authoritative host for the richer group-sync protocol.
final class LocalClassifierHub {
    static let shared = LocalClassifierHub()
    static var address: String { VaultRuntimeEnvironment.current.hubAddress }
    static let protocolVersion = LocalHubAuthentication.protocolVersion
    static let classifierRelayTimeoutSeconds = 30

    private struct Peer {
        let id = UUID().uuidString
        var program = ""
        var ready = false
        let challenge: String
        let connection: NWConnection
    }

    private struct PendingRequest {
        let browserID: String
        let classifierID: String
        let operation: String
    }

    private let queue = DispatchQueue(label: "VaultClassifier.LocalClassifierHub")
    private let lock = NSLock()
    private var listener: NWListener?
    private var peers: [ObjectIdentifier: Peer] = [:]
    private var pending: [String: PendingRequest] = [:]

    private(set) var isHosting = false

    private init() {}

    func startIfNeeded() {
        lock.lock()
        let alreadyListening = listener != nil
        lock.unlock()
        guard !alreadyListening else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.defaultProtocolStack.applicationProtocols.insert(NWProtocolWebSocket.Options(), at: 0)
            guard let port = NWEndpoint.Port(rawValue: VaultRuntimeEnvironment.current.hubPort) else {
                return
            }
            let listener = try NWListener(using: parameters, on: port)
            lock.lock()
            self.listener = listener
            lock.unlock()
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, self.isCurrent(listener) else { return }
                switch state {
                case .ready:
                    self.isHosting = true
                case .failed:
                    self.stopListenerOnly()
                default:
                    break
                }
            }
            listener.start(queue: queue)
        } catch {}
    }

    func stop() {
        stopListenerOnly()
        lock.lock()
        let connections = peers.values.map(\.connection)
        peers.removeAll()
        pending.removeAll()
        lock.unlock()
        for connection in connections { connection.cancel() }
    }

    func peerSnapshot() -> [[String: Any]] {
        lock.lock()
        let snapshot = peers.values.filter(\.ready).map {
            ["id": $0.id, "program": $0.program, "connected": true] as [String: Any]
        }
        lock.unlock()
        return snapshot
    }

    private func isCurrent(_ candidate: NWListener?) -> Bool {
        lock.lock()
        let result = listener === candidate
        lock.unlock()
        return result
    }

    private func stopListenerOnly() {
        lock.lock()
        let listener = self.listener
        self.listener = nil
        lock.unlock()
        listener?.cancel()
        isHosting = false
    }

    private func accept(_ connection: NWConnection) {
        // NWListener cannot bind a specific local host. Reject the connection
        // before allocating peer state unless the TCP peer is this Mac.
        guard Self.isLoopback(connection) else {
            connection.cancel()
            return
        }
        let key = ObjectIdentifier(connection)
        guard let challenge = try? LocalHubAuthentication.makeChallenge() else {
            connection.cancel()
            return
        }
        lock.lock()
        peers[key] = Peer(challenge: challenge, connection: connection)
        lock.unlock()
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.removePeer(key) }
            if case .cancelled = state { self?.removePeer(key) }
        }
        connection.start(queue: queue)
        send(connection, ["kind": "challenge", "v": Self.protocolVersion, "challenge": challenge])
        receive(connection, key: key)
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let waiting = self.peers[key]?.ready == false
            self.lock.unlock()
            if waiting { connection.cancel() }
        }
    }

    private static func isLoopback(_ connection: NWConnection) -> Bool {
        guard case let .hostPort(host, _) = connection.endpoint else { return false }
        switch host.debugDescription.lowercased() {
        case "127.0.0.1", "::1", "[::1]":
            return true
        default:
            return false
        }
    }

    private func receive(_ connection: NWConnection, key: ObjectIdentifier) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            if Self.isWebSocketClose(context) {
                self.removePeer(key)
                connection.cancel()
                return
            }
            if let data, !data.isEmpty, data.count <= 1_048_576 {
                self.handle(data, from: connection, key: key)
            } else if data?.count ?? 0 > 1_048_576 {
                connection.cancel()
            }
            if error == nil {
                self.receive(connection, key: key)
            } else {
                self.removePeer(key)
                connection.cancel()
            }
        }
    }

    private func handle(_ data: Data, from connection: NWConnection, key: ObjectIdentifier) {
        guard let frame = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = frame["kind"] as? String else {
            connection.cancel()
            return
        }
        lock.lock()
        let authenticated = peers[key]?.ready == true
        lock.unlock()
        guard kind == "hello" || authenticated else {
            reject(connection, reason: "authentication-required")
            return
        }
        switch kind {
        case "hello": handleHello(frame, connection: connection, key: key)
        case "classifier-request": routeRequest(frame, from: key)
        case "classifier-response": routeResponse(frame, from: key)
        case "classifier-broadcast": routeBroadcast(frame, from: key)
        case "ping": send(connection, ["kind": "pong", "t": frame["t"] ?? 0])
        default: break
        }
    }

    private func handleHello(_ frame: [String: Any], connection: NWConnection, key: ObjectIdentifier) {
        guard (frame["v"] as? NSNumber)?.intValue == Self.protocolVersion,
              let program = frame["program"] as? String,
              LocalHubAuthentication.isBrowserProgram(program) || LocalHubAuthentication.isDesktopProgram(program),
              let submittedChallenge = frame["challenge"] as? String,
              let proof = frame["proof"] as? String else {
            reject(connection, reason: "protocol-mismatch")
            return
        }
        lock.lock()
        let challenge = peers[key]?.challenge
        lock.unlock()
        guard let challenge, submittedChallenge == challenge,
              LocalHubAuthentication.verifyProof(program: program, challenge: challenge, proof: proof) else {
            reject(connection, reason: "authentication-failed")
            return
        }
        // Mac Vault owns the complete cluster registry. Let it bind this fixed
        // port whenever it appears, then reconnect the classifier to that hub.
        if program == "macapp" {
            reject(connection, reason: "hub-yield-to-macapp")
            queue.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in self?.stop() }
            return
        }
        lock.lock()
        guard var peer = peers[key], !peer.ready else { lock.unlock(); reject(connection, reason: "already-authenticated"); return }
        peer.program = program
        peer.ready = true
        peers[key] = peer
        lock.unlock()
        send(connection, ["kind": "welcome", "v": Self.protocolVersion, "hubProgram": "classifier", "peers": peerSnapshot()])
        broadcastPeers()
    }

    private func routeRequest(_ frame: [String: Any], from key: ObjectIdentifier) {
        guard let requestID = frame["requestID"] as? String,
              requestID.count > 0, requestID.count <= 128,
              let operation = frame["operation"] as? String,
              ["bridge-info", "collection-info", "diagnostic", "collect", "video-tags", "video-tags-batch", "dev-log"].contains(operation),
              let body = frame["body"] as? [String: Any], JSONSerialization.isValidJSONObject(body) else { return }
        lock.lock()
        guard let source = peers[key], LocalHubAuthentication.isBrowserProgram(source.program),
              pending[requestID] == nil,
              pending.count < 32,
              let classifier = peers.values.first(where: { $0.ready && $0.program == "classifier" }) else {
            let source = peers[key]?.connection
            lock.unlock()
            if let source { send(source, ["kind": "classifier-response", "requestID": requestID, "operation": operation, "error": "classifier-unavailable"]) }
            return
        }
        pending[requestID] = .init(browserID: source.id, classifierID: classifier.id, operation: operation)
        lock.unlock()
        send(classifier.connection, ["kind": "classifier-request", "sourcePeerID": source.id, "requestID": requestID, "operation": operation, "body": body])
        queue.asyncAfter(deadline: .now() + .seconds(Self.classifierRelayTimeoutSeconds)) { [weak self] in
            self?.expire(requestID)
        }
    }

    /// Relays an unsolicited classifier push (a completed classification) to
    /// every connected browser peer. Fire-and-forget: no correlation state, and
    /// an invalid frame is dropped rather than disconnecting the classifier.
    private func routeBroadcast(_ frame: [String: Any], from key: ObjectIdentifier) {
        guard let operation = frame["operation"] as? String,
              ["video-tags-updated"].contains(operation),
              let body = frame["body"] as? [String: Any],
              JSONSerialization.isValidJSONObject(body) else { return }
        lock.lock()
        guard let source = peers[key], source.ready, source.program == "classifier" else {
            lock.unlock()
            return
        }
        let browsers = peers.values
            .filter { $0.ready && LocalHubAuthentication.isBrowserProgram($0.program) }
            .map(\.connection)
        lock.unlock()
        for connection in browsers {
            send(connection, ["kind": "classifier-broadcast", "operation": operation, "body": body])
        }
    }

    private func routeResponse(_ frame: [String: Any], from key: ObjectIdentifier) {
        guard let sourcePeerID = frame["sourcePeerID"] as? String,
              let requestID = frame["requestID"] as? String,
              let operation = frame["operation"] as? String else { return }
        lock.lock()
        guard let classifier = peers[key], classifier.program == "classifier",
              let pending = self.pending[requestID],
              pending.classifierID == classifier.id,
              pending.browserID == sourcePeerID,
              pending.operation == operation,
              let browser = peers.values.first(where: { $0.ready && $0.id == sourcePeerID }) else {
            lock.unlock()
            return
        }
        self.pending.removeValue(forKey: requestID)
        lock.unlock()
        var response: [String: Any] = ["kind": "classifier-response", "requestID": requestID, "operation": operation]
        if let body = frame["body"] { response["body"] = body }
        if let error = frame["error"] { response["error"] = error }
        send(browser.connection, response)
    }

    private func expire(_ requestID: String) {
        lock.lock()
        guard let request = pending.removeValue(forKey: requestID),
              let browser = peers.values.first(where: { $0.ready && $0.id == request.browserID }) else { lock.unlock(); return }
        lock.unlock()
        send(browser.connection, ["kind": "classifier-response", "requestID": requestID, "operation": request.operation, "error": "classifier-timeout"])
    }

    private func removePeer(_ key: ObjectIdentifier) {
        lock.lock()
        let removed = peers.removeValue(forKey: key)
        let id = removed?.id
        let failures = pending.filter {
            $0.value.browserID == id || $0.value.classifierID == id
        }
        for requestID in failures.keys { pending.removeValue(forKey: requestID) }
        let targets = failures.compactMap { requestID, request -> (NWConnection, String, String)? in
            guard request.classifierID == id,
                  let browser = peers.values.first(where: { $0.ready && $0.id == request.browserID }) else {
                return nil
            }
            return (browser.connection, requestID, request.operation)
        }
        lock.unlock()
        for (connection, requestID, operation) in targets {
            send(connection, ["kind": "classifier-response", "requestID": requestID, "operation": operation, "error": "classifier-unavailable"])
        }
        if removed != nil { broadcastPeers() }
    }

    private func broadcastPeers() {
        lock.lock()
        let connections = peers.values.filter(\.ready).map(\.connection)
        lock.unlock()
        let payload: [String: Any] = ["kind": "peers", "peers": peerSnapshot()]
        for connection in connections { send(connection, payload) }
    }

    private func reject(_ connection: NWConnection, reason: String) {
        send(connection, ["kind": "rejected", "reason": reason])
        queue.asyncAfter(deadline: .now() + .milliseconds(100)) { connection.cancel() }
    }

    private static func isWebSocketClose(_ context: NWConnection.ContentContext?) -> Bool {
        let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
            as? NWProtocolWebSocket.Metadata
        return metadata?.opcode == .close
    }

    private func send(_ connection: NWConnection, _ frame: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: frame) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        connection.send(content: data, contentContext: NWConnection.ContentContext(identifier: "text", metadata: [metadata]), isComplete: true, completion: .contentProcessed { _ in })
    }
}
