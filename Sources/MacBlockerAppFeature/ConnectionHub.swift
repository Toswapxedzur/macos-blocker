#if os(macOS)
import Foundation
import MacBlockerCore
import Network

/// The fixed local Vault WebSocket hub.
///
/// The first open Vault app owns the loopback listener. Other Vault apps join
/// that hub as local peers; when the owner quits, a remaining app retries the
/// listener so the hub needs only one open app to stay available.
final class ConnectionHub: ObservableObject {
    static let protocolVersion = LocalHubAuthentication.protocolVersion
    static let localProgram = "macapp"
    private static let maxMessageBytes = 1_048_576
    private static let maxClassifierBodyBytes = 88_000
    private static let maxClassifierRequests = 32
    private static let remotePrograms = LocalHubAuthentication.browserPrograms.union(["classifier"])
    private static let browserPrograms = LocalHubAuthentication.browserPrograms

    private struct Peer {
        let id: String
        var program: String
        var connected: Bool
        let challenge: String
        let connection: NWConnection
    }

    /// A short-lived routed classifier call. The hub owns this correlation so a
    /// connected browser cannot select a response destination or impersonate a
    /// different peer on the shared localhost socket.
    private struct ClassifierRequest {
        let sourcePeerID: String
        let classifierPeerID: String
        let operation: String
    }

    /// Process-wide hub. Owned at the app-delegate level (not by any SwiftUI
    /// view) so the server survives closing the editor window and lives for the
    /// whole app session.
    static let shared = ConnectionHub()

    private let queue = DispatchQueue(label: "macosBlocker.ConnectionHub")
    private let lock = NSLock()

    private var listener: NWListener?
    private var peers: [ObjectIdentifier: Peer] = [:]
    private var classifierRequests: [String: ClassifierRequest] = [:]
    private var running = false
    private static var brokerAddress: String {
        VaultRuntimeEnvironment.current.hubAddress
    }
    private var lastError = ""
    private var brokerPeers: [[String: Any]] = []
    private var joinedHubProgram = ""
    private var brokerSession: URLSession?
    private var brokerTask: URLSessionWebSocketTask?
    private var reconnectWorkItem: DispatchWorkItem?
    private var pingTimer: DispatchSourceTimer?
    private var wantsBrokerConnection = false
    private var hostingLocalHub = false
    private var lastBridgeAnnouncement: [String: Any]?
    static func helloRejectionReason(_ obj: [String: Any], challenge: String, secret: Data?) -> String? {
        let version = (obj["v"] as? NSNumber)?.intValue
        guard version == protocolVersion else { return "protocol-mismatch" }
        guard let program = obj["program"] as? String, remotePrograms.contains(program) else {
            return "invalid-program"
        }
        guard let secret,
              obj["challenge"] as? String == challenge,
              let proof = obj["proof"] as? String,
              LocalHubAuthentication.verifyProof(program: program, challenge: challenge, proof: proof, secret: secret) else {
            return "authentication-failed"
        }
        return nil
    }

    static func classifierRequestRejectionReason(_ obj: [String: Any]) -> String? {
        guard let requestID = obj["requestID"] as? String,
              isVisibleBridgeIdentifier(requestID, maximumLength: 128),
              let operation = obj["operation"] as? String,
              ["bridge-info", "collection-info", "diagnostic", "collect", "source-tags", "classify", "correct"].contains(operation),
              let body = obj["body"] as? [String: Any],
              JSONSerialization.isValidJSONObject(body),
              let bodyData = try? JSONSerialization.data(withJSONObject: body),
              bodyData.count <= maxClassifierBodyBytes else {
            return "invalid-classifier-request"
        }
        return nil
    }

    private static func classifierResponseRejectionReason(_ obj: [String: Any]) -> String? {
        guard let sourcePeerID = obj["sourcePeerID"] as? String,
              isVisibleBridgeIdentifier(sourcePeerID, maximumLength: 128),
              let requestID = obj["requestID"] as? String,
              isVisibleBridgeIdentifier(requestID, maximumLength: 128),
              let operation = obj["operation"] as? String,
              ["bridge-info", "collection-info", "diagnostic", "collect", "source-tags", "classify", "correct"].contains(operation) else {
            return "invalid-classifier-response"
        }
        if let body = obj["body"] as? [String: Any],
           JSONSerialization.isValidJSONObject(body),
           let bodyData = try? JSONSerialization.data(withJSONObject: body),
           bodyData.count <= maxClassifierBodyBytes {
            return nil
        }
        if let error = obj["error"] as? String,
           error.count <= 256,
           error.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value <= 0x7e }) {
            return nil
        }
        return "invalid-classifier-response"
    }

    private static func isVisibleBridgeIdentifier(_ value: String, maximumLength: Int) -> Bool {
        !value.isEmpty && value.count <= maximumLength && value.unicodeScalars.allSatisfy {
            $0.value >= 0x21 && $0.value <= 0x7e
        }
    }

    // MARK: Cluster registry (per-group web-app bridge linking)

    private struct GroupInfo {
        let id: String
        let name: String
        let type: String
        let frozen: Bool
    }

    /// A live cluster: the bound programs plus the hub-authoritative shared
    /// settings derived from each member's contribution.
    private final class ClusterState {
        let id: String
        let groupName: String
        let groupType: String
        var members: Set<String> = []
        /// Live peer presence comes from the broker snapshot. It is deliberately
        /// not inferred from a local listener because Mac Vault is only a
        /// broker client now.
        var onlineMembers: Set<String> = []
        /// Per-program local group id: the specific group *instance* that program
        /// linked. Membership is pinned to this id so deleting a group and later
        /// re-creating one with the same name does NOT silently re-join the old
        /// cluster (the new group carries a fresh id). Empty for clusters formed
        /// before id pinning; those fall back to name+type matching and are
        /// backfilled from the roster on the next announce.
        var memberGroupIds: [String: String] = [:]
        /// Per-program contribution: { scalars: {...}, sites?: [...], apps?: [...] }.
        var contributions: [String: [String: Any]] = [:]
        // Hub-authoritative shared state.
        var sharedScalars: [String: Any] = [:]
        var sharedTs: Double = 0
        var sharedSites: [String] = []
        var sharedApps: [[String: Any]] = []
        /// Shared live usage budget. Members report *increments* (usageDeltaMs)
        /// from their own accrual, never absolutes, so folding this total back
        /// into each member's local counter can never double count. Before any
        /// delta arrives we seed it from the largest member absolute so joining a
        /// cluster with prior usage doesn't wipe it.
        var sharedUsageMs: Double = 0
        var sharedUsageResetAtMs: Double = 0
        var usageSeeded = false
        /// Active snooze runtime shared across members (newest start wins). The
        /// entry carries its own timing so each side enforces + expires it
        /// identically; `sharedSnoozeTs` is the originating start time.
        var sharedSnooze: [String: Any] = [:]
        var sharedSnoozeTs: Double = 0
        /// Shared cumulative snooze total (display only on each member). We keep
        /// the max reported across members so the figure reflects time accrued on
        /// any endpoint; members never merge it into their own accumulator, so a
        /// max is safe and monotonic.
        var sharedSnoozeTotalMs: Double = 0

        init(id: String, groupName: String, groupType: String) {
            self.id = id
            self.groupName = groupName
            self.groupType = groupType
        }
    }

    /// Each endpoint's eligible Default/Custom groups, keyed by program id.
    private var rosters: [String: [GroupInfo]] = [:]
    /// Active clusters keyed by cluster id.
    private var clusters: [String: ClusterState] = [:]
    /// A rejection reason for a Mac-initiated link, drained by the web layer.
    private var pendingLocalRejection: String?

    /// UserDefaults key for the persisted cluster registry. Bumping the suffix
    /// invalidates older on-disk shapes.
    private static let clustersDefaultsKey = "ConnectionHub.clusters.v1"

    // MARK: Lifecycle

    func start() {
        guard !wantsBrokerConnection else { return }
        wantsBrokerConnection = true
        lastError = ""
        startLocalHubOrJoinExisting()
    }

    func stop() {
        wantsBrokerConnection = false
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        pingTimer?.cancel()
        pingTimer = nil
        brokerTask?.cancel(with: .goingAway, reason: nil)
        brokerTask = nil
        brokerSession?.invalidateAndCancel()
        brokerSession = nil
        listener?.cancel()
        listener = nil
        lock.lock()
        let conns = peers.values.map { $0.connection }
        peers.removeAll()
        running = false
        hostingLocalHub = false
        joinedHubProgram = ""
        lock.unlock()
        for conn in conns { conn.cancel() }
    }

    private func startLocalHubOrJoinExisting() {
        guard wantsBrokerConnection, listener == nil else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.defaultProtocolStack.applicationProtocols.insert(NWProtocolWebSocket.Options(), at: 0)
            guard let port = NWEndpoint.Port(rawValue: VaultRuntimeEnvironment.current.hubPort) else {
                return
            }
            let listener = try NWListener(using: parameters, on: port)
            self.listener = listener
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, self.listener === listener else { return }
                switch state {
                case .ready:
                    self.lock.lock()
                    self.running = true
                    self.hostingLocalHub = true
                    self.lastError = ""
                    self.brokerPeers = []
                    self.joinedHubProgram = ""
                    self.lock.unlock()
                case .failed:
                    self.listener?.cancel()
                    self.listener = nil
                    self.lock.lock()
                    self.running = false
                    self.hostingLocalHub = false
                    self.lastError = "server-running-not-connected"
                    self.joinedHubProgram = ""
                    self.lock.unlock()
                    self.joinExistingLocalHub()
                default:
                    break
                }
            }
            listener.start(queue: queue)
        } catch {
            lock.lock()
            hostingLocalHub = false
            lastError = "server-running-not-connected"
            joinedHubProgram = ""
            lock.unlock()
            joinExistingLocalHub()
        }
    }

    /// The listener attempt always comes first. Reaching this method means a
    /// peer already owns the fixed local port, so the welcome below must prove
    /// it is a current Mac Vault or Vault Classifier hub before we join it.
    private func joinExistingLocalHub() {
        guard wantsBrokerConnection, let url = URL(string: Self.brokerAddress) else {
            setError("invalid-broker-address")
            return
        }
        brokerTask?.cancel(with: .goingAway, reason: nil)
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: url)
        brokerSession = session
        brokerTask = task
        task.resume()
        receiveBroker(on: task)
    }

    private func receiveBroker(on task: URLSessionWebSocketTask) {
        task.receive { [weak self, weak task] result in
            guard let self, let task, self.brokerTask === task else { return }
            switch result {
            case .success(let message):
                let data: Data
                switch message {
                case .string(let text): data = Data(text.utf8)
                case .data(let value): data = value
                @unknown default: return
                }
                self.handleBrokerFrame(data)
                if self.brokerTask === task { self.receiveBroker(on: task) }
            case .failure(let error):
                self.brokerDisconnected(error.localizedDescription)
            }
        }
    }

    private func handleBrokerFrame(_ data: Data) {
        guard data.count <= Self.maxMessageBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = object["kind"] as? String else {
            brokerDisconnected("invalid-message")
            return
        }
        switch kind {
        case "challenge":
            guard (object["v"] as? NSNumber)?.intValue == Self.protocolVersion,
                  let challenge = object["challenge"] as? String,
                  let proof = try? LocalHubAuthentication.makeProof(program: Self.localProgram, challenge: challenge) else {
                brokerDisconnected("authentication-unavailable")
                return
            }
            sendBroker([
                "kind": "hello",
                "v": Self.protocolVersion,
                "program": Self.localProgram,
                "challenge": challenge,
                "proof": proof,
            ])
        case "welcome":
            guard (object["v"] as? NSNumber)?.intValue == Self.protocolVersion,
                  let hubProgram = object["hubProgram"] as? String,
                  ["macapp", "classifier"].contains(hubProgram) else {
                brokerDisconnected("protocol-mismatch", retry: false)
                return
            }
            lock.lock()
            running = true
            lastError = ""
            brokerPeers = object["peers"] as? [[String: Any]] ?? []
            joinedHubProgram = hubProgram
            lock.unlock()
            if let clusters = object["clusters"] as? [[String: Any]] { replaceBrokerClusters(clusters) }
            if let announcement = lastBridgeAnnouncement { sendBroker(announcement) }
            startBrokerPings()
        case "peers":
            lock.lock()
            brokerPeers = object["peers"] as? [[String: Any]] ?? []
            lock.unlock()
        case "clusters":
            replaceBrokerClusters(object["clusters"] as? [[String: Any]] ?? [])
        case "cluster-updated":
            if let cluster = object["cluster"] as? [String: Any] { applyBrokerCluster(cluster) }
        case "connect-group-rejected":
            lock.lock()
            pendingLocalRejection = (object["reason"] as? String) ?? ""
            lock.unlock()
        case "rejected":
            let reason = (object["reason"] as? String) ?? "rejected"
            brokerDisconnected(reason, retry: reason == "hub-yield-to-macapp")
        default:
            break
        }
    }

    private func brokerDisconnected(_ reason: String, retry: Bool = true) {
        lock.lock()
        let wasJoinedHost = running && !hostingLocalHub
        running = false
        lastError = reason
        brokerPeers.removeAll()
        joinedHubProgram = ""
        lock.unlock()
        brokerTask?.cancel(with: .goingAway, reason: nil)
        brokerTask = nil
        pingTimer?.cancel()
        pingTimer = nil
        guard retry, wantsBrokerConnection else { return }
        reconnectWorkItem?.cancel()
        // If the server we had joined disappeared, run a new host election
        // instead of blindly reconnecting to its old socket. This method tries
        // to listen first and joins only if another verified app wins the port.
        let delay: DispatchTimeInterval = (wasJoinedHost || reason == "hub-yield-to-macapp") ? .milliseconds(250) : .seconds(2)
        let work = DispatchWorkItem { [weak self] in self?.startLocalHubOrJoinExisting() }
        reconnectWorkItem = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func sendBroker(_ frame: [String: Any], on task: URLSessionWebSocketTask? = nil) {
        guard JSONSerialization.isValidJSONObject(frame),
              let data = try? JSONSerialization.data(withJSONObject: frame),
              data.count <= Self.maxMessageBytes,
              let text = String(data: data, encoding: .utf8),
              let target = task ?? brokerTask else { return }
        target.send(.string(text)) { [weak self] error in
            if let error { self?.brokerDisconnected(error.localizedDescription) }
        }
    }

    private func startBrokerPings() {
        pingTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 20, repeating: 20)
        timer.setEventHandler { [weak self] in self?.sendBroker(["kind": "ping", "t": Date().timeIntervalSince1970 * 1_000]) }
        pingTimer = timer
        timer.resume()
    }

    // MARK: Connections

    private func accept(_ conn: NWConnection) {
        // NWListener cannot bind a specific local host. Reject the connection
        // before allocating peer state unless the TCP peer is this Mac.
        guard Self.isLoopback(conn) else {
            conn.cancel()
            return
        }
        guard let challenge = try? LocalHubAuthentication.makeChallenge() else {
            conn.cancel()
            return
        }
        let key = ObjectIdentifier(conn)
        lock.lock()
        peers[key] = Peer(id: UUID().uuidString, program: "", connected: false, challenge: challenge, connection: conn)
        lock.unlock()

        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.removePeer(key)
            default:
                break
            }
        }
        conn.start(queue: queue)
        send(conn, dict: ["kind": "challenge", "v": Self.protocolVersion, "challenge": challenge])
        receive(conn, key: key)
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let isPending = self.peers[key]?.connected == false
            self.lock.unlock()
            if isPending {
                self.rejectAndClose(conn, reason: "authentication-timeout")
            }
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

    private func receive(_ conn: NWConnection, key: ObjectIdentifier) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                if data.count > Self.maxMessageBytes {
                    conn.cancel()
                } else {
                    self.handleIncoming(conn, key: key, data: data)
                }
            }
            if error == nil {
                self.receive(conn, key: key)
            } else {
                self.removePeer(key)
            }
        }
    }

    private func handleIncoming(_ conn: NWConnection, key: ObjectIdentifier, data: Data) {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let kind = obj["kind"] as? String else {
            rejectAndClose(conn, reason: "invalid-message")
            return
        }
        lock.lock()
        let authenticated = peers[key]?.connected == true
        lock.unlock()
        if kind != "hello" && !authenticated {
            rejectAndClose(conn, reason: "authentication-required")
            return
        }
        if kind == "hello" && authenticated {
            rejectAndClose(conn, reason: "already-authenticated")
            return
        }
        switch kind {
        case "hello":
            lock.lock()
            let challenge = peers[key]?.challenge
            lock.unlock()
            guard let challenge else {
                rejectAndClose(conn, reason: "authentication-failed")
                return
            }
            let secret = try? LocalHubAuthentication.sharedSecret()
            if let reason = Self.helloRejectionReason(obj, challenge: challenge, secret: secret) {
                rejectAndClose(conn, reason: reason)
                return
            }
            let program = (obj["program"] as? String) ?? "browser"
            lock.lock()
            peers[key]?.program = program
            peers[key]?.connected = true
            lock.unlock()
            send(conn, dict: [
                "kind": "welcome",
                "v": Self.protocolVersion,
                "hubProgram": Self.localProgram,
                "peers": peerListJSON()
            ])
            broadcastPeers()
            sendClustersSnapshot(conn)
        case "groups-announce":
            lock.lock()
            let prog = peers[key]?.program ?? ((obj["program"] as? String) ?? "")
            lock.unlock()
            setRoster(program: prog, groups: (obj["groups"] as? [[String: Any]]) ?? [])
        case "connect-group":
            lock.lock()
            let fromProg = peers[key]?.program ?? ((obj["fromProgram"] as? String) ?? "")
            lock.unlock()
            connectGroup(
                from: fromProg,
                to: (obj["toProgram"] as? String) ?? "",
                groupName: (obj["groupName"] as? String) ?? "",
                groupType: (obj["groupType"] as? String) ?? ""
            )
        case "disconnect-group":
            lock.lock()
            let prog = peers[key]?.program ?? ((obj["program"] as? String) ?? "")
            lock.unlock()
            disconnectGroup(
                clusterId: (obj["clusterId"] as? String) ?? "",
                groupName: (obj["groupName"] as? String) ?? "",
                program: prog
            )
        case "group-sync":
            lock.lock()
            let prog = peers[key]?.program ?? ((obj["program"] as? String) ?? "")
            lock.unlock()
            applySync(
                program: prog,
                groupName: (obj["groupName"] as? String) ?? "",
                groupType: (obj["groupType"] as? String) ?? "",
                contribution: obj,
                ts: (obj["ts"] as? Double) ?? 0
            )
        case "classifier-request":
            lock.lock()
            let program = peers[key]?.program ?? ""
            lock.unlock()
            routeClassifierRequest(from: key, program: program, object: obj)
        case "classifier-response":
            lock.lock()
            let program = peers[key]?.program ?? ""
            lock.unlock()
            routeClassifierResponse(from: key, program: program, object: obj)
        case "ping":
            send(conn, dict: ["kind": "pong", "t": (obj["t"] as? Double) ?? 0])
        default:
            break
        }
    }

    private func rejectAndClose(_ conn: NWConnection, reason: String) {
        send(conn, dict: ["kind": "rejected", "reason": reason])
        queue.asyncAfter(deadline: .now() + .milliseconds(100)) { conn.cancel() }
    }

    private func send(_ conn: NWConnection, dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        conn.send(
            content: data,
            contentContext: context,
            isComplete: true,
            completion: .contentProcessed { _ in }
        )
    }

    // MARK: Shared classifier route

    private func routeClassifierRequest(from key: ObjectIdentifier, program: String, object: [String: Any]) {
        guard Self.browserPrograms.contains(program) else {
            lock.lock(); let source = peers[key]?.connection; lock.unlock()
            if let source { rejectAndClose(source, reason: "classifier-browser-required") }
            return
        }
        guard Self.classifierRequestRejectionReason(object) == nil,
              let requestID = object["requestID"] as? String,
              let operation = object["operation"] as? String,
              let body = object["body"] as? [String: Any] else {
            lock.lock(); let source = peers[key]?.connection; lock.unlock()
            if let source { rejectAndClose(source, reason: "invalid-classifier-request") }
            return
        }

        lock.lock()
        guard let source = peers[key], source.connected else { lock.unlock(); return }
        guard classifierRequests[requestID] == nil else {
            lock.unlock()
            send(source.connection, dict: ["kind": "classifier-response", "requestID": requestID, "operation": operation, "error": "duplicate-classifier-request"])
            return
        }
        guard classifierRequests.count < Self.maxClassifierRequests else {
            lock.unlock()
            send(source.connection, dict: ["kind": "classifier-response", "requestID": requestID, "operation": operation, "error": "classifier-busy"])
            return
        }
        let classifiers = peers.values.filter { $0.connected && $0.program == "classifier" }
        guard classifiers.count == 1, let classifier = classifiers.first else {
            lock.unlock()
            send(source.connection, dict: ["kind": "classifier-response", "requestID": requestID, "operation": operation, "error": "classifier-unavailable"])
            return
        }
        classifierRequests[requestID] = .init(
            sourcePeerID: source.id,
            classifierPeerID: classifier.id,
            operation: operation
        )
        lock.unlock()

        send(classifier.connection, dict: [
            "kind": "classifier-request",
            "sourcePeerID": source.id,
            "requestID": requestID,
            "operation": operation,
            "body": body,
        ])
        queue.asyncAfter(deadline: .now() + 6) { [weak self] in
            self?.expireClassifierRequest(requestID)
        }
    }

    private func routeClassifierResponse(from key: ObjectIdentifier, program: String, object: [String: Any]) {
        guard program == "classifier", Self.classifierResponseRejectionReason(object) == nil,
              let sourcePeerID = object["sourcePeerID"] as? String,
              let requestID = object["requestID"] as? String,
              let operation = object["operation"] as? String else {
            lock.lock(); let classifier = peers[key]?.connection; lock.unlock()
            if let classifier { rejectAndClose(classifier, reason: "invalid-classifier-response") }
            return
        }
        lock.lock()
        let classifier = peers[key]
        guard let classifier,
              let pending = classifierRequests[requestID],
              pending.classifierPeerID == classifier.id,
              pending.sourcePeerID == sourcePeerID,
              pending.operation == operation else {
            lock.unlock()
            if let classifier { rejectAndClose(classifier.connection, reason: "unmatched-classifier-response") }
            return
        }
        classifierRequests.removeValue(forKey: requestID)
        let source = peers.values.first { $0.connected && $0.id == pending.sourcePeerID }?.connection
        lock.unlock()
        guard let source else { return }
        var response: [String: Any] = [
            "kind": "classifier-response",
            "requestID": requestID,
            "operation": operation,
        ]
        if let body = object["body"] { response["body"] = body }
        if let error = object["error"] { response["error"] = error }
        send(source, dict: response)
    }

    private func expireClassifierRequest(_ requestID: String) {
        lock.lock()
        guard let pending = classifierRequests.removeValue(forKey: requestID) else {
            lock.unlock()
            return
        }
        let source = peers.values.first { $0.connected && $0.id == pending.sourcePeerID }?.connection
        lock.unlock()
        if let source {
            send(source, dict: [
                "kind": "classifier-response",
                "requestID": requestID,
                "operation": pending.operation,
                "error": "classifier-timeout",
            ])
        }
    }

    private func removePeer(_ key: ObjectIdentifier) {
        lock.lock()
        let removed = peers.removeValue(forKey: key)
        let program = removed?.program
        let removedPeerID = removed?.id
        // If a browser disconnects, retain its in-flight route until the
        // classifier replies or the six-second expiry fires. Otherwise that
        // valid later reply would look unmatched and unnecessarily disconnect
        // the classifier peer. A classifier disconnect, by contrast, fails
        // every route it owns immediately.
        let affectedRequests = classifierRequests.filter { _, pending in
            guard let removedPeerID else { return false }
            return pending.classifierPeerID == removedPeerID
        }
        for (requestID, _) in affectedRequests {
            classifierRequests.removeValue(forKey: requestID)
        }
        let replyTargets: [(NWConnection, String, String)] = affectedRequests.compactMap { requestID, pending in
            guard pending.classifierPeerID == removedPeerID,
                  let source = peers.values.first(where: { $0.connected && $0.id == pending.sourcePeerID }) else {
                return nil
            }
            return (source.connection, requestID, pending.operation)
        }
        let existed = removed != nil
        lock.unlock()
        for (source, requestID, operation) in replyTargets {
            send(source, dict: [
                "kind": "classifier-response",
                "requestID": requestID,
                "operation": operation,
                "error": "classifier-unavailable",
            ])
        }
        if let program, !program.isEmpty {
            // A dropped socket means the program went OFFLINE, not that it left
            // its clusters. We keep its cluster membership and its last
            // contribution (sites/apps/scalars/usage baseline) so the cluster's
            // shared memory survives a brief disconnect — the member is shown
            // offline until it reconnects. The roster is dropped because it is
            // re-announced on reconnect, so stale groups can't validate links.
            lock.lock()
            rosters.removeValue(forKey: program)
            let affected = clusters.values
                .filter { $0.members.contains(program) }
                .map { clusterJSONObject($0) }
            lock.unlock()
            for snapshot in affected { broadcastCluster(snapshot) }
        }
        if existed { broadcastPeers() }
    }

    private func broadcastPeers() {
        lock.lock()
        let conns = peers.values.filter { $0.connected }.map { $0.connection }
        lock.unlock()
        let payload: [String: Any] = ["kind": "peers", "peers": peerListJSON()]
        for conn in conns { send(conn, dict: payload) }
    }

    // MARK: Status

    private func peerListJSON() -> [[String: Any]] {
        lock.lock()
        let list = peers.values.filter { $0.connected }.map {
            ["id": $0.id, "program": $0.program, "connected": $0.connected] as [String: Any]
        }
        lock.unlock()
        return list
    }

    private func setRunning(_ value: Bool) {
        lock.lock(); running = value; lock.unlock()
    }

    private func setError(_ message: String) {
        lock.lock(); lastError = message; running = false; lock.unlock()
    }

    /// JSON status string in the shape the web editor's `__cbConnectionState`
    /// receiver expects.
    func currentStatusJSON() -> String {
        lock.lock()
        let running = self.running
        let err = self.lastError
        let peerList = self.brokerPeers
        let hosting = self.hostingLocalHub
        let joinedProgram = self.joinedHubProgram
        lock.unlock()
        let visiblePeers = hosting ? peerListJSON() : peerList
        let state: String
        if !err.isEmpty {
            state = err
        } else if hosting {
            state = "hosting"
        } else if running {
            state = "joined"
        } else {
            state = "off"
        }
        let status: [String: Any] = [
            "running": running,
            "state": state,
            "address": Self.brokerAddress,
            "peers": visiblePeers,
            "error": err,
            "hubProgram": hosting ? "macapp" : joinedProgram
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: status),
              let json = String(data: data, encoding: .utf8) else {
            return "{\"running\":false,\"state\":\"off\",\"peers\":[]}"
        }
        return json
    }

    // MARK: Cluster registry API (called from the WS path and the web bridge)

    /// Records an endpoint's eligible groups. `program` "macapp" is this Mac.
    ///
    /// A roster announcement is the full, current set of bridge-eligible groups
    /// for that program (it is re-sent after every edit, delete, and reconnect),
    /// so it doubles as the authoritative "decouple on delete" signal: any
    /// cluster this program belongs to whose group name+type is no longer in the
    /// roster was deleted (or renamed) on that endpoint, and the program must
    /// leave it. This works even when the *peer* is offline — the cluster is
    /// updated/dissolved in the hub registry now, and the peer reconciles from
    /// the clusters snapshot on its next reconnect — and it stops a same-named
    /// group created later from silently re-joining a stale cluster, because the
    /// cluster is gone once it drops below two members.
    func setRoster(program: String, groups: [[String: Any]]) {
        guard !program.isEmpty else { return }
        let infos = groups.map {
            GroupInfo(
                id: ($0["id"] as? String) ?? "",
                name: ($0["name"] as? String) ?? "",
                type: ($0["type"] as? String) ?? "",
                frozen: ($0["frozen"] as? Bool) ?? false
            )
        }
        lock.lock()
        rosters[program] = infos
        // Snapshot the affected clusters first so we can mutate `clusters` safely
        // inside the loop (ClusterState is a class, so these are live references).
        let affected = clusters.values.filter { $0.members.contains(program) }
        var snapshots: [[String: Any]] = []
        var changed = false
        for cluster in affected {
            // Membership is pinned to the group *instance* this program linked.
            // Backfill the id for clusters formed before id pinning (or restored
            // from disk) by matching name+type once; this auto-migrates old links.
            var pinnedId = cluster.memberGroupIds[program] ?? ""
            if pinnedId.isEmpty,
               let legacy = infos.first(where: {
                   $0.name == cluster.groupName && $0.type == cluster.groupType
               }), !legacy.id.isEmpty {
                pinnedId = legacy.id
                cluster.memberGroupIds[program] = pinnedId
                changed = true
            }
            // Keep the member only if its pinned instance is still present under
            // the same name+type. A delete removes the id; a re-create under the
            // same name yields a NEW id (so it can't silently re-join); a rename
            // changes the name (so it decouples, matching the name-based UX).
            // Frozen groups stay in the roster, so a freeze never decouples.
            let stillPresent: Bool
            if pinnedId.isEmpty {
                // No id to pin against (pre-id-pinning client): name+type only.
                stillPresent = infos.contains {
                    $0.name == cluster.groupName && $0.type == cluster.groupType
                }
            } else {
                stillPresent = infos.contains {
                    $0.id == pinnedId &&
                    $0.name == cluster.groupName &&
                    $0.type == cluster.groupType
                }
            }
            if stillPresent { continue }
            cluster.members.remove(program)
            cluster.memberGroupIds.removeValue(forKey: program)
            cluster.contributions.removeValue(forKey: program)
            if cluster.members.count < 2 {
                clusters.removeValue(forKey: cluster.id)
                cluster.members.removeAll()
            }
            changed = true
            snapshots.append(clusterJSONObject(cluster))
        }
        if changed { persistClustersLocked() }
        lock.unlock()
        for snapshot in snapshots { broadcastCluster(snapshot) }
    }

    /// Number of live clusters (≥2 members). Used to warn the user before
    /// quitting, since quitting stops the hub and breaks links until relaunch.
    func activeClusterCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return clusters.values.filter { $0.members.count >= 2 }.count
    }

    /// Links the same-named group on two programs into one cluster. Requires both
    /// to have a matching, unfrozen group of the same type; otherwise rejects.
    func connectGroup(from: String, to: String, groupName: String, groupType: String) {
        guard !from.isEmpty, !to.isEmpty, !groupName.isEmpty, from != to else { return }
        lock.lock()
        let fromOk = rosterHasEligibleLocked(from, name: groupName, type: groupType)
        let toOk = rosterHasEligibleLocked(to, name: groupName, type: groupType)
        if !(fromOk && toOk) {
            lock.unlock()
            let reason = !fromOk
                ? "this group must be unfrozen to connect"
                : "no matching unfrozen \"\(groupName)\" group on \(to)"
            rejectTo(program: from, reason: reason)
            return
        }
        let cluster = clusters.values.first { $0.groupName == groupName && $0.groupType == groupType }
            ?? {
                let created = ClusterState(id: UUID().uuidString, groupName: groupName, groupType: groupType)
                clusters[created.id] = created
                return created
            }()
        cluster.members.insert(from)
        cluster.members.insert(to)
        // Pin each member to the specific local group instance it linked, so a
        // later delete + same-name re-create can't silently re-join this cluster.
        if let fromId = rosterGroupIdLocked(from, name: groupName, type: groupType), !fromId.isEmpty {
            cluster.memberGroupIds[from] = fromId
        }
        if let toId = rosterGroupIdLocked(to, name: groupName, type: groupType), !toId.isEmpty {
            cluster.memberGroupIds[to] = toId
        }
        persistClustersLocked()
        let snapshot = clusterJSONObject(cluster)
        lock.unlock()
        broadcastCluster(snapshot)
    }

    func disconnectGroup(clusterId: String, groupName: String, program: String) {
        lock.lock()
        var target = clusters[clusterId]
        if target == nil { target = clusters.values.first { $0.groupName == groupName } }
        guard let cluster = target else { lock.unlock(); return }
        cluster.members.remove(program)
        cluster.memberGroupIds.removeValue(forKey: program)
        cluster.contributions.removeValue(forKey: program)
        if cluster.members.count < 2 {
            clusters.removeValue(forKey: cluster.id)
            cluster.members.removeAll()
        }
        persistClustersLocked()
        let snapshot = clusterJSONObject(cluster)
        lock.unlock()
        broadcastCluster(snapshot)
    }

    /// Folds one member's contribution into the cluster's shared state and, if the
    /// shared snapshot changed, broadcasts it. This is the heart of the sync
    /// engine: scalars are last-writer-wins, lists are a union of owned lists, and
    /// the usage counter is a delta accumulator (the Mac is the budget authority).
    func applySync(program: String, groupName: String, groupType: String, contribution: [String: Any], ts: Double) {
        guard !program.isEmpty, !groupName.isEmpty else { return }
        lock.lock()
        guard let cluster = clusters.values.first(where: {
            $0.groupName == groupName && $0.members.contains(program)
        }) else {
            lock.unlock()
            return
        }

        let before = clusterJSONObject(cluster)

        // Block-list / scalar contributions only update when the message
        // actually carries them. Lightweight usage-only pings (sent by the
        // browser background when its popup is closed) must NOT clobber the
        // member's stored sites/apps/scalars contribution.
        let scalarsPayload = contribution["scalars"] as? [String: Any]
        let carriesConfig =
            scalarsPayload != nil ||
            contribution["sites"] != nil ||
            contribution["apps"] != nil
        if carriesConfig {
            var stored: [String: Any] = ["scalars": scalarsPayload ?? [:]]
            if let sites = contribution["sites"] as? [String] { stored["sites"] = sites }
            // Apps may arrive as plain name strings (legacy) or as { name, icon }
            // objects (so the browser mirror can show app icons). Store whatever
            // shape we got; clusterJSONObject normalizes on read.
            if let apps = contribution["apps"] { stored["apps"] = apps }
            cluster.contributions[program] = stored

            // Scalars: last writer wins, except the link initiator forces its
            // settings to win the first merge (priority flag).
            let priority = (contribution["priority"] as? Bool) ?? false
            if let scalars = scalarsPayload {
                if priority {
                    cluster.sharedScalars = scalars
                    cluster.sharedTs = max(cluster.sharedTs, ts) + 1
                } else if ts >= cluster.sharedTs {
                    cluster.sharedScalars = scalars
                    cluster.sharedTs = ts
                }
            }

            // Freeze is NOT last-writer-wins. With both sides stamping Date.now()
            // the LWW winner is order-dependent, so the cluster freeze flipped
            // randomly on couple/decouple. Instead we take the MOST RESTRICTIVE
            // freeze across every member's stored contribution: freezing any
            // member propagates and the state is stable until every member is
            // unfrozen. This runs after the scalar merge so it overrides whatever
            // freeze the LWW happened to pick.
            mergeFreezeLocked(cluster)
        }

        // Usage: shared budget via delta accrual. Members report increments
        // (usageDeltaMs) measured at their own accrual point — the browser's page
        // heartbeat and the Mac's frontmost-app sampler. Because we only ever ADD
        // reported increments (never adopt an absolute), folding the broadcast
        // total back into each member's local counter produces no echo and no
        // double counting, and there is no "decrease == reset" race. A newer
        // reset anchor rolls the whole budget over.
        if let anchor = contribution["usageResetAtMs"] as? Double, anchor > cluster.sharedUsageResetAtMs {
            cluster.sharedUsageMs = 0
            cluster.sharedUsageResetAtMs = anchor
            cluster.usageSeeded = false
        }
        if let delta = contribution["usageDeltaMs"] as? Double, delta != 0 {
            cluster.sharedUsageMs = max(0, cluster.sharedUsageMs + delta)
            cluster.usageSeeded = true
        } else if !cluster.usageSeeded,
                  let seed = contribution["usageMs"] as? Double,
                  seed > cluster.sharedUsageMs {
            // No real delta yet: seed the budget from the largest existing member
            // counter so a group that already had usage keeps it when it links.
            cluster.sharedUsageMs = seed
        }

        // Active snooze: newest start wins. A member only carries `snoozeTs` when
        // it actually has an active/cooling snooze entry, so usage-only pings and
        // members without a snooze never clobber a snooze started elsewhere.
        if let snoozeTs = contribution["snoozeTs"] as? Double, snoozeTs > 0 {
            if snoozeTs > cluster.sharedSnoozeTs {
                cluster.sharedSnoozeTs = snoozeTs
                cluster.sharedSnooze = (contribution["snooze"] as? [String: Any]) ?? [:]
            }
        }

        // Cumulative snooze total: keep the max across members (display only).
        if let total = contribution["snoozeTotalMs"] as? Double, total > cluster.sharedSnoozeTotalMs {
            cluster.sharedSnoozeTotalMs = total
        }

        // Persist only on config-bearing syncs (scalars/sites/apps/snooze), not
        // on per-tick usage pings, so the on-disk registry tracks structural and
        // settings changes without hammering the disk every second.
        if carriesConfig { persistClustersLocked() }

        let after = clusterJSONObject(cluster)
        lock.unlock()

        if !NSDictionary(dictionary: before).isEqual(to: after) {
            broadcastCluster(after)
        }
    }

    /// Called by the in-process macOS enforcer when it accrues (or rolls over)
    /// usage for one of its groups. A no-op unless the Mac's group is actually
    /// in a cluster (applySync ignores unknown clusters). `deltaMs` is the time
    /// just accrued for the frontmost blocked app; `resetAtMs` is the group's
    /// current reset anchor (a newer anchor rolls the shared budget over).
    func reportLocalUsage(groupName: String, deltaMs: Double, resetAtMs: Double, seedMs: Double? = nil) {
        var contribution: [String: Any] = ["usageResetAtMs": resetAtMs]
        if deltaMs != 0 { contribution["usageDeltaMs"] = deltaMs }
        // A seed is the Mac's absolute local total, used by the hub only until the
        // first real delta arrives (it adopts the largest member total) so prior
        // Mac usage survives joining a cluster.
        if let seedMs { contribution["usageMs"] = seedMs }
        contribution["kind"] = "group-sync"
        contribution["program"] = Self.localProgram
        contribution["groupName"] = groupName
        contribution["groupType"] = "site"
        contribution["ts"] = 0
        submitBridgeFrame(contribution)
    }

    /// The hub-authoritative shared usage budget for a Mac-clustered Default
    /// group, or nil when the Mac's group isn't in any cluster. The in-process
    /// enforcer folds this total back into its local timer so the Mac display +
    /// enforcement reflect time spent on every linked member (e.g. browser
    /// website time), not just the Mac's own frontmost-app time.
    func sharedUsage(groupName: String) -> (ms: Double, resetAtMs: Double)? {
        guard !groupName.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let cluster = clusters.values.first(where: {
            $0.groupName == groupName && $0.members.contains(Self.localProgram)
        }) else { return nil }
        return (cluster.sharedUsageMs, cluster.sharedUsageResetAtMs)
    }

    func syncFromBridge(json: String) {
        guard let obj = decode(json) else { return }
        submitBridgeFrame(obj)
    }

    /// JSON array of all clusters, pushed to the Mac's own web editor each tick.
    func clustersJSON() -> String {
        lock.lock()
        let arr = clusters.values.map { clusterJSONObject($0) }
        lock.unlock()
        guard let data = try? JSONSerialization.data(withJSONObject: arr),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }

    /// Returns and clears any pending Mac-initiated rejection, as JSON.
    func takeLocalRejectionJSON() -> String? {
        lock.lock()
        let reason = pendingLocalRejection
        pendingLocalRejection = nil
        lock.unlock()
        guard let reason else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: ["reason": reason]),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return json
    }

    // MARK: Cluster registry — JSON-string entry points for the web bridge

    func announceFromBridge(json: String) {
        guard let obj = decode(json) else { return }
        lastBridgeAnnouncement = obj
        submitBridgeFrame(obj)
    }

    func connectFromBridge(json: String) {
        guard let obj = decode(json) else { return }
        submitBridgeFrame(obj)
    }

    func disconnectFromBridge(json: String) {
        guard let obj = decode(json) else { return }
        submitBridgeFrame(obj)
    }

    /// The hosting Mac is itself a local endpoint, so its editor frames are
    /// applied straight to the hub state. A non-host sends the exact same frame
    /// through the one shared loopback socket.
    private func submitBridgeFrame(_ frame: [String: Any]) {
        lock.lock()
        let isHosting = hostingLocalHub
        lock.unlock()
        guard isHosting else {
            sendBroker(frame)
            return
        }
        switch frame["kind"] as? String {
        case "groups-announce":
            setRoster(program: Self.localProgram, groups: frame["groups"] as? [[String: Any]] ?? [])
        case "connect-group":
            connectGroup(
                from: Self.localProgram,
                to: frame["toProgram"] as? String ?? "",
                groupName: frame["groupName"] as? String ?? "",
                groupType: frame["groupType"] as? String ?? ""
            )
        case "disconnect-group":
            disconnectGroup(
                clusterId: frame["clusterId"] as? String ?? "",
                groupName: frame["groupName"] as? String ?? "",
                program: Self.localProgram
            )
        case "group-sync":
            applySync(
                program: Self.localProgram,
                groupName: frame["groupName"] as? String ?? "",
                groupType: frame["groupType"] as? String ?? "",
                contribution: frame,
                ts: frame["ts"] as? Double ?? 0
            )
        default:
            break
        }
    }

    private func replaceBrokerClusters(_ snapshots: [[String: Any]]) {
        lock.lock()
        clusters.removeAll()
        for snapshot in snapshots { installBrokerClusterLocked(snapshot) }
        lock.unlock()
    }

    private func applyBrokerCluster(_ snapshot: [String: Any]) {
        guard let identifier = snapshot["id"] as? String else { return }
        lock.lock()
        if let members = snapshot["members"] as? [[String: Any]], members.isEmpty {
            clusters.removeValue(forKey: identifier)
        } else {
            installBrokerClusterLocked(snapshot)
        }
        lock.unlock()
    }

    private func installBrokerClusterLocked(_ snapshot: [String: Any]) {
        guard let identifier = snapshot["id"] as? String,
              let groupName = snapshot["groupName"] as? String,
              let groupType = snapshot["groupType"] as? String else { return }
        let cluster = ClusterState(id: identifier, groupName: groupName, groupType: groupType)
        for member in (snapshot["members"] as? [[String: Any]] ?? []) {
            guard let program = member["program"] as? String else { continue }
            cluster.members.insert(program)
            if let groupID = member["groupId"] as? String { cluster.memberGroupIds[program] = groupID }
            if member["online"] as? Bool == true { cluster.onlineMembers.insert(program) }
        }
        if let shared = snapshot["shared"] as? [String: Any] {
            cluster.sharedScalars = shared["scalars"] as? [String: Any] ?? [:]
            cluster.sharedTs = (shared["ts"] as? NSNumber)?.doubleValue ?? 0
            cluster.sharedSites = shared["sites"] as? [String] ?? []
            cluster.sharedApps = shared["apps"] as? [[String: Any]] ?? []
            cluster.sharedUsageMs = (shared["usageMs"] as? NSNumber)?.doubleValue ?? 0
            cluster.sharedUsageResetAtMs = (shared["usageResetAtMs"] as? NSNumber)?.doubleValue ?? 0
            cluster.sharedSnooze = shared["snooze"] as? [String: Any] ?? [:]
            cluster.sharedSnoozeTs = (shared["snoozeTs"] as? NSNumber)?.doubleValue ?? 0
            cluster.sharedSnoozeTotalMs = (shared["snoozeTotalMs"] as? NSNumber)?.doubleValue ?? 0
        }
        clusters[identifier] = cluster
    }

    // MARK: Cluster registry — internals

    private func decode(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Restrictiveness rank for a freeze mode. Higher wins the cluster merge.
    /// none < frozen (password) < parental < strict (time-locked).
    private func freezeRank(_ mode: String?) -> Int {
        switch mode {
        case "strict": return 3
        case "parental": return 2
        case "frozen": return 1
        default: return 0
        }
    }

    /// Caller must hold `lock`. Overwrites the freeze fields in `sharedScalars`
    /// with the most-restrictive freeze tuple found across all member
    /// contributions. Deterministic (no timestamps), so coupling/decoupling can
    /// never flip the freeze state at random. The whole tuple is copied from the
    /// winning member so frozenAtMs / strictFreezeHours / freezeModeChoice stay
    /// internally consistent.
    private func mergeFreezeLocked(_ cluster: ClusterState) {
        let freezeFields = ["freezeMode", "freezeModeChoice", "strictFreezeHours", "frozenAtMs"]
        var bestRank = -1
        var bestFreeze: [String: Any]? = nil
        for contribution in cluster.contributions.values {
            guard let scalars = contribution["scalars"] as? [String: Any] else { continue }
            let rank = freezeRank(scalars["freezeMode"] as? String)
            if rank > bestRank {
                bestRank = rank
                var tuple: [String: Any] = [:]
                for field in freezeFields where scalars[field] != nil {
                    tuple[field] = scalars[field]
                }
                bestFreeze = tuple
            }
        }
        guard let winning = bestFreeze else { return }
        for field in freezeFields {
            if let value = winning[field] {
                cluster.sharedScalars[field] = value
            } else {
                cluster.sharedScalars.removeValue(forKey: field)
            }
        }
    }

    /// Caller must hold `lock`. Persists the cluster registry so links survive an
    /// app/server restart — the user only loses a cluster by explicitly
    /// disconnecting it. Live usage is intentionally NOT persisted (it is
    /// re-seeded from each member's local counter on reconnect), which also
    /// avoids per-tick disk writes; this is called only on structural / config
    /// changes.
    private func persistClustersLocked() {
        let arr: [[String: Any]] = clusters.values.map { c in
            [
                "id": c.id,
                "groupName": c.groupName,
                "groupType": c.groupType,
                "members": Array(c.members),
                "memberGroupIds": c.memberGroupIds,
                "contributions": c.contributions,
                "sharedScalars": c.sharedScalars,
                "sharedTs": c.sharedTs,
                "sharedSnooze": c.sharedSnooze,
                "sharedSnoozeTs": c.sharedSnoozeTs,
                "sharedSnoozeTotalMs": c.sharedSnoozeTotalMs
            ]
        }
        if let data = try? JSONSerialization.data(withJSONObject: arr) {
            UserDefaults.standard.set(data, forKey: ConnectionHub.clustersDefaultsKey)
        }
    }

    /// Caller must hold `lock`. Rebuilds the cluster registry from disk on boot.
    /// Usage fields start at 0/unseeded so the first member report re-seeds the
    /// shared budget from the largest member total.
    private func restoreClustersLocked() {
        guard let data = UserDefaults.standard.data(forKey: ConnectionHub.clustersDefaultsKey),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return }
        for obj in arr {
            guard let id = obj["id"] as? String,
                  let groupName = obj["groupName"] as? String,
                  let groupType = obj["groupType"] as? String else { continue }
            let cluster = ClusterState(id: id, groupName: groupName, groupType: groupType)
            if let members = obj["members"] as? [String] { cluster.members = Set(members) }
            if let ids = obj["memberGroupIds"] as? [String: String] { cluster.memberGroupIds = ids }
            if let contributions = obj["contributions"] as? [String: [String: Any]] {
                cluster.contributions = contributions
            }
            if let scalars = obj["sharedScalars"] as? [String: Any] { cluster.sharedScalars = scalars }
            cluster.sharedTs = (obj["sharedTs"] as? Double) ?? 0
            if let snooze = obj["sharedSnooze"] as? [String: Any] { cluster.sharedSnooze = snooze }
            cluster.sharedSnoozeTs = (obj["sharedSnoozeTs"] as? Double) ?? 0
            cluster.sharedSnoozeTotalMs = (obj["sharedSnoozeTotalMs"] as? Double) ?? 0
            // Only restore clusters that still have ≥2 members (a 1-member
            // cluster is meaningless and would never broadcast).
            if cluster.members.count >= 2 { clusters[id] = cluster }
        }
    }

    /// Caller must hold `lock`.
    private func rosterHasEligibleLocked(_ program: String, name: String, type: String) -> Bool {
        guard let infos = rosters[program] else { return false }
        return infos.contains { $0.name == name && $0.type == type && !$0.frozen }
    }

    /// Caller must hold `lock`. The local group id for an eligible (unfrozen)
    /// same-named group, used to pin cluster membership to a specific instance.
    private func rosterGroupIdLocked(_ program: String, name: String, type: String) -> String? {
        guard let infos = rosters[program] else { return nil }
        return infos.first { $0.name == name && $0.type == type && !$0.frozen }?.id
    }

    /// Caller must hold `lock`. Programs with a live connected peer, plus the Mac
    /// host itself (always online while the hub runs). Used to flag cluster
    /// members online/offline.
    private func onlineProgramsLocked() -> Set<String> {
        var set = Set<String>()
        for peer in peers.values where peer.connected && !peer.program.isEmpty {
            set.insert(peer.program)
        }
        set.insert(Self.localProgram)
        return set
    }

    /// Caller must hold `lock`. Serializes a cluster including the shared state
    /// and the union of owned lists (sites from browsers, apps from Macs).
    private func clusterJSONObject(_ cluster: ClusterState) -> [String: Any] {
        var sites = Set(cluster.sharedSites)
        // App pool keyed by display name → icon data URL. A non-empty icon from
        // any member wins so a name contributed without an icon (legacy string)
        // still picks up the icon when another member supplies it.
        var appIcons: [String: String] = [:]
        for entry in cluster.sharedApps {
            guard let name = entry["name"] as? String, !name.isEmpty else { continue }
            appIcons[name] = (entry["icon"] as? String) ?? ""
        }
        for contribution in cluster.contributions.values {
            if let list = contribution["sites"] as? [String] { sites.formUnion(list) }
            if let list = contribution["apps"] as? [[String: Any]] {
                for entry in list {
                    let name = (entry["name"] as? String) ?? ""
                    guard !name.isEmpty else { continue }
                    let icon = (entry["icon"] as? String) ?? ""
                    if (appIcons[name] ?? "").isEmpty { appIcons[name] = icon }
                }
            } else if let list = contribution["apps"] as? [String] {
                for name in list where !name.isEmpty {
                    if appIcons[name] == nil { appIcons[name] = "" }
                }
            }
        }
        let appsArray: [[String: Any]] = appIcons.keys.sorted().map {
            ["name": $0, "icon": appIcons[$0] ?? ""]
        }
        let online = cluster.onlineMembers
        let allOnline = cluster.members.allSatisfy { online.contains($0) }
        let hasShared = !cluster.sharedScalars.isEmpty || cluster.sharedTs > 0
        var dict: [String: Any] = [
            "id": cluster.id,
            "groupName": cluster.groupName,
            "groupType": cluster.groupType,
            "allOnline": allOnline,
            "members": cluster.members.sorted().map {
                [
                    "program": $0,
                    "groupName": cluster.groupName,
                    "groupId": cluster.memberGroupIds[$0] ?? "",
                    "online": online.contains($0)
                ] as [String: Any]
            }
        ]
        if hasShared || !sites.isEmpty || !appsArray.isEmpty || cluster.sharedUsageMs > 0
            || cluster.sharedSnoozeTs > 0 || cluster.sharedSnoozeTotalMs > 0 {
            dict["shared"] = [
                "scalars": cluster.sharedScalars,
                "ts": cluster.sharedTs,
                "sites": sites.sorted(),
                "apps": appsArray,
                "usageMs": cluster.sharedUsageMs,
                "usageResetAtMs": cluster.sharedUsageResetAtMs,
                "snooze": cluster.sharedSnooze,
                "snoozeTs": cluster.sharedSnoozeTs,
                "snoozeTotalMs": cluster.sharedSnoozeTotalMs
            ] as [String: Any]
        }
        return dict
    }

    private func broadcastCluster(_ snapshot: [String: Any]) {
        let payload: [String: Any] = ["kind": "cluster-updated", "cluster": snapshot]
        lock.lock()
        let conns = peers.values.filter { $0.connected }.map { $0.connection }
        lock.unlock()
        for conn in conns { send(conn, dict: payload) }
        // The Mac's own web editor is refreshed by the per-tick clustersJSON push.
    }

    private func sendClustersSnapshot(_ conn: NWConnection) {
        lock.lock()
        let arr = clusters.values.map { clusterJSONObject($0) }
        lock.unlock()
        send(conn, dict: ["kind": "clusters", "clusters": arr])
    }

    private func rejectTo(program: String, reason: String) {
        if program == Self.localProgram {
            lock.lock()
            pendingLocalRejection = reason
            lock.unlock()
            return
        }
        lock.lock()
        let conn = peers.values.first { $0.connected && $0.program == program }?.connection
        lock.unlock()
        if let conn {
            send(conn, dict: ["kind": "connect-group-rejected", "reason": reason])
        }
    }

}
#endif
