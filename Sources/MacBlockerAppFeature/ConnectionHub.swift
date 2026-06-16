#if os(macOS)
import Foundation
import Network

/// Localhost WebSocket hub for the web-app bridge.
///
/// The macOS app is the only endpoint that can listen on a socket (a browser
/// extension cannot), so it hosts this server on a fixed loopback port. Browser
/// extensions connect out to it; because the listener is loopback-only there is
/// no pairing step.
///
/// Scope: accept loopback WebSocket connections, track connected peers, route
/// cluster/group sync messages, and expose a JSON status string for the web
/// editor (polled each second + on demand).
final class ConnectionHub: ObservableObject {
    private struct Peer {
        let id: String
        var program: String
        var connected: Bool
        let connection: NWConnection
    }

    /// Process-wide hub. Owned at the app-delegate level (not by any SwiftUI
    /// view) so the server survives closing the editor window and lives for the
    /// whole app session.
    static let shared = ConnectionHub()

    private let queue = DispatchQueue(label: "macosBlocker.ConnectionHub")
    private let lock = NSLock()

    private var listener: NWListener?
    private var peers: [ObjectIdentifier: Peer] = [:]
    private var running = false
    /// Fixed loopback port for the bridge (no longer user-configurable).
    private let port = 8787
    private var lastError = ""

    // MARK: Cluster registry (per-group web-app bridge linking)

    private struct GroupInfo {
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
        /// Per-program contribution: { scalars: {...}, sites?: [...], apps?: [...] }.
        var contributions: [String: [String: Any]] = [:]
        // Hub-authoritative shared state.
        var sharedScalars: [String: Any] = [:]
        var sharedTs: Double = 0
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
        // Idempotent: a listener already bound is left untouched so we don't
        // churn (and drop peers) on repeated start calls.
        lock.lock()
        let alreadyBound = (listener != nil)
        lock.unlock()
        if alreadyBound { return }
        stop()
        lock.lock()
        self.lastError = ""
        // Restore persisted clusters once so a link survives an app/server
        // restart (members show offline until they reconnect). Only when empty
        // so a live registry is never clobbered by a stale snapshot.
        if clusters.isEmpty { restoreClustersLocked() }
        lock.unlock()

        let parameters = NWParameters.tcp
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)
        parameters.allowLocalEndpointReuse = true
        // Loopback only — never expose the hub on the LAN.
        parameters.requiredInterfaceType = .loopback

        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            setError("invalid port")
            return
        }

        do {
            let listener = try NWListener(using: parameters, on: nwPort)
            listener.newConnectionHandler = { [weak self] conn in
                self?.accept(conn)
            }
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.setRunning(true)
                case .failed(let error):
                    self?.setError("\(error)")
                    self?.stop()
                case .cancelled:
                    self?.setRunning(false)
                default:
                    break
                }
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            setError("\(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        lock.lock()
        let conns = peers.values.map { $0.connection }
        peers.removeAll()
        running = false
        lock.unlock()
        for conn in conns { conn.cancel() }
    }

    // MARK: Connections

    private func accept(_ conn: NWConnection) {
        let key = ObjectIdentifier(conn)
        lock.lock()
        peers[key] = Peer(id: UUID().uuidString, program: "", connected: false, connection: conn)
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
        receive(conn, key: key)
    }

    private func receive(_ conn: NWConnection, key: ObjectIdentifier) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.handleIncoming(conn, key: key, data: data)
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
              let kind = obj["kind"] as? String else { return }
        switch kind {
        case "hello":
            // Loopback-only listener, so any local client may attach (no pairing).
            let program = (obj["program"] as? String) ?? "browser"
            lock.lock()
            peers[key]?.program = program
            peers[key]?.connected = true
            lock.unlock()
            send(conn, dict: ["kind": "welcome", "peers": peerListJSON()])
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
        case "ping":
            send(conn, dict: ["kind": "pong", "t": (obj["t"] as? Double) ?? 0])
        default:
            break
        }
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

    private func removePeer(_ key: ObjectIdentifier) {
        lock.lock()
        let program = peers[key]?.program
        let existed = peers.removeValue(forKey: key) != nil
        lock.unlock()
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
        let list = peers.values.map {
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
        let peerList = peers.values.map {
            ["id": $0.id, "program": $0.program, "connected": $0.connected] as [String: Any]
        }
        lock.unlock()
        let status: [String: Any] = [
            "running": running,
            "state": err.isEmpty ? (running ? "running" : "off") : "error",
            "address": "ws://127.0.0.1:\(port)",
            "peers": peerList,
            "error": err
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: status),
              let json = String(data: data, encoding: .utf8) else {
            return "{\"running\":false,\"state\":\"off\",\"peers\":[]}"
        }
        return json
    }

    // MARK: Cluster registry API (called from the WS path and the web bridge)

    /// Records an endpoint's eligible groups. `program` "macapp" is this Mac.
    func setRoster(program: String, groups: [[String: Any]]) {
        guard !program.isEmpty else { return }
        let infos = groups.map {
            GroupInfo(
                name: ($0["name"] as? String) ?? "",
                type: ($0["type"] as? String) ?? "",
                frozen: ($0["frozen"] as? Bool) ?? false
            )
        }
        lock.lock()
        rosters[program] = infos
        lock.unlock()
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
        applySync(program: "macapp", groupName: groupName, groupType: "site", contribution: contribution, ts: 0)
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
            $0.groupName == groupName && $0.members.contains("macapp")
        }) else { return nil }
        return (cluster.sharedUsageMs, cluster.sharedUsageResetAtMs)
    }

    func syncFromBridge(json: String) {
        guard let obj = decode(json) else { return }
        applySync(
            program: (obj["program"] as? String) ?? "macapp",
            groupName: (obj["groupName"] as? String) ?? "",
            groupType: (obj["groupType"] as? String) ?? "",
            contribution: obj,
            ts: (obj["ts"] as? Double) ?? 0
        )
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
        setRoster(
            program: (obj["program"] as? String) ?? "macapp",
            groups: (obj["groups"] as? [[String: Any]]) ?? []
        )
    }

    func connectFromBridge(json: String) {
        guard let obj = decode(json) else { return }
        connectGroup(
            from: (obj["fromProgram"] as? String) ?? "macapp",
            to: (obj["toProgram"] as? String) ?? "",
            groupName: (obj["groupName"] as? String) ?? "",
            groupType: (obj["groupType"] as? String) ?? ""
        )
    }

    func disconnectFromBridge(json: String) {
        guard let obj = decode(json) else { return }
        disconnectGroup(
            clusterId: (obj["clusterId"] as? String) ?? "",
            groupName: (obj["groupName"] as? String) ?? "",
            program: (obj["program"] as? String) ?? "macapp"
        )
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
                "contributions": c.contributions,
                "sharedScalars": c.sharedScalars,
                "sharedTs": c.sharedTs,
                "sharedSnooze": c.sharedSnooze,
                "sharedSnoozeTs": c.sharedSnoozeTs
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
            if let contributions = obj["contributions"] as? [String: [String: Any]] {
                cluster.contributions = contributions
            }
            if let scalars = obj["sharedScalars"] as? [String: Any] { cluster.sharedScalars = scalars }
            cluster.sharedTs = (obj["sharedTs"] as? Double) ?? 0
            if let snooze = obj["sharedSnooze"] as? [String: Any] { cluster.sharedSnooze = snooze }
            cluster.sharedSnoozeTs = (obj["sharedSnoozeTs"] as? Double) ?? 0
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

    /// Caller must hold `lock`. Programs with a live connected peer, plus the Mac
    /// host itself (always online while the hub runs). Used to flag cluster
    /// members online/offline.
    private func onlineProgramsLocked() -> Set<String> {
        var set = Set<String>()
        for peer in peers.values where peer.connected && !peer.program.isEmpty {
            set.insert(peer.program)
        }
        set.insert("macapp")
        return set
    }

    /// Caller must hold `lock`. Serializes a cluster including the shared state
    /// and the union of owned lists (sites from browsers, apps from Macs).
    private func clusterJSONObject(_ cluster: ClusterState) -> [String: Any] {
        var sites = Set<String>()
        // App pool keyed by display name → icon data URL. A non-empty icon from
        // any member wins so a name contributed without an icon (legacy string)
        // still picks up the icon when another member supplies it.
        var appIcons: [String: String] = [:]
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
        let online = onlineProgramsLocked()
        let allOnline = cluster.members.allSatisfy { online.contains($0) }
        let hasShared = !cluster.sharedScalars.isEmpty || cluster.sharedTs > 0
        var dict: [String: Any] = [
            "id": cluster.id,
            "groupName": cluster.groupName,
            "groupType": cluster.groupType,
            "allOnline": allOnline,
            "members": cluster.members.sorted().map {
                ["program": $0, "groupName": cluster.groupName, "online": online.contains($0)] as [String: Any]
            }
        ]
        if hasShared || !sites.isEmpty || !appsArray.isEmpty || cluster.sharedUsageMs > 0 || cluster.sharedSnoozeTs > 0 {
            dict["shared"] = [
                "scalars": cluster.sharedScalars,
                "ts": cluster.sharedTs,
                "sites": sites.sorted(),
                "apps": appsArray,
                "usageMs": cluster.sharedUsageMs,
                "usageResetAtMs": cluster.sharedUsageResetAtMs,
                "snooze": cluster.sharedSnooze,
                "snoozeTs": cluster.sharedSnoozeTs
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
        if program == "macapp" {
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
