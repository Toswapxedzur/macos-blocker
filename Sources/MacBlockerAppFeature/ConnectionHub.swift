#if os(macOS)
import Foundation
import MacBlockerCore
import Network
import VaultClassifierBridge

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
    static let classifierRelayTimeoutSeconds = 30
    // The browser relay carries larger bodies than the classifier route because
    // an MCP-driven read can return page content or the open-tab list; still
    // well under the 1 MiB socket frame cap.
    private static let maxBrowserBodyBytes = 800_000
    private static let maxBrowserRequests = 32
    static let browserRelayTimeoutSeconds = 30
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
    struct ClassifierRequest {
        let sourcePeerID: String
        let classifierPeerID: String
        let operation: String
    }

    enum ClassifierResponseCorrelation: Equatable {
        case matched
        case expired
        case mismatched
    }

    /// A short-lived request the hub host relays *to* a connected browser peer on
    /// behalf of the in-process MCP server. The hub owns the correlation so a
    /// browser can only answer the request actually routed to it — the mirror of
    /// the classifier route, in the opposite direction.
    struct BrowserRequest {
        let requestID: String
        let browserPeerID: String
        let operation: String
        let completion: (BrowserRelayResult) -> Void
    }

    enum BrowserRelayResult {
        case success([String: Any])
        case failure(String)
    }

    /// Process-wide hub. Owned at the app-delegate level (not by any SwiftUI
    /// view) so the server survives closing the editor window and lives for the
    /// whole app session.
    static let shared = ConnectionHub()

    private let queue = DispatchQueue(label: "macosBlocker.ConnectionHub")
    private let lock = NSLock()

    /// The Activity log store. When set, the hub handles the activity ops locally
    /// (writing this store) instead of relaying them to the classifier peer. Set
    /// once at launch; shared with the native app-usage recorder.
    var activityStore: ActivityStore?
    // Kept in sync with SharedBrowserBridgeOperation.activityRecord/.activitySettings
    // (the enum is the cross-repo source of truth; the extension parity test checks
    // the extension side against it). These are handled locally, not relayed.
    private static let activityRequestOperations: Set<String> = ["activity-record", "activity-settings"]

    private var listener: NWListener?
    private var peers: [ObjectIdentifier: Peer] = [:]
    private var classifierRequests: [String: ClassifierRequest] = [:]
    private var browserRequests: [String: BrowserRequest] = [:]
    /// A listen that failed (the port is still held by a Mac Vault that is
    /// quitting) is tried again.
    private var reconnectWorkItem: DispatchWorkItem?
    /// While hosting: starts each linked group's new budget period on time,
    /// even when no member is reporting usage (the hub owns the period).
    private var budgetTimer: DispatchSourceTimer?
    /// The registry last written (skips identical writes from the budget timer).
    private var lastPersistedClusters: Data?
    private var wantsToListen = false
    // Internal (not private) so tests can stand in for a hosting hub.
    var hostingLocalHub = false
    static func helloRejectionReason(_ obj: [String: Any], challenge: String, secret: Data?) -> String? {
        let version = (obj["v"] as? NSNumber)?.intValue
        guard version == protocolVersion else { return "protocol-mismatch" }
        guard let program = obj["program"] as? String, remotePrograms.contains(program) else {
            return "invalid-program"
        }
        guard let secret else { return "authentication-failed" }
        guard obj["challenge"] as? String == challenge else { return "authentication-failed" }
        guard let proof = obj["proof"] as? String else { return "authentication-failed" }
        guard VaultClassifierBridge.LocalHubAuthentication.verifyProof(
            program: program, challenge: challenge, proof: proof, secret: secret
        ) else { return "authentication-failed" }
        return nil
    }

    /// One connection per browser (owner 2026-09-25): a second instance of a
    /// browser program (two Chromes, a test rig beside the real browser) is
    /// refused while the first is connected, so two instances can never take
    /// turns overwriting each other's roster and contributions. When the first
    /// connection closes, the next hello wins (a refused browser keeps
    /// retrying). The classifier is not a browser and is exempt.
    static func isDuplicateBrowser(_ program: String, connectedPrograms: [String]) -> Bool {
        guard program != "classifier" else { return false }
        return connectedPrograms.contains(program)
    }

    static func classifierRequestRejectionReason(_ obj: [String: Any]) -> String? {
        guard let requestID = obj["requestID"] as? String,
              isVisibleBridgeIdentifier(requestID, maximumLength: 128),
              let operation = obj["operation"] as? String,
              ["bridge-info", "collection-info", "diagnostic", "collect", "video-tags", "video-tags-batch", "classifier-taxonomy", "submit-correction", "dev-log", "activity-record", "activity-settings"].contains(operation),
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
              ["bridge-info", "collection-info", "diagnostic", "collect", "video-tags", "video-tags-batch", "classifier-taxonomy", "submit-correction", "dev-log", "activity-record", "activity-settings"].contains(operation) else {
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

    static func classifierResponseCorrelation(
        pending: ClassifierRequest?,
        classifierPeerID: String,
        sourcePeerID: String,
        operation: String
    ) -> ClassifierResponseCorrelation {
        guard let pending else { return .expired }
        guard pending.classifierPeerID == classifierPeerID,
              pending.sourcePeerID == sourcePeerID,
              pending.operation == operation else {
            return .mismatched
        }
        return .matched
    }

    /// Validates an outbound browser-relay call. The operation namespace is a
    /// bounded visible identifier rather than a fixed enum: unlike the classifier
    /// route, the browser relay is deliberately generic, and the extension's own
    /// inbound adapter is the authority on which operations it honors.
    static func browserRequestRejectionReason(operation: String, body: [String: Any]) -> String? {
        guard isVisibleBridgeIdentifier(operation, maximumLength: 64) else {
            return "invalid-browser-operation"
        }
        guard JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body),
              data.count <= maxBrowserBodyBytes else {
            return "invalid-browser-request"
        }
        return nil
    }

    static func browserResponseRejectionReason(_ obj: [String: Any]) -> String? {
        guard let requestID = obj["requestID"] as? String,
              isVisibleBridgeIdentifier(requestID, maximumLength: 128),
              let operation = obj["operation"] as? String,
              isVisibleBridgeIdentifier(operation, maximumLength: 64) else {
            return "invalid-browser-response"
        }
        if let body = obj["body"] as? [String: Any],
           JSONSerialization.isValidJSONObject(body),
           let bodyData = try? JSONSerialization.data(withJSONObject: body),
           bodyData.count <= maxBrowserBodyBytes {
            return nil
        }
        if let error = obj["error"] as? String,
           error.count <= 256,
           error.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value <= 0x7e }) {
            return nil
        }
        return "invalid-browser-response"
    }

    static func browserResponseCorrelation(
        pending: BrowserRequest?,
        browserPeerID: String,
        operation: String
    ) -> ClassifierResponseCorrelation {
        guard let pending else { return .expired }
        guard pending.browserPeerID == browserPeerID,
              pending.operation == operation else {
            return .mismatched
        }
        return .matched
    }

    static func isWebSocketClose(_ context: NWConnection.ContentContext?) -> Bool {
        let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
            as? NWProtocolWebSocket.Metadata
        return metadata?.opcode == .close
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
        let frozen: Bool
    }

    /// A live cluster: the bound programs plus the hub-authoritative shared
    /// settings derived from each member's contribution.
    private final class ClusterState {
        let id: String
        let groupName: String
        var members: Set<String> = []
        /// Per-program local group id: the specific group *instance* that program
        /// linked. Membership is pinned to this id so deleting a group and later
        /// re-creating one with the same name does NOT silently re-join the old
        /// cluster (the new group carries a fresh id).
        var memberGroupIds: [String: String] = [:]
        /// The members that have contributed their definition: a member's FIRST
        /// contribution unions its lines into the shared ones.
        var contributed: Set<String> = []
        // Hub-authoritative shared state: the one group definition every
        // member adopts. Scalars and scopes are latest-edit-wins (see applySync).
        var sharedScalars: [String: Any] = [:]
        var sharedTs: Double = 0
        var sharedScopes: [[String: Any]] = []
        /// The link's one lock (group-actions.js lockUnit), versioned; empty
        /// until a member contributes one.
        var sharedLock: [String: Any] = [:]
        /// Shared live usage budget. Members report *increments* (usageDeltaMs)
        /// from their own accrual, never absolutes, so folding this total back
        /// into each member's local counter can never double count. Before any
        /// delta arrives we seed it from the largest member absolute so joining a
        /// cluster with prior usage doesn't wipe it.
        var sharedUsageMs: Double = 0
        var sharedUsageResetAtMs: Double = 0
        var usageSeeded = false
        /// Rolling-limit groups share per-minute usage (minute-start ms -> ms)
        /// instead of one total: a sliding window needs to know WHEN time was
        /// used so old minutes can age out. Deltas only, like `sharedUsageMs`.
        var sharedBuckets: [Double: Double] = [:]
        var bucketsSeeded = false
        /// Active snooze runtime shared across members (newest start wins). The
        /// entry carries its own timing so each side enforces + expires it
        /// identically; `sharedSnoozeTs` is the originating start time.
        var sharedSnooze: [String: Any] = [:]
        var sharedSnoozeTs: Double = 0
        /// The link's total snoozed time: the hub counts each shared snooze once,
        /// when it has finished (members show this figure). `snoozeCountedStartMs`
        /// is the start of the last snooze counted (entries run one at a time).
        var sharedSnoozeTotalMs: Double = 0
        var snoozeCountedStartMs: Double = 0

        init(id: String, groupName: String) {
            self.id = id
            self.groupName = groupName
        }
    }

    /// Each endpoint's eligible Default/Custom groups, keyed by program id.
    private var rosters: [String: [GroupInfo]] = [:]
    /// Active clusters keyed by cluster id.
    private var clusters: [String: ClusterState] = [:]

    /// UserDefaults key for the persisted cluster registry. Bumping the suffix
    /// invalidates older on-disk shapes.
    private static let clustersDefaultsKey = "ConnectionHub.clusters.v1"

    // MARK: Lifecycle

    func start() {
        guard !wantsToListen else { return }
        wantsToListen = true
        startLocalHub()
    }

    func stop() {
        wantsToListen = false
        lock.lock()
        if hostingLocalHub { persistClustersLocked() }
        lock.unlock()
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        budgetTimer?.cancel()
        budgetTimer = nil
        listener?.cancel()
        listener = nil
        lock.lock()
        let conns = peers.values.map { $0.connection }
        let strandedBrowserRequests = browserRequests.values.map { $0.completion }
        browserRequests.removeAll()
        peers.removeAll()
        hostingLocalHub = false
        lock.unlock()
        for conn in conns { conn.cancel() }
        for completion in strandedBrowserRequests { completion(.failure("browser-unavailable")) }
    }

    /// Mac Vault is the only hub: it listens on the fixed local port. Only one
    /// Mac Vault runs (the app refuses a second copy at launch); if the port is
    /// still held — a quitting copy — the listen is simply tried again.
    private func startLocalHub() {
        guard wantsToListen, listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(NWProtocolWebSocket.Options(), at: 0)
        guard let port = NWEndpoint.Port(rawValue: VaultRuntimeEnvironment.current.hubPort),
              let listener = try? NWListener(using: parameters, on: port) else {
            retryListenLater()
            return
        }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, self.listener === listener else { return }
            switch state {
            case .ready:
                self.lock.lock()
                self.hostingLocalHub = true
                // Links (and their running budgets) survive a restart.
                if self.clusters.isEmpty { self.restoreClustersLocked() }
                self.lock.unlock()
                self.startBudgetTimer()
            case .failed:
                self.listener?.cancel()
                self.listener = nil
                self.lock.lock()
                self.hostingLocalHub = false
                self.lock.unlock()
                self.retryListenLater()
            default:
                break
            }
        }
        listener.start(queue: queue)
    }

    private func retryListenLater() {
        guard wantsToListen else { return }
        reconnectWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.startLocalHub() }
        reconnectWorkItem = work
        queue.asyncAfter(deadline: .now() + 3, execute: work)
    }

    private func startBudgetTimer() {
        budgetTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let hosting = self.hostingLocalHub
            self.lock.unlock()
            guard hosting else { return }
            self.rollSharedBudgets(nowMs: Date().timeIntervalSince1970 * 1000)
            self.lock.lock()
            self.persistClustersLocked()
            self.lock.unlock()
        }
        budgetTimer = timer
        timer.resume()
    }

    /// Starts a new period for every linked fixed budget whose period ended,
    /// counts every shared snooze that finished, and tells the members.
    func rollSharedBudgets(nowMs: Double) {
        lock.lock()
        var changed: [[String: Any]] = []
        for cluster in clusters.values {
            let rolled = rollBudgetLocked(cluster, nowMs: nowMs)
            let counted = Self.countSnoozeLocked(cluster, nowMs: nowMs)
            if rolled || counted { changed.append(clusterJSONObject(cluster)) }
        }
        lock.unlock()
        for snapshot in changed { broadcastCluster(snapshot) }
    }

    /// Caller must hold `lock`. The hub is the only authority over a linked
    /// group's budget period (members adopt it; they never reset it). When the
    /// shared period has ended, the total restarts at 0 from the next grid
    /// start — the same rule every program uses locally (UsageBudget). A rolling
    /// limit has no period (its minutes age out), so it is left alone.
    @discardableResult
    private func rollBudgetLocked(_ cluster: ClusterState, nowMs: Double) -> Bool {
        guard cluster.sharedUsageResetAtMs > 0,
              (cluster.sharedScalars["rollingLimit"] as? Bool) != true else { return false }
        let start = Self.sharedPeriodStartMs(anchorMs: cluster.sharedUsageResetAtMs, scalars: cluster.sharedScalars, nowMs: nowMs)
        guard start > cluster.sharedUsageResetAtMs else { return false }
        cluster.sharedUsageMs = 0
        cluster.sharedUsageResetAtMs = start.rounded(.down)
        // A fresh period: a member's absolute total from the old one must not
        // seed it back.
        cluster.usageSeeded = true
        return true
    }

    /// Caller must hold `lock`. Adds the shared snooze's snoozed time to the
    /// link's total once, when it has finished (or is being replaced).
    @discardableResult
    private static func countSnoozeLocked(_ cluster: ClusterState, nowMs: Double, replacing: Bool = false) -> Bool {
        let entry = cluster.sharedSnooze
        guard let start = (entry["startsAtMs"] as? NSNumber)?.doubleValue,
              let until = (entry["untilMs"] as? NSNumber)?.doubleValue,
              start != cluster.snoozeCountedStartMs,
              replacing || nowMs >= until else { return false }
        cluster.sharedSnoozeTotalMs += max(0, min(until, nowMs) - start)
        cluster.snoozeCountedStartMs = start
        return true
    }

    static func sharedPeriodStartMs(anchorMs: Double, scalars: [String: Any], nowMs: Double) -> Double {
        let policy = BlockGroup(
            id: "", groupType: .site, name: "", enabled: true, mode: .afterMinutes,
            allowedMinutes: 0,
            resetIntervalHours: (scalars["resetIntervalHours"] as? NSNumber)?.doubleValue ?? 24,
            resetAtMidnight: (scalars["resetAtMidnight"] as? Bool) == true
        )
        return UsageBudget.periodStartMs(anchorMs: anchorMs, group: policy, nowMs: nowMs)
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
        conn.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            if Self.isWebSocketClose(context) {
                self.removePeer(key)
                conn.cancel()
                return
            }
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
                conn.cancel()
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
            // Verify against the classifier's file-based hub secret — the one the
            // Native Messaging host hands the browser and the classifier client
            // uses — so this hub (the sole host) accepts them. (Both modules
            // declare LocalHubAuthentication; qualify the shared-secret source.)
            let secret = try? VaultClassifierBridge.LocalHubAuthentication.sharedSecret()
            if let reason = Self.helloRejectionReason(obj, challenge: challenge, secret: secret) {
                rejectAndClose(conn, reason: reason)
                return
            }
            let program = (obj["program"] as? String) ?? "browser"
            lock.lock()
            let connectedPrograms = peers.values.filter { $0.connected }.map(\.program)
            let duplicate = Self.isDuplicateBrowser(program, connectedPrograms: connectedPrograms)
            if !duplicate {
                peers[key]?.program = program
                peers[key]?.connected = true
            }
            lock.unlock()
            if duplicate {
                rejectAndClose(conn, reason: "duplicate-program")
                return
            }
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
        case "group-sync":
            lock.lock()
            let prog = peers[key]?.program ?? ((obj["program"] as? String) ?? "")
            lock.unlock()
            applySync(
                program: prog,
                groupName: (obj["groupName"] as? String) ?? "",
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
        case "classifier-broadcast":
            lock.lock()
            let program = peers[key]?.program ?? ""
            lock.unlock()
            routeClassifierBroadcast(from: key, program: program, object: obj)
        case "browser-response":
            lock.lock()
            let program = peers[key]?.program ?? ""
            lock.unlock()
            routeBrowserResponse(from: key, program: program, object: obj)
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

        // The Activity ops are handled by the hub host itself (it owns the store)
        // rather than relayed to the classifier peer.
        if Self.activityRequestOperations.contains(operation) {
            lock.lock(); let source = peers[key]?.connection; lock.unlock()
            guard let source else { return }
            handleActivityRequest(source: source, requestID: requestID, operation: operation, body: body)
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
        queue.asyncAfter(deadline: .now() + .seconds(Self.classifierRelayTimeoutSeconds)) { [weak self] in
            self?.expireClassifierRequest(requestID)
        }
    }

    /// Handles an Activity op locally (the hub host owns the store; see
    /// ACTIVITY-LOG.md §5) and replies on the same classifier-response channel the
    /// extension already awaits. `activity-record` stores browser records (the
    /// store is the privacy backstop — a disabled category writes nothing);
    /// `activity-settings` gets, or merges-and-sets, the recording settings.
    private func handleActivityRequest(source: NWConnection, requestID: String, operation: String, body: [String: Any]) {
        guard let store = activityStore else {
            send(source, dict: ["kind": "classifier-response", "requestID": requestID, "operation": operation, "error": "activity-unavailable"])
            return
        }
        switch operation {
        case "activity-record":
            let settings = store.loadSettings()
            var stored = 0
            for record in ActivityWire.records(from: body) where store.record(record, settings: settings) { stored += 1 }
            if let icons = body["icons"] as? [String: String] { store.mergeWebIcons(icons) }
            send(source, dict: ["kind": "classifier-response", "requestID": requestID, "operation": operation, "body": ["stored": stored]])
        case "activity-settings":
            if let settingsBody = body["settings"] as? [String: Any] {
                store.saveSettings(ActivityWire.merged(store.loadSettings(), with: settingsBody))
            }
            send(source, dict: ["kind": "classifier-response", "requestID": requestID, "operation": operation, "body": ["settings": ActivityWire.settingsPayload(store.loadSettings())]])
        default:
            send(source, dict: ["kind": "classifier-response", "requestID": requestID, "operation": operation, "error": "unsupported-activity-op"])
        }
    }

    /// Relays an unsolicited classifier push (a completed classification) to
    /// every connected browser peer. Fire-and-forget: no correlation state, and
    /// an invalid frame is dropped rather than disconnecting the classifier.
    private func routeClassifierBroadcast(from key: ObjectIdentifier, program: String, object: [String: Any]) {
        guard program == "classifier",
              let operation = object["operation"] as? String,
              ["video-tags-updated"].contains(operation),
              let body = object["body"] as? [String: Any],
              JSONSerialization.isValidJSONObject(body),
              let bodyData = try? JSONSerialization.data(withJSONObject: body),
              bodyData.count <= Self.maxClassifierBodyBytes else {
            return
        }
        lock.lock()
        let browsers = peers.values
            .filter { $0.connected && Self.browserPrograms.contains($0.program) }
            .map(\.connection)
        lock.unlock()
        for conn in browsers {
            send(conn, dict: ["kind": "classifier-broadcast", "operation": operation, "body": body])
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
        guard let classifier = peers[key] else {
            lock.unlock()
            return
        }
        let pending = classifierRequests[requestID]
        switch Self.classifierResponseCorrelation(
            pending: pending,
            classifierPeerID: classifier.id,
            sourcePeerID: sourcePeerID,
            operation: operation
        ) {
        case .expired:
            // A structurally valid response may arrive after the bounded relay
            // timeout. It no longer has a destination, but it is not a protocol
            // violation and must not disconnect the authenticated classifier.
            lock.unlock()
            return
        case .mismatched:
            lock.unlock()
            rejectAndClose(classifier.connection, reason: "unmatched-classifier-response")
            return
        case .matched:
            break
        }
        guard let pending else {
            lock.unlock()
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

    // MARK: Browser relay (in-process MCP server → connected browser peer)

    /// Relays a bounded request to a connected browser peer and calls `completion`
    /// with its response. Called by the in-process MCP server that runs inside the
    /// hub host, so the initiator is trusted and never a socket peer. Fails fast
    /// when this app isn't hosting, when there is no browser (or an ambiguous set
    /// of browsers) to target, on overflow, or after the relay timeout. The
    /// completion always runs exactly once (inline on the fast-fail paths, or on
    /// the hub queue once a response, timeout, or disconnect resolves the relay).
    func sendBrowserRequest(
        operation: String,
        body: [String: Any],
        targetProgram: String? = nil,
        completion: @escaping (BrowserRelayResult) -> Void
    ) {
        if let reason = Self.browserRequestRejectionReason(operation: operation, body: body) {
            completion(.failure(reason))
            return
        }
        lock.lock()
        guard hostingLocalHub else {
            lock.unlock()
            completion(.failure("browser-relay-requires-host"))
            return
        }
        // `targetProgram` names a browser program (chrome, edge, …) or, when two
        // instances of the same program are connected (the owner's Chrome and a
        // test rig's Chromium), one peer id.
        let browsers = peers.values.filter {
            $0.connected && Self.browserPrograms.contains($0.program)
                && (targetProgram == nil || $0.program == targetProgram
                    || $0.id.caseInsensitiveCompare(targetProgram ?? "") == .orderedSame)
        }
        guard let target = browsers.first else {
            lock.unlock()
            completion(.failure("browser-unavailable"))
            return
        }
        // With two browsers connected the caller must name one, so a request is
        // never silently answered by an arbitrary browser.
        guard browsers.count == 1 else {
            let choices = browsers.map { "\($0.program) \($0.id)" }.sorted().joined(separator: ", ")
            lock.unlock()
            completion(.failure("browser-ambiguous: \(choices)"))
            return
        }
        guard browserRequests.count < Self.maxBrowserRequests else {
            lock.unlock()
            completion(.failure("browser-busy"))
            return
        }
        let requestID = UUID().uuidString
        browserRequests[requestID] = BrowserRequest(
            requestID: requestID,
            browserPeerID: target.id,
            operation: operation,
            completion: completion
        )
        let connection = target.connection
        lock.unlock()
        send(connection, dict: [
            "kind": "browser-request",
            "requestID": requestID,
            "operation": operation,
            "body": body,
        ])
        queue.asyncAfter(deadline: .now() + .seconds(Self.browserRelayTimeoutSeconds)) { [weak self] in
            self?.expireBrowserRequest(requestID)
        }
    }

    private func routeBrowserResponse(from key: ObjectIdentifier, program: String, object: [String: Any]) {
        guard Self.browserPrograms.contains(program),
              Self.browserResponseRejectionReason(object) == nil,
              let requestID = object["requestID"] as? String,
              let operation = object["operation"] as? String else {
            lock.lock(); let responder = peers[key]?.connection; lock.unlock()
            if let responder { rejectAndClose(responder, reason: "invalid-browser-response") }
            return
        }
        lock.lock()
        guard let responder = peers[key] else { lock.unlock(); return }
        let pending = browserRequests[requestID]
        switch Self.browserResponseCorrelation(
            pending: pending,
            browserPeerID: responder.id,
            operation: operation
        ) {
        case .expired:
            // A late but valid response after the relay timeout is not a protocol
            // violation; it simply has no destination left.
            lock.unlock()
            return
        case .mismatched:
            lock.unlock()
            rejectAndClose(responder.connection, reason: "unmatched-browser-response")
            return
        case .matched:
            break
        }
        guard let pending else { lock.unlock(); return }
        browserRequests.removeValue(forKey: requestID)
        lock.unlock()
        if let responseBody = object["body"] as? [String: Any] {
            pending.completion(.success(responseBody))
        } else {
            pending.completion(.failure((object["error"] as? String) ?? "browser-error"))
        }
    }

    private func expireBrowserRequest(_ requestID: String) {
        lock.lock()
        let pending = browserRequests.removeValue(forKey: requestID)
        lock.unlock()
        pending?.completion(.failure("browser-timeout"))
    }

    private func removePeer(_ key: ObjectIdentifier) {
        lock.lock()
        let removed = peers.removeValue(forKey: key)
        let program = removed?.program
        let removedPeerID = removed?.id
        // A closed browser no longer has a response destination, so release its
        // routes immediately. A closed classifier also fails every route it
        // owns and reports that failure to each browser that is still present.
        let affectedRequests = classifierRequests.filter { _, pending in
            guard let removedPeerID else { return false }
            return pending.sourcePeerID == removedPeerID
                || pending.classifierPeerID == removedPeerID
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
        // A dropped browser peer strands every relay routed to it; fail those
        // completions so the in-process MCP caller never hangs.
        let strandedBrowserRequests = browserRequests.filter { $0.value.browserPeerID == removedPeerID }
        for (requestID, _) in strandedBrowserRequests { browserRequests.removeValue(forKey: requestID) }
        let strandedBrowserCompletions = strandedBrowserRequests.values.map { $0.completion }
        let existed = removed != nil
        lock.unlock()
        for completion in strandedBrowserCompletions { completion(.failure("browser-unavailable")) }
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
            // Membership is pinned to the group *instance* this program linked:
            // it stays only while that instance is present under the same name.
            // A delete removes the id; a re-create under the same name yields a
            // NEW id (so it can't silently re-join); a rename decouples. Frozen
            // groups stay in the roster, so a freeze never decouples. A link
            // without a pinned id (from before pinning) is dropped here and
            // re-forms, pinned, through auto-link.
            let pinnedId = cluster.memberGroupIds[program] ?? ""
            let stillPresent = !pinnedId.isEmpty
                && infos.contains { $0.id == pinnedId && Self.sameName($0.name, cluster.groupName) }
            if stillPresent { continue }
            cluster.members.remove(program)
            cluster.memberGroupIds.removeValue(forKey: program)
            cluster.contributed.remove(program)
            if cluster.members.count < 2 {
                clusters.removeValue(forKey: cluster.id)
                cluster.members.removeAll()
            }
            changed = true
            snapshots.append(clusterJSONObject(cluster))
        }
        // Auto-link: after pruning, (re)form clusters for same-named groups now
        // present on two or more programs. There is no manual connect step.
        let added = autoLinkClustersLocked()
        if !added.isEmpty {
            changed = true
            snapshots.append(contentsOf: added)
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

    /// Caller must hold `lock`. Auto-forms clusters: every group name present on
    /// two or more programs becomes one cluster containing all programs that have
    /// that group. Same-named groups link with no manual step; membership is pinned
    /// to the specific instance so a delete/re-create can't silently re-join.
    /// Returns snapshots of the clusters it changed.
    private func autoLinkClustersLocked() -> [[String: Any]] {
        // name -> program -> (pinned group id, locked) — first instance per
        // program. Names match case-insensitively (the editors keep names
        // unique that way).
        var byName: [String: [String: (id: String, frozen: Bool)]] = [:]
        var displayName: [String: String] = [:]
        for (program, infos) in rosters {
            for info in infos where !info.name.isEmpty {
                let key = Self.nameKey(info.name)
                if displayName[key] == nil { displayName[key] = info.name }
                if byName[key]?[program] == nil {
                    byName[key, default: [:]][program] = (info.id, info.frozen)
                }
            }
        }
        var snapshots: [[String: Any]] = []
        for (key, entries) in byName where entries.count >= 2 {
            let existing = clusters.values.first { Self.nameKey($0.groupName) == key }
            // Owner 2026-09-26: a locked group cannot join a link, and a locked
            // link takes no one new — linking happens only between unlocked
            // groups; linked groups then lock together. A member already in
            // the link with the same group stays, locked or not.
            let linkLocked = existing.map { Self.lockIsLocked($0.sharedLock) } ?? false
            let eligible = entries.filter { program, entry in
                if let existing, existing.members.contains(program), existing.memberGroupIds[program] == entry.id { return true }
                return !entry.frozen && !linkLocked
            }
            guard eligible.count >= 2 || (existing != nil && !eligible.isEmpty) else { continue }
            let cluster = existing ?? {
                let created = ClusterState(id: UUID().uuidString, groupName: displayName[key] ?? key)
                clusters[created.id] = created
                return created
            }()
            var mutated = false
            for (program, entry) in eligible {
                if cluster.members.insert(program).inserted { mutated = true }
                if !entry.id.isEmpty && cluster.memberGroupIds[program] != entry.id {
                    cluster.memberGroupIds[program] = entry.id
                    mutated = true
                }
            }
            if mutated { snapshots.append(clusterJSONObject(cluster)) }
        }
        return snapshots
    }

    /// group-actions.js LOCK_FIELDS: the fields of the one lock unit.
    static let lockFields = ["lockedAtMs", "lockWaitHours", "parentalPasswordHash", "parentalPasswordSalt", "lockVersion"]

    /// A lock unit (group-actions.js) is locked when it has a lock time.
    static func lockIsLocked(_ unit: [String: Any]) -> Bool {
        (unit["lockedAtMs"] as? NSNumber) != nil
    }

    /// Folds one member's contribution into the cluster's shared state and, if the
    /// shared snapshot changed, broadcasts it. This is the heart of the sync
    /// engine: scalars and scope lines are latest-edit-wins (a member's FIRST
    /// contribution unions its entries into the shared lines, so two groups that
    /// existed separately keep both sides' entries when they link), and the usage
    /// counter is a delta accumulator (the Mac is the budget authority).
    func applySync(program: String, groupName: String, contribution: [String: Any], ts: Double) {
        guard !program.isEmpty, !groupName.isEmpty else { return }
        lock.lock()
        guard let cluster = clusters.values.first(where: {
            Self.sameName($0.groupName, groupName) && $0.members.contains(program)
        }) else {
            lock.unlock()
            return
        }

        let before = clusterJSONObject(cluster)

        // Definition contributions (scalars / scopes) only update when the
        // message actually carries them. Lightweight usage-only pings (sent by
        // the browser background when its popup is closed) must NOT clobber the
        // member's stored contribution.
        let scalarsPayload = contribution["scalars"] as? [String: Any]
        let scopesPayload = contribution["scopes"] as? [[String: Any]]
        let carriesConfig = scalarsPayload != nil || scopesPayload != nil
        if carriesConfig {
            let firstContribution = !cluster.contributed.contains(program)
            let priority = (contribution["priority"] as? Bool) ?? false
            let wins = priority || ts >= cluster.sharedTs
            let budgetBefore = Self.budgetShape(cluster.sharedScalars)
            cluster.contributed.insert(program)

            // Scalars: last writer wins, except the link initiator forces its
            // settings to win the first merge (priority flag).
            if let scalars = scalarsPayload {
                if priority {
                    cluster.sharedScalars = scalars
                    cluster.sharedTs = max(cluster.sharedTs, ts) + 1
                } else if ts >= cluster.sharedTs {
                    cluster.sharedScalars = scalars
                    cluster.sharedTs = ts
                }
            }
            // A changed budget (the same fields that restart an unlinked group's
            // budget in the editor) restarts the shared budget for every device:
            // linked groups are one group.
            if !budgetBefore.isEmpty, Self.budgetShape(cluster.sharedScalars) != budgetBefore {
                cluster.sharedUsageMs = 0
                // The new period starts on the group's own grid (with midnight
                // re-anchoring that is today's grid, not this instant), as every
                // program computes it — else each would see a different period.
                let nowMs = (Date().timeIntervalSince1970 * 1000).rounded(.down)
                cluster.sharedUsageResetAtMs = Self.sharedPeriodStartMs(anchorMs: nowMs, scalars: cluster.sharedScalars, nowMs: nowMs).rounded(.down)
                cluster.sharedBuckets = [:]
                cluster.usageSeeded = true
                cluster.bucketsSeeded = true
            }
            // Entries: a member's first contribution brings its own entries into
            // the shared definition (union by entry, the newcomer's version of a
            // shared entry wins); afterwards the whole line list is latest-edit-
            // wins, since every member edits the one shared definition.
            if let scopes = scopesPayload {
                if firstContribution {
                    cluster.sharedScopes = Self.unionScopes(cluster.sharedScopes, incoming: scopes)
                } else if wins {
                    cluster.sharedScopes = scopes
                }
            }

            // The link's one lock is versioned (group-actions.js): the first
            // member's lock starts it; afterwards a change is taken only when
            // it was made on top of the current version (compare-and-set). A
            // joining member never changes it — it adopts the link's lock.
            if let lock = contribution["lock"] as? [String: Any] {
                let incoming = (lock["lockVersion"] as? NSNumber)?.intValue ?? 0
                let base = (contribution["lockBase"] as? NSNumber)?.intValue ?? 0
                if let current = (cluster.sharedLock["lockVersion"] as? NSNumber)?.intValue {
                    if !firstContribution, base == current, incoming > current { cluster.sharedLock = lock }
                } else {
                    cluster.sharedLock = lock
                }
            }
        }

        // Usage: shared budget via delta accrual. Members report increments
        // (usageDeltaMs) measured at their own accrual point — the browser's page
        // heartbeat and the Mac's frontmost-app sampler. Because we only ever ADD
        // reported increments (never adopt an absolute), folding the broadcast
        // total back into each member's local counter produces no echo and no
        // double counting, and there is no "decrease == reset" race. A newer
        // reset anchor rolls the whole budget over.
        // The hub owns the shared period: a member's anchor only seeds it when
        // the hub has none yet; from then on only the hub starts a new period.
        if cluster.sharedUsageResetAtMs == 0, let anchor = contribution["usageResetAtMs"] as? Double, anchor > 0 {
            cluster.sharedUsageResetAtMs = anchor.rounded(.down)
        }
        rollBudgetLocked(cluster, nowMs: Date().timeIntervalSince1970 * 1000)
        // Time a browser counted while the hub was away arrives tagged with
        // its period: added only when that period is still the current one.
        let deltaPeriod = (contribution["usageDeltaAnchorMs"] as? NSNumber)?.doubleValue
        if let delta = contribution["usageDeltaMs"] as? Double, delta != 0,
           deltaPeriod == nil || deltaPeriod!.rounded(.down) == cluster.sharedUsageResetAtMs.rounded(.down) {
            cluster.sharedUsageMs = max(0, cluster.sharedUsageMs + delta)
            cluster.usageSeeded = true
        } else if !cluster.usageSeeded,
                  let seed = contribution["usageMs"] as? Double,
                  seed > cluster.sharedUsageMs {
            // No real delta yet: seed the budget from the largest existing member
            // counter so a group that already had usage keeps it when it links.
            cluster.sharedUsageMs = seed
        }
        applyBucketContributionLocked(cluster, contribution)

        // Active snooze: newest start wins. A member only carries `snoozeTs` when
        // it actually has an active/cooling snooze entry, so usage-only pings and
        // members without a snooze never clobber a snooze started elsewhere.
        let nowMs = Date().timeIntervalSince1970 * 1000
        if let snoozeTs = contribution["snoozeTs"] as? Double, snoozeTs > 0 {
            if snoozeTs > cluster.sharedSnoozeTs {
                // A new snooze replaces a finished one: count that one first.
                Self.countSnoozeLocked(cluster, nowMs: nowMs, replacing: true)
                cluster.sharedSnoozeTs = snoozeTs
                cluster.sharedSnooze = (contribution["snooze"] as? [String: Any]) ?? [:]
            }
        }
        Self.countSnoozeLocked(cluster, nowMs: nowMs)

        // Persist only on config-bearing syncs (scalars/scopes/snooze), not
        // on per-tick usage pings, so the on-disk registry tracks structural and
        // settings changes without hammering the disk every second.
        if carriesConfig { persistClustersLocked() }

        let after = clusterJSONObject(cluster)
        lock.unlock()

        if !NSDictionary(dictionary: before).isEqual(to: after) {
            broadcastCluster(after)
        }
    }

    /// The entry a scope line belongs to: "apps" for the app list, "site" for
    /// the website list, else its platform id.
    static func scopeEntryKey(_ line: [String: Any]) -> String {
        if (line["surface"] as? String) == "apps" { return "apps" }
        if let platform = line["platform"] as? String, !platform.isEmpty { return platform }
        return "site"
    }

    /// Union of two line lists by entry: entries only `existing` names are kept,
    /// entries `incoming` names come from `incoming`. Line ids are renumbered per
    /// surface so the merged list has unique ids.
    static func unionScopes(_ existing: [[String: Any]], incoming: [[String: Any]]) -> [[String: Any]] {
        let incomingKeys = Set(incoming.map(scopeEntryKey))
        let merged = existing.filter { !incomingKeys.contains(scopeEntryKey($0)) } + incoming
        var counters: [String: Int] = [:]
        return merged.map { line in
            let surface = (line["surface"] as? String) ?? "site"
            counters[surface, default: 0] += 1
            var copy = line
            copy["id"] = "\(surface)-\(counters[surface]!)"
            return copy
        }
    }

    static func nameKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func sameName(_ a: String, _ b: String) -> Bool { nameKey(a) == nameKey(b) }

    /// The settings whose change restarts a budget (popup `modeChanged` /
    /// `resetIntervalChanged`); empty when nothing is shared yet.
    static func budgetShape(_ scalars: [String: Any]) -> String {
        guard !scalars.isEmpty else { return "" }
        return ["mode", "resetIntervalHours", "resetAtMidnight", "rollingLimit"]
            .map { "\(scalars[$0] ?? "")" }.joined(separator: "|")
    }

    /// Mirror of group-scopes.js `SYNC_SCALAR_FIELDS` (a test keeps the two equal):
    /// the policy settings a linked group shares.
    static let syncScalarFields = [
        "mode", "allowedMinutes", "resetIntervalHours", "resetAtMidnight", "rollingLimit",
        "allowSnooze", "snoozeMinutes", "snoozeActivationDelayMinutes", "snoozeCooldownMinutes", "snoozeConfirmations",
        "activeDays", "timeWindowsText",
        "fallbackUrl", "pauseSeconds",
    ]

    /// The Mac's roster last given to the hub (canonical JSON).
    private var lastLocalRoster = ""

    /// Mac group id -> the stored definition last seen (canonical JSON).
    private var localDefinitionSeen: [String: String] = [:]

    /// Mac Vault is a member of its links whether or not its editor window is
    /// open. Joining a link, it contributes its stored definition (merged like
    /// any first contribution, so its Apps entry joins the shared lines).
    /// Afterwards it sends a change only when the stored group actually changed
    /// on the Mac — the editor, quick add, an AI tool — and differs from the
    /// shared definition; a copy that merely lags behind another device's newer
    /// edit is never sent over it.
    func contributeLocalDefinitions(document: [String: Any], nowMs: Double) {
        let groups = document["blockedGroups"] as? [[String: Any]] ?? []
        // The Mac's own group list comes from its store, every tick — so a
        // group created, renamed, frozen or deleted with the window closed (by
        // the "+" or a tool) links or leaves its link like any other.
        let roster: [[String: Any]] = groups.compactMap { group in
            guard let id = group["id"] as? String else { return nil }
            return ["id": id, "name": (group["name"] as? String) ?? "", "frozen": WebStoreDocument.isLocked(group)]
        }
        let rosterKey = Self.canonicalJSON(roster)
        if rosterKey != lastLocalRoster {
            lastLocalRoster = rosterKey
            setRoster(program: Self.localProgram, groups: roster)
        }
        guard !groups.isEmpty else { return }
        var frames: [[String: Any]] = []
        lock.lock()
        for cluster in clusters.values where cluster.members.contains(Self.localProgram) {
            let pinned = cluster.memberGroupIds[Self.localProgram] ?? ""
            guard !pinned.isEmpty, let group = groups.first(where: { ($0["id"] as? String) == pinned }),
                  let groupID = group["id"] as? String else { continue }
            // A snooze started or ended here (a tool, the engine) reaches the
            // link as the newest change, editor window or not.
            if let entry = (document["groupSnoozes"] as? [String: Any])?[groupID] as? [String: Any] {
                let changedAt = Self.snoozeChangeTs(entry)
                if changedAt > cluster.sharedSnoozeTs {
                    frames.append(["kind": "group-sync", "program": Self.localProgram, "groupName": cluster.groupName,
                                   "ts": 0, "snooze": entry, "snoozeTs": changedAt])
                }
            }
            var scalars: [String: Any] = [:]
            for field in Self.syncScalarFields where group[field] != nil { scalars[field] = group[field] }
            let scopes = group["scopes"] as? [[String: Any]] ?? []
            // The lock travels as its own versioned unit (group-actions.js).
            var lockUnit: [String: Any] = [:]
            if group["lockVersion"] != nil {
                for field in Self.lockFields { lockUnit[field] = group[field] ?? NSNull() }
            }
            let key = Self.canonicalJSON(["scalars": scalars, "scopes": scopes, "lock": lockUnit])
            let previous = localDefinitionSeen[groupID]
            if previous == key { continue }
            localDefinitionSeen[groupID] = key
            let joined = cluster.contributed.contains(Self.localProgram)
            var ts: Double
            if !joined {
                ts = 0 // joining: its lines are unioned; its settings never beat a newer edit
            } else if previous == nil {
                continue // first sight in this process of an already-contributed group: not an edit
            } else if Self.canonicalJSON(Self.syncScalarFields.reduce(into: [String: Any]()) { $0[$1] = cluster.sharedScalars[$1] })
                        == Self.canonicalJSON(Self.syncScalarFields.reduce(into: [String: Any]()) { $0[$1] = scalars[$1] })
                        && Self.canonicalJSON(cluster.sharedScopes) == Self.canonicalJSON(scopes)
                        && (lockUnit.isEmpty || Self.canonicalJSON(lockUnit) == Self.canonicalJSON(Self.lockFields.reduce(into: [String: Any]()) { $0[$1] = cluster.sharedLock[$1] ?? NSNull() })) {
                continue // the file caught up with the shared definition (adopted), not an edit
            } else {
                ts = nowMs
            }
            var frame: [String: Any] = ["kind": "group-sync", "program": Self.localProgram, "groupName": cluster.groupName, "ts": ts,
                                        "scalars": scalars]
            if !scopes.isEmpty { frame["scopes"] = scopes }
            if !lockUnit.isEmpty {
                frame["lock"] = lockUnit
                frame["lockBase"] = (group["lockSyncedVersion"] as? NSNumber)?.intValue ?? 0
            }
            frames.append(frame)
        }
        lock.unlock()
        for frame in frames { submitBridgeFrame(frame) }
    }

    static func canonicalJSON(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// The stored document with each linked group's live shared definition
    /// (policy scalars and entry lines) and any newer shared snooze laid over
    /// it — what the editor would adopt if it were open. Mac enforcement reads
    /// through this, so a closed editor window never leaves the Mac enforcing a
    /// stale definition or missing a snooze started on another device.
    func overlayShared(onto document: [String: Any]) -> [String: Any] {
        var groups = document["blockedGroups"] as? [[String: Any]] ?? []
        guard !groups.isEmpty else { return document }
        var snoozes = document["groupSnoozes"] as? [String: Any] ?? [:]
        var snoozeTotals = document["groupSnoozeTotalsMs"] as? [String: Any] ?? [:]
        var changed = false
        lock.lock()
        for cluster in clusters.values where cluster.members.contains(Self.localProgram) {
            let pinned = cluster.memberGroupIds[Self.localProgram] ?? ""
            guard !pinned.isEmpty, let index = groups.firstIndex(where: { ($0["id"] as? String) == pinned }) else { continue }
            for (field, value) in cluster.sharedScalars { groups[index][field] = value }
            if !cluster.sharedScopes.isEmpty { groups[index]["scopes"] = cluster.sharedScopes }
            if !cluster.sharedLock.isEmpty {
                for (field, value) in cluster.sharedLock { groups[index][field] = value }
                groups[index]["lockSyncedVersion"] = cluster.sharedLock["lockVersion"]
            }
            changed = true
            if cluster.sharedSnoozeTs > 0, !cluster.sharedSnooze.isEmpty,
               let id = groups[index]["id"] as? String,
               cluster.sharedSnoozeTs > Self.snoozeChangeTs(snoozes[id] as? [String: Any]) {
                snoozes[id] = cluster.sharedSnooze
            }
            // The link's snooze total is the hub's count (each snooze once).
            if cluster.sharedSnoozeTotalMs > 0, let id = groups[index]["id"] as? String {
                snoozeTotals[id] = cluster.sharedSnoozeTotalMs
            }
        }
        lock.unlock()
        guard changed else { return document }
        var overlaid = document
        overlaid["blockedGroups"] = groups
        overlaid["groupSnoozes"] = snoozes
        overlaid["groupSnoozeTotalsMs"] = snoozeTotals
        return overlaid
    }

    /// When a snooze entry last changed (started or ended): the newest change
    /// wins across linked devices. Entries from before 2026-09-26 carry only
    /// their start.
    static func snoozeChangeTs(_ entry: [String: Any]?) -> Double {
        guard let entry else { return 0 }
        if let changed = (entry["changedAtMs"] as? NSNumber)?.doubleValue, changed > 0 { return changed }
        return (entry["startsAtMs"] as? NSNumber)?.doubleValue ?? 0
    }

    /// Called by the in-process macOS enforcer when it accrues (or rolls over)
    /// usage for one of its groups. A no-op unless the Mac's group is actually
    /// in a cluster (applySync ignores unknown clusters). `deltaMs` is the time
    /// just accrued for the frontmost blocked app; `resetAtMs` is the group's
    /// current reset anchor (a newer anchor rolls the shared budget over).
    func reportLocalUsage(
        groupID: String,
        deltaMs: Double,
        resetAtMs: Double,
        seedMs: Double? = nil,
        bucketDeltas: [Double: Double] = [:],
        seedBuckets: [Double: Double]? = nil
    ) {
        var contribution: [String: Any] = ["usageResetAtMs": resetAtMs]
        if deltaMs != 0 { contribution["usageDeltaMs"] = deltaMs }
        if !bucketDeltas.isEmpty { contribution["usageBuckets"] = UsageBudget.bucketJSON(bucketDeltas) }
        if let seedBuckets { contribution["usageBucketsSeed"] = UsageBudget.bucketJSON(seedBuckets) }
        // A seed is the Mac's absolute local total, used by the hub only until the
        // first real delta arrives (it adopts the largest member total) so prior
        // Mac usage survives joining a cluster.
        if let seedMs { contribution["usageMs"] = seedMs }
        guard let cluster = localCluster(groupID: groupID) else { return }
        contribution["kind"] = "group-sync"
        contribution["program"] = Self.localProgram
        contribution["groupName"] = cluster.groupName
        contribution["ts"] = 0
        submitBridgeFrame(contribution)
    }

    /// The hub-authoritative shared usage budget for a Mac-clustered Default
    /// group, or nil when the Mac's group isn't in any cluster. The in-process
    /// enforcer folds this total back into its local timer so the Mac display +
    /// enforcement reflect time spent on every linked member (e.g. browser
    /// website time), not just the Mac's own frontmost-app time.
    func sharedUsage(groupID: String) -> (ms: Double, resetAtMs: Double, buckets: [Double: Double])? {
        guard let cluster = localCluster(groupID: groupID) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return (cluster.sharedUsageMs, cluster.sharedUsageResetAtMs, cluster.sharedBuckets)
    }

    /// The link a Mac group belongs to — matched by its pinned id, as the
    /// overlay and the contributions match it.
    private func localCluster(groupID: String) -> ClusterState? {
        guard !groupID.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return clusters.values.first { $0.members.contains(Self.localProgram) && $0.memberGroupIds[Self.localProgram] == groupID }
    }

    /// Folds a member's rolling usage into the cluster: `usageBuckets` are
    /// per-minute increments; `usageBucketsSeed` is a member's absolute history,
    /// used (max per minute) only until the first real increment arrives so a
    /// group that already had rolling usage keeps it when it links. Minutes older
    /// than any window the group can use (its interval, at least a day) are pruned.
    private func applyBucketContributionLocked(_ cluster: ClusterState, _ contribution: [String: Any]) {
        if let deltas = UsageBudget.parseBuckets(contribution["usageBuckets"]), !deltas.isEmpty {
            for (minute, delta) in deltas {
                let next = (cluster.sharedBuckets[minute] ?? 0) + delta
                cluster.sharedBuckets[minute] = next > 0 ? next : nil
            }
            cluster.bucketsSeeded = true
        } else if !cluster.bucketsSeeded, let seed = UsageBudget.parseBuckets(contribution["usageBucketsSeed"]) {
            for (minute, used) in seed where used > (cluster.sharedBuckets[minute] ?? 0) {
                cluster.sharedBuckets[minute] = used
            }
        }
        guard !cluster.sharedBuckets.isEmpty else { return }
        let intervalHours = (cluster.sharedScalars["resetIntervalHours"] as? NSNumber)?.doubleValue ?? 24
        let horizonMs = max(intervalHours, 24) * 3_600_000 + 60_000
        let cutoff = Date().timeIntervalSince1970 * 1000 - horizonMs
        cluster.sharedBuckets = cluster.sharedBuckets.filter { $0.key > cutoff }
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

    // MARK: Cluster registry — JSON-string entry points for the web bridge

    /// The Mac is itself a local endpoint: its frames are applied straight to
    /// the hub state.
    private func submitBridgeFrame(_ frame: [String: Any]) {
        switch frame["kind"] as? String {
        case "group-sync":
            applySync(
                program: Self.localProgram,
                groupName: frame["groupName"] as? String ?? "",
                contribution: frame,
                ts: frame["ts"] as? Double ?? 0
            )
        default:
            break
        }
    }

    /// Caller must hold `lock`. Persists the cluster registry — links and their
    /// running budgets — so both survive an app restart; the user only loses a
    /// link by disconnecting it. Called on config changes and by the 10 s budget
    /// timer (a write only when something changed).
    private func persistClustersLocked() {
        let arr: [[String: Any]] = clusters.values.map { c in
            [
                "id": c.id,
                "groupName": c.groupName,
                "members": Array(c.members),
                "memberGroupIds": c.memberGroupIds,
                "contributed": Array(c.contributed),
                "sharedScalars": c.sharedScalars,
                "sharedScopes": c.sharedScopes,
                "sharedLock": c.sharedLock,
                "sharedTs": c.sharedTs,
                "sharedSnooze": c.sharedSnooze,
                "sharedSnoozeTs": c.sharedSnoozeTs,
                "sharedSnoozeTotalMs": c.sharedSnoozeTotalMs,
                "snoozeCountedStartMs": c.snoozeCountedStartMs,
                "sharedUsageMs": c.sharedUsageMs,
                "sharedUsageResetAtMs": c.sharedUsageResetAtMs,
                "sharedBuckets": UsageBudget.bucketJSON(c.sharedBuckets),
                "usageSeeded": c.usageSeeded,
                "bucketsSeeded": c.bucketsSeeded
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: arr, options: [.sortedKeys]),
              data != lastPersistedClusters else { return }
        lastPersistedClusters = data
        UserDefaults.standard.set(data, forKey: ConnectionHub.clustersDefaultsKey)
    }

    /// Caller must hold `lock`. Rebuilds the cluster registry (and the running
    /// budgets) from disk when the hub starts.
    func restoreClustersLocked() {
        guard let data = UserDefaults.standard.data(forKey: ConnectionHub.clustersDefaultsKey),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return }
        for obj in arr {
            guard let id = obj["id"] as? String,
                  let groupName = obj["groupName"] as? String else { continue }
            // Registries written before 2026-09-24 carry a `groupType` and
            // per-member sites/apps pools; both are ignored (the definition is
            // re-shared by the members' next contribution).
            let cluster = ClusterState(id: id, groupName: groupName)
            if let members = obj["members"] as? [String] { cluster.members = Set(members) }
            if let ids = obj["memberGroupIds"] as? [String: String] { cluster.memberGroupIds = ids }
            // (Registries before 2026-09-26 kept each whole contribution.)
            cluster.contributed = Set(obj["contributed"] as? [String]
                ?? ((obj["contributions"] as? [String: Any]).map { Array($0.keys) } ?? []))
            if let scalars = obj["sharedScalars"] as? [String: Any] { cluster.sharedScalars = scalars }
            if let scopes = obj["sharedScopes"] as? [[String: Any]] { cluster.sharedScopes = scopes }
            if let lock = obj["sharedLock"] as? [String: Any] { cluster.sharedLock = lock }
            cluster.sharedTs = (obj["sharedTs"] as? Double) ?? 0
            if let snooze = obj["sharedSnooze"] as? [String: Any] { cluster.sharedSnooze = snooze }
            cluster.sharedSnoozeTs = (obj["sharedSnoozeTs"] as? Double) ?? 0
            cluster.sharedSnoozeTotalMs = (obj["sharedSnoozeTotalMs"] as? Double) ?? 0
            cluster.snoozeCountedStartMs = (obj["snoozeCountedStartMs"] as? Double) ?? 0
            cluster.sharedUsageMs = (obj["sharedUsageMs"] as? Double) ?? 0
            cluster.sharedUsageResetAtMs = (obj["sharedUsageResetAtMs"] as? Double) ?? 0
            cluster.sharedBuckets = UsageBudget.parseBuckets(obj["sharedBuckets"]) ?? [:]
            cluster.usageSeeded = (obj["usageSeeded"] as? Bool) ?? false
            cluster.bucketsSeeded = (obj["bucketsSeeded"] as? Bool) ?? false
            // Only restore clusters that still have ≥2 members (a 1-member
            // cluster is meaningless and would never broadcast).
            if cluster.members.count >= 2 { clusters[id] = cluster }
        }
    }

    /// Caller must hold `lock`. Programs with a live connected peer, plus the Mac
    /// host itself (always online while the hub runs). Used to flag cluster
    /// members online/offline.
    private func onlineProgramsLocked() -> Set<String> {
        Set(peers.values.filter { $0.connected && !$0.program.isEmpty }.map(\.program)).union([Self.localProgram])
    }

    /// Caller must hold `lock`. Serializes a cluster including the shared
    /// definition (scalars + scope lines) and the shared runtime (usage, snooze).
    private func clusterJSONObject(_ cluster: ClusterState) -> [String: Any] {
        let online = onlineProgramsLocked()
        let allOnline = cluster.members.allSatisfy { online.contains($0) }
        let hasShared = !cluster.sharedScalars.isEmpty || !cluster.sharedScopes.isEmpty || cluster.sharedTs > 0 || !cluster.sharedLock.isEmpty
        var dict: [String: Any] = [
            "id": cluster.id,
            "groupName": cluster.groupName,
            "allOnline": allOnline,
            "members": cluster.members.sorted().map {
                [
                    "program": $0,
                    "groupName": cluster.groupName,
                    "groupId": cluster.memberGroupIds[$0] ?? "",
                    "online": online.contains($0),
                    // False until the member sent its definition: a browser then
                    // contributes it (its lines join the link's).
                    "contributed": cluster.contributed.contains($0)
                ] as [String: Any]
            }
        ]
        if hasShared || cluster.sharedUsageMs > 0
            || !cluster.sharedBuckets.isEmpty
            || cluster.sharedSnoozeTs > 0 || cluster.sharedSnoozeTotalMs > 0 {
            var shared: [String: Any] = [
                "scalars": cluster.sharedScalars,
                "ts": cluster.sharedTs,
                "usageMs": cluster.sharedUsageMs,
                "usageResetAtMs": cluster.sharedUsageResetAtMs,
                "usageBuckets": UsageBudget.bucketJSON(cluster.sharedBuckets),
                "snooze": cluster.sharedSnooze,
                "snoozeTs": cluster.sharedSnoozeTs,
                "snoozeTotalMs": cluster.sharedSnoozeTotalMs
            ]
            // Lines appear once a member contributed them: an empty list is
            // "nothing shared yet", which members must not adopt as a deletion.
            if !cluster.sharedScopes.isEmpty { shared["scopes"] = cluster.sharedScopes }
            if !cluster.sharedLock.isEmpty { shared["lock"] = cluster.sharedLock }
            dict["shared"] = shared
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

}
#endif
