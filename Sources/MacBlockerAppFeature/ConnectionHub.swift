#if os(macOS)
import Foundation
import CoreFoundation
import CryptoKit
import struct VaultClassifierCore.RuleAIConfiguration
import struct VaultClassifierCore.StorageSchemaPolicy
import struct VaultClassifierCore.StorageProduct
import MacBlockerCore
import MacBlockerWebUI
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

    typealias BrowserIdentityBudgetPredicate = ([String: Any], [[String: Any]], String) -> Bool
    // The affected-budget classification is separate from connection identity:
    // it determines where a missing identity requires a pause, never overlap.
    static func defaultBrowserIdentityBudgetPredicate(_ scalars: [String: Any], _ scopes: [[String: Any]], _ program: String) -> Bool {
        BrowserIdentityBudgetPolicy.affects(scalars, scopes: scopes,
                                            browserBundleIDs: BrowserIdentityBudgetPolicy.recognizedBrowserBundleIDs())
    }

    private struct BrowserIdentitySnapshot {
        let generation: String
        let paused: Bool
        let definitionReady: Bool
        var applied = false
    }

    /// Safari uses the owner-approved ordinary-app association. It is a
    /// declared accounting choice, never an attested identity or proof.
    enum BrowserUsageAssociation: Equatable {
        case attested(BrowserApplicationIdentity)
        case ordinarySafari
        var bundleID: String {
            switch self {
            case .attested(let identity): return identity.value
            case .ordinarySafari: return "com.apple.safari"
            }
        }
    }

    static func browserUsageAssociation(program: String, browserIdentity: BrowserApplicationIdentity?) -> BrowserUsageAssociation? {
        if let browserIdentity, browserIdentity.kind == "mac-bundle-id" { return .attested(browserIdentity) }
        return program == "safari" && browserIdentity == nil ? .ordinarySafari : nil
    }

    private static func requiresBrowserIdentityProof(_ program: String) -> Bool {
        browserPrograms.contains(program) && program != "safari"
    }

    /// Exact proof remains required for Chromium-family accounting. Safari's
    /// explicit ordinary-app association does not claim STP/WebApp detection.
    static func countsWholeBrowser(_ scopes: [[String: Any]], program: String, browserIdentity: BrowserApplicationIdentity?) -> Bool {
        guard let association = browserUsageAssociation(program: program, browserIdentity: browserIdentity) else { return false }
        return countsWholeBrowser(scopes, bundleID: association.bundleID)
    }

    static func countsWholeBrowser(_ scopes: [[String: Any]], browserIdentity: BrowserApplicationIdentity?) -> Bool {
        guard let browserIdentity, browserIdentity.kind == "mac-bundle-id" else { return false }
        return countsWholeBrowser(scopes, bundleID: browserIdentity.value)
    }

    private static func countsWholeBrowser(_ scopes: [[String: Any]], bundleID: String) -> Bool {
        return scopes.contains { line in
            guard (line["surface"] as? String) == "apps",
                  (line["action"] as? String ?? "block") == "block" else { return false }
            let listed = Set((line["apps"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String })
            let included = BlockGroup.lists(listed, bundleID)
            return (line["appsExcept"] as? Bool) == true ? !included : included
        }
    }

    private struct Peer {
        let id: String
        var program: String
        var connected: Bool
        var browserIdentity: BrowserApplicationIdentity?
        var supportsOriginalUsage = false
        var browserIdentitySnapshots: [String: BrowserIdentitySnapshot] = [:]
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
    static let shared: ConnectionHub = {
        let hub = ConnectionHub()
        hub.localWebStore = BlockerWebStore()
        return hub
    }()

    /// The native member's canonical store. Test hubs can inject an isolated
    /// store; transport-only hubs need no local persistence surface.
    private var localWebStoreValue: BlockerWebStore?
    var localWebStore: BlockerWebStore? {
        get { lock.lock(); defer { lock.unlock() }; return localWebStoreValue }
        set {
            if let store = newValue {
                // Capture the canonical baseline before exposing ownership.
                // Production initializes it before the editor/timer/MCP admit
                // writes. This is observation only, under file -> hub order.
                try? store.withLockedDocument(notify: false) { document, _ in
                    self.lock.lock(); defer { self.lock.unlock() }
                    self.assignLocalWebStoreLocked(store, document: document)
                }
            } else {
                lock.lock(); defer { lock.unlock() }
                assignLocalWebStoreLocked(nil, document: nil)
            }
        }
    }

    private func assignLocalWebStoreLocked(_ store: BlockerWebStore?, document: [String: Any]?) {
        guard localWebStoreValue !== store else { return }
        localWebStoreValue?.clearSharedReconciliation(owner: self)
        localWebStoreValue = store
        localDefinitionSeen.removeAll()
        lastLocalRoster = ""
        if let document, let groups = Self.canonicalLocalGroups(document) {
            for group in groups {
                if let id = group["id"] as? String { localDefinitionSeen[id] = Self.localDefinition(group) }
            }
        }
        guard let store else { return }
        store.setSharedReconciliation(owner: self) { [weak self, weak store] in
            guard let self, let store, self.localWebStore === store else { return false }
            return self.reconcileLocalStore(store, nowMs: (Date().timeIntervalSince1970 * 1000).rounded(.down))
        }
        store.setEditorDefinitionMutation(owner: self) { [weak self, weak store] request in
            guard let self, let store, self.localWebStore === store else {
                throw GroupStoreError.invalidInput("native-editor-unavailable")
            }
            return try self.applyEditorDefinitionRequest(request, store: store)
        }
    }

    private let queue = DispatchQueue(label: "macosBlocker.ConnectionHub")
    private let lock = NSLock()
    private let outboundQueue: DispatchQueue
    /// Optional transport injection: production sends the exact same serialized
    /// frames to NWConnection; isolated tests observe delivery without sockets.
    private let outboundDelivery: ((Data) -> Void)?

    /// Broker dependency remains behind authenticated, connection-bound routing.
    var ruleAIRequest: @MainActor (String, String, String, String) async -> [String: Any] = { operation, program, groupID, payload in
        let service = RuleAIService.shared
        return operation == "models" ? service.modelOptions() : await service.request(program: program, groupID: groupID, payload: payload)
    }

    private let registryDefaults: UserDefaults
    private let browserIdentityBudgetPredicate: BrowserIdentityBudgetPredicate

    init(registryDefaults: UserDefaults = .standard,
         browserIdentityBudgetPredicate: @escaping BrowserIdentityBudgetPredicate = ConnectionHub.defaultBrowserIdentityBudgetPredicate) {
        self.registryDefaults = registryDefaults
        self.browserIdentityBudgetPredicate = browserIdentityBudgetPredicate
        // Production always owns a private serial FIFO. Only the isolated
        // transport initializer below permits a test queue and delivery sink.
        outboundQueue = DispatchQueue(label: "macosBlocker.ConnectionHub.outbound")
        outboundDelivery = nil
    }

    init(testOutboundQueue: DispatchQueue, registryDefaults: UserDefaults = .standard,
         browserIdentityBudgetPredicate: @escaping BrowserIdentityBudgetPredicate = ConnectionHub.defaultBrowserIdentityBudgetPredicate,
         outboundDelivery: @escaping (Data) -> Void) {
        self.registryDefaults = registryDefaults
        self.browserIdentityBudgetPredicate = browserIdentityBudgetPredicate
        self.outboundQueue = testOutboundQueue
        self.outboundDelivery = outboundDelivery
    }

    /// The Activity log store. When set, the hub handles the activity ops locally
    /// (writing this store) instead of relaying them to the classifier peer. Set
    /// once at launch; shared with the native app-usage recorder.
    private let activityAssignmentLock = NSLock()
    private var activityStoreValue: ActivityStore?
    private var activityObserver: UUID?
    private var publishedActivitySnapshot: ActivitySettingsSnapshot?
    var activityStore: ActivityStore? {
        get { lock.lock(); defer { lock.unlock() }; return activityStoreValue }
        set {
            // Never call into the store under the hub lock: successful store
            // commits publish outside its own lock and may enter this hub.
            activityAssignmentLock.lock(); defer { activityAssignmentLock.unlock() }
            lock.lock()
            guard activityStoreValue !== newValue else { lock.unlock(); return }
            let oldStore = activityStoreValue, oldObserver = activityObserver
            activityStoreValue = newValue
            activityObserver = nil
            publishedActivitySnapshot = nil
            let retiring = peers.values.filter { $0.connected && Self.browserPrograms.contains($0.program) }.map(\.connection)
            for connection in retiring {
                peers[ObjectIdentifier(connection)]?.connected = false
                peers[ObjectIdentifier(connection)]?.browserIdentity = nil
                peers[ObjectIdentifier(connection)]?.browserIdentitySnapshots = [:]
            }
            lock.unlock()
            if let oldObserver { oldStore?.removeSettingsObserver(oldObserver) }
            // A replacement is a new authority epoch. Existing browser sessions
            // must authenticate again; the classifier/listener stay running.
            retiring.forEach { $0.cancel() }
            guard let store = newValue else { return }
            let token = store.observeSettings { [weak self, weak store] snapshot in
                guard let self, let store else { return }
                self.publishActivitySettings(snapshot, from: store)
            }
            lock.lock(); activityObserver = token; lock.unlock()
            // Subscribing first closes the read/subscribe race. If a commit
            // callback wins, this older initial read cannot replace its state.
            publishActivitySettings(store.settingsSnapshot(), from: store)
        }
    }

    deinit {
        // Destruction owns the last reference; no hub lock is needed here.
        if let activityObserver { activityStoreValue?.removeSettingsObserver(activityObserver) }
    }

    /// Successful commits carry their exact snapshot, never a later reread.
    /// An already captured callback from a retired store has no authority.
    func publishActivitySettings(_ snapshot: ActivitySettingsSnapshot, from store: ActivityStore) {
        lock.lock(); defer { lock.unlock() }
        guard activityStoreValue === store else { return }
        if let previous = publishedActivitySnapshot {
            guard previous.epoch == snapshot.epoch, snapshot.revision > previous.revision else { return }
        }
        publishedActivitySnapshot = snapshot
        let destinations = peers.values.filter { $0.connected && Self.browserPrograms.contains($0.program) }.map(\.connection)
        enqueueLocked(Self.activitySettingsNotification(snapshot), to: destinations)
    }

    static func activitySettingsNotification(_ snapshot: ActivitySettingsSnapshot) -> [String: Any] {
        ["kind": "activity-settings-updated", "body": ActivityWire.settingsSnapshotPayload(snapshot)]
    }

    /// The caller has already verified the hello proof. Welcome and the cached
    /// initial settings snapshot are enqueued together under the hub lock.
    private func welcomeAuthenticatedPeerLocked(_ connection: NWConnection, program: String) {
        enqueueLocked([
            "kind": "welcome", "v": Self.protocolVersion,
            "usageTransferReceipts": true,
            "ruleTimeVersion": 1, "ruleAIVersion": 1,
            "browserIdentityVersion": VaultClassifierBridge.LocalHubAuthentication.browserIdentityVersion,
            "activitySettingsNotifications": activityStoreValue != nil && publishedActivitySnapshot != nil,
            "hubProgram": Self.localProgram, "peers": peerListJSONLocked()
        ], to: [connection])
        if Self.browserPrograms.contains(program), let snapshot = publishedActivitySnapshot {
            // Sending one peer its initial state never advances the global
            // publication marker or suppresses another peer's commit delivery.
            enqueueLocked(Self.activitySettingsNotification(snapshot), to: [connection])
        }
    }
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
    private var clusterStorageWritable = true
    private var wantsToListen = false
    // Internal (not private) so tests can stand in for a hosting hub.
    var hostingLocalHub = false
    static func helloRejectionReason(_ obj: [String: Any], challenge: String, secret: Data?,
                                     appMajor: Int = StorageProduct.current.major) -> String? {
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
        if obj.keys.contains("originalUsageVersion"), !isOriginalUsageVersion(obj["originalUsageVersion"]) { return "invalid-original-usage-version" }
        let hasVersion = obj.keys.contains("browserIdentityVersion")
        let hasIdentity = obj.keys.contains("browserIdentity")
        guard hasVersion || hasIdentity else {
            return requiresBrowserIdentityProof(program) && !(0...3).contains(appMajor) ? "browser-upgrade-required" : nil
        }
        guard browserPrograms.contains(program), hasVersion && hasIdentity,
              VaultClassifierBridge.LocalHubAuthentication.isBrowserIdentityVersion(obj["browserIdentityVersion"]),
              let object = obj["browserIdentity"] as? [String: Any],
              let identity = VaultClassifierBridge.LocalHubAuthentication.verifyBrowserIdentityAttestation(
                object, program: program, challenge: challenge, secret: secret),
              identity.kind == "mac-bundle-id" else { return "invalid-browser-identity" }
        return nil
    }

    static func isOriginalUsageVersion(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(String(cString: number.objCType)) else { return false }
        return number.int64Value == 1
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
        var timeState: [String: Any]? = nil
        var custom = false
        var enabled = false
        var ruleAI: [String: Any]? = nil
        var aiEpoch = UUID().uuidString
    }

    /// A live cluster: the bound programs plus the hub-authoritative shared
    /// settings derived from each member's contribution.
    private final class ClusterState {
        let id: String
        /// The link's shared name (linked groups are renamed together).
        var groupName: String
        /// The program whose Link button made the link: its settings win the
        /// first merge (the other group joins it).
        var initiator = ""
        var members: Set<String> = []
        /// Per-program local group id: the specific group *instance* that program
        /// linked. Membership is pinned to this id so deleting a group and later
        /// re-creating one with the same name does NOT silently re-join the old
        /// cluster (the new group carries a fresh id).
        var memberGroupIds: [String: String] = [:]
        /// The members that have contributed their definition: a member's FIRST
        /// contribution unions its lines into the shared ones.
        var contributed: Set<String> = []
        /// A definition-only old client has not transferred its original budget.
        /// Keep this bounded join admission distinct from configuration replay.
        var originalUsagePending: Set<String> = []
        // Hub-authoritative shared state: the one group definition every
        // member adopts. Scalars and scopes are latest-edit-wins (see applySync).
        var sharedScalars: [String: Any] = [:]
        var aiEpoch = UUID().uuidString
        var sharedTs: Double = 0
        var sharedScopes: [[String: Any]] = []
        /// Hub-only provenance for stable first-join Website identities; never sent on the wire.
        var scopeOrigins: [String: String] = [:]
        /// The link's one lock (group-actions.js lockUnit), versioned; empty
        /// until a member contributes one.
        var sharedLock: [String: Any] = [:]
        /// Shared live usage budget. Members report *increments* (usageDeltaMs)
        /// from their own accrual, never absolutes, so adopting this total does
        /// not echo usage back. The browser-app overlap rule below also keeps
        /// website time nested inside a whole-browser target. Before any
        /// delta arrives we seed it from the largest member absolute so joining a
        /// cluster with prior usage doesn't wipe it.
        var sharedUsageMs: Double = 0
        var sharedUsageResetAtMs: Double = 0
        var usageSeeded = false
        /// Only while original definitions are still joining: max original
        /// usage plus increments accrued after linking. A delayed original
        /// seed must neither erase those increments nor be suppressed by them.
        var joiningUsageBaseMs: Double? = nil
        var joiningUsageDeltaMs: Double = 0
        var joiningSeedFloorMs: Double = 0
        var joiningBucketsBase: [Double: Double] = [:]
        var joiningBucketDeltas: [Double: Double] = [:]
        /// Durable receipts for immutable offline usage batches, keyed by peer
        /// program and transfer id. Retried batches never consume usage twice.
        var usageTransferReceipts: [String: Double] = [:]
        /// Rolling-limit groups share per-minute usage (minute-start ms -> ms)
        /// instead of one total: a sliding window needs to know WHEN time was
        /// used so old minutes can age out. Deltas only, like `sharedUsageMs`.
        var sharedBuckets: [Double: Double] = [:]
        var sharedRuleTime: [String: Any] = [:]
        var detachedRuleTime: [String: [String: Any]] = [:]
        var bucketsSeeded = false
        /// Active snooze runtime shared across members (newest start wins). The
        /// entry carries its own timing so each side enforces + expires it
        /// identically; `sharedSnoozeTs` is the originating start time.
        var sharedSnooze: [String: Any] = [:]
        var sharedSnoozeTs: Double = 0
        /// The link's total snoozed time: time snoozes count once when finished;
        /// budget snoozes count as shared usage consumes the extra allowance.
        /// `snoozeCountedStartMs`
        /// is the start of the last snooze counted (entries run one at a time).
        var sharedSnoozeTotalMs: Double = 0
        var snoozeCountedStartMs: Double = 0

        init(id: String, groupName: String) {
            self.id = id
            self.groupName = groupName
        }

        /// Editor admission runs on distinct state until its canonical file save
        /// succeeds. Explicitly copy every field, including joining/runtime data.
        func editorCopy() -> ClusterState {
            let copy = ClusterState(id: id, groupName: groupName)
            copy.initiator = initiator
            copy.members = members
            copy.memberGroupIds = memberGroupIds
            copy.contributed = contributed
            copy.originalUsagePending = originalUsagePending
            copy.sharedTs = sharedTs
            copy.aiEpoch = aiEpoch
            copy.scopeOrigins = scopeOrigins
            copy.sharedUsageMs = sharedUsageMs
            copy.sharedUsageResetAtMs = sharedUsageResetAtMs
            copy.usageSeeded = usageSeeded
            copy.joiningUsageBaseMs = joiningUsageBaseMs
            copy.joiningUsageDeltaMs = joiningUsageDeltaMs
            copy.joiningSeedFloorMs = joiningSeedFloorMs
            copy.joiningBucketsBase = joiningBucketsBase
            copy.joiningBucketDeltas = joiningBucketDeltas
            copy.usageTransferReceipts = usageTransferReceipts
            copy.sharedBuckets = sharedBuckets
            copy.sharedRuleTime = sharedRuleTime.mapValues(ConnectionHub.copyJSONValue)
            copy.detachedRuleTime = detachedRuleTime.mapValues { $0.mapValues(ConnectionHub.copyJSONValue) }
            copy.bucketsSeeded = bucketsSeeded
            copy.sharedSnoozeTs = sharedSnoozeTs
            copy.sharedSnoozeTotalMs = sharedSnoozeTotalMs
            copy.snoozeCountedStartMs = snoozeCountedStartMs
            copy.sharedScalars = sharedScalars.mapValues(ConnectionHub.copyJSONValue)
            copy.sharedScopes = sharedScopes.map { $0.mapValues(ConnectionHub.copyJSONValue) }
            copy.sharedLock = sharedLock.mapValues(ConnectionHub.copyJSONValue)
            copy.sharedSnooze = sharedSnooze.mapValues(ConnectionHub.copyJSONValue)
            return copy
        }
    }

    /// Each endpoint's eligible Default/Custom groups, keyed by program id.
    private var rosters: [String: [GroupInfo]] = [:]
    private var rosterRevisions: [String: UInt64] = [:]
    /// Active clusters keyed by cluster id.
    private var clusters: [String: ClusterState] = [:]

    private struct EditorFrame {
        let data: Data
        let connections: [NWConnection]
    }
    private final class EditorStaging {
        var frames: [EditorFrame] = []
        var persistRegistry = false
    }
    /// Only set inside the editor's canonical file -> hub transaction. No
    /// transport or registry write escapes until the canonical save succeeds.
    private var editorStaging: EditorStaging?

    private static func copyJSONValue(_ value: Any) -> Any {
        if let dictionary = value as? [String: Any] { return dictionary.mapValues(copyJSONValue) }
        if let array = value as? [Any] { return array.map(copyJSONValue) }
        return value
    }

    /// UserDefaults key for the persisted cluster registry. Bumping the suffix
    /// invalidates older on-disk shapes.
    /// v2 since 2026-09-27: links are made by the user. The automatic links
    /// of v1 were dropped (owner) — see restoreClustersLocked.
    private static let clustersDefaultsKey = "ConnectionHub.clusters.v2"
    private static let droppedClustersDefaultsKey = "ConnectionHub.clusters.v1"
    /// Mac groups that left a link (unlinked, or their link dissolved) and must
    /// keep only their own lines; the engine takes and trims them.
    private var unlinkedLocal: Set<String> = []

    // MARK: Lifecycle

    /// The listener, its retry and the budget timer live on the hub's queue
    /// (their callbacks run there); start and stop hop onto it.
    func start() {
        queue.async { [self] in
            guard !wantsToListen else { return }
            wantsToListen = true
            startLocalHub()
        }
    }

    func stop() {
        queue.sync { stopOnQueue() }
    }

    private func stopOnQueue() {
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
        // Publish the same native-only credential for the separate Safari
        // extension before a browser can receive its authentication challenge.
        guard (try? LocalHubAuthentication.sharedSecret()) != nil else {
            retryListenLater()
            return
        }
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
        for cluster in clusters.values {
            let rolled = rollBudgetLocked(cluster, nowMs: nowMs)
            let counted = Self.countSnoozeLocked(cluster, nowMs: nowMs)
            if rolled || counted || browserIdentityTransitionPendingLocked(cluster) { broadcastClusterLocked(clusterJSONObject(cluster)) }
        }
        lock.unlock()
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
        // A new period whenever the anchor isn't this period's start, as
        // UsageBudget and group-actions.js decide it.
        guard start != cluster.sharedUsageResetAtMs else { return false }
        cluster.sharedUsageMs = 0
        if cluster.joiningUsageBaseMs != nil { cluster.joiningUsageBaseMs = 0; cluster.joiningUsageDeltaMs = 0 }
        cluster.sharedUsageResetAtMs = start.rounded(.down)
        if cluster.joiningUsageBaseMs != nil { cluster.joiningSeedFloorMs = cluster.sharedUsageResetAtMs }
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
        guard (entry["kind"] as? String) != "budget" else { return false }
        guard let start = (entry["startsAtMs"] as? NSNumber)?.doubleValue,
              let until = (entry["untilMs"] as? NSNumber)?.doubleValue,
              start != cluster.snoozeCountedStartMs,
              replacing || nowMs >= until else { return false }
        cluster.sharedSnoozeTotalMs += max(0, min(until, nowMs) - start).rounded()
        cluster.snoozeCountedStartMs = start
        return true
    }

    private static func countBudgetSnoozeLocked(_ cluster: ClusterState, beforeMs: Double, addedMs: Double, nowMs: Double) {
        let given = (GroupActionsRuntime.shared.call("snoozeGivenMs", [cluster.sharedScalars, cluster.sharedSnooze, beforeMs, addedMs, nowMs]) as? NSNumber)?.doubleValue ?? 0
        if given.isFinite && given > 0 { cluster.sharedSnoozeTotalMs += given }
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
        registerPendingPeer(conn, challenge: challenge)

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

    // Common peer-state entry points, also exercised by isolated transport
    // tests. Admission is called only after handleIncoming verifies the proof.
    func registerPendingPeer(_ connection: NWConnection, challenge: String) {
        lock.lock(); defer { lock.unlock() }
        peers[ObjectIdentifier(connection)] = Peer(id: UUID().uuidString, program: "", connected: false, browserIdentity: nil,
                                                  challenge: challenge, connection: connection)
    }

    func admitAuthenticatedPeer(_ connection: NWConnection, program: String,
                                browserIdentity: BrowserApplicationIdentity? = nil, supportsOriginalUsage: Bool = false) -> String? {
        lock.lock(); defer { lock.unlock() }
        let key = ObjectIdentifier(connection)
        guard peers[key] != nil, Self.remotePrograms.contains(program) else { return "invalid-program" }
        guard peers[key]?.connected == false else { return "already-authenticated" }
        if activityStoreValue != nil && publishedActivitySnapshot == nil { return "activity-initializing" }
        let connectedPrograms = peers.values.filter { $0.connected }.map(\.program)
        guard !Self.isDuplicateBrowser(program, connectedPrograms: connectedPrograms) else { return "duplicate-program" }
        if !supportsOriginalUsage, clusters.values.contains(where: { unsafeLegacyRollingOriginalLocked($0, program: program) }) {
            return "browser-upgrade-required"
        }
        peers[key]?.program = program
        peers[key]?.supportsOriginalUsage = supportsOriginalUsage
        peers[key]?.browserIdentity = browserIdentity
        peers[key]?.connected = true
        welcomeAuthenticatedPeerLocked(connection, program: program)
        broadcastPeersLocked()
        sendClustersSnapshotLocked(connection)
        for cluster in clusters.values where cluster.members.contains(program) {
            broadcastClusterLocked(clusterJSONObject(cluster))
        }
        return nil
    }

    var activityNotificationRecipients: [String] {
        lock.lock(); defer { lock.unlock() }
        return peers.values.filter { $0.connected && Self.browserPrograms.contains($0.program) }.map(\.program).sorted()
    }

    func handleIncoming(_ conn: NWConnection, key: ObjectIdentifier, data: Data) {
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
            let secret = try? LocalHubAuthentication.sharedSecret()
            if let reason = Self.helloRejectionReason(obj, challenge: challenge, secret: secret) {
                rejectAndClose(conn, reason: reason)
                return
            }
            let program = (obj["program"] as? String) ?? "browser"
            let identity = (obj["browserIdentity"] as? [String: Any]).flatMap { object in
                secret.flatMap { VaultClassifierBridge.LocalHubAuthentication.verifyBrowserIdentityAttestation(
                    object, program: program, challenge: challenge, secret: $0) }
            }
            if let reason = admitAuthenticatedPeer(conn, program: program, browserIdentity: identity, supportsOriginalUsage: Self.isOriginalUsageVersion(obj["originalUsageVersion"])) {
                rejectAndClose(conn, reason: reason)
            }
        case "groups-announce":
            lock.lock()
            let prog = peers[key]?.program ?? ((obj["program"] as? String) ?? "")
            lock.unlock()
            if let refusal = setRoster(program: prog, groups: (obj["groups"] as? [[String: Any]]) ?? []) {
                send(conn, dict: ["kind": "group-sync-refused", "reason": refusal])
            }
        case "rule-ai-request":
            lock.lock()
            let peer = peers[key]
            lock.unlock()
            guard let peer, peer.connected, Self.browserPrograms.contains(peer.program),
                  let requestID = obj["requestID"] as? String, Self.isVisibleBridgeIdentifier(requestID, maximumLength: 128) else { return }
            let op = obj["operation"] as? String ?? ""
            let groupID = obj["groupId"] as? String ?? ""
            let payload = obj["payload"] as? String ?? ""
            guard ["models", "generate"].contains(op), payload.utf8.count <= 48_000 else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let body = await self.ruleAIRequest(op, peer.program, groupID, payload)
                let current = self.lock.withLock { self.peers[key]?.id == peer.id && self.peers[key]?.connected == true }
                if current { self.send(conn, dict: ["kind": "rule-ai-response", "requestID": requestID, "body": body]) }
            }
        case "rule-time-request":
            lock.lock()
            let program = peers[key]?.program ?? ""
            lock.unlock()
            let requestID = obj["requestID"] as? String ?? ""
            guard Self.isVisibleBridgeIdentifier(requestID, maximumLength: 128), let groupID = obj["groupId"] as? String,
                  let commands = obj["commands"] as? [[String: Any]], commands.count <= 64 else { return }
            let body = syncRuleTime(program: program, groupID: groupID, clusterID: obj["clusterId"] as? String,
                                    seed: obj["seed"] as? [String: Any], commands: commands, usage: obj["usage"] as? [String: Any])
            send(conn, dict: ["kind": "rule-time-response", "requestID": requestID, "groupId": groupID, "body": body])
        case "group-sync":
            lock.lock()
            if let peer = peers[key], peer.connected {
                var contribution = obj
                let groupID = (obj["groupId"] as? String) ?? ""
                if let cluster = clusterLocked(program: peer.program, groupId: groupID),
                   browserIdentityPauseRequiredLocked(cluster),
                   ((cluster.contributed.contains(peer.program) && ["scalars", "scopes", "lock", "lockBase"].contains { obj[$0] != nil })
                    || ((obj["snoozeTs"] as? Double) ?? 0) > cluster.sharedSnoozeTs) {
                    enqueueLocked(["kind": "group-sync-refused", "groupId": groupID, "reason": "browser-upgrade-required"], to: [conn])
                }
                // Safari's durable ACK identifies an updated consumer without
                // demanding an unneeded identity proof. Baseline Safari config
                // remains available; affected unlink still requires this ACK.
                let snapshotApplied = browserIdentitySnapshotAppliedLocked(peerKey: key, groupID: groupID, contribution: obj)
                if peer.browserIdentity != nil && !snapshotApplied {
                    // A reconnect may still hold the effective disabled value
                    // saved by an older client. Only a durable current snapshot
                    // adoption authorizes its definitions and initial seeds.
                    // Fresh usage and tagged offline handovers retain their
                    // existing independent accounting path below.
                    for field in ["scalars", "scopes", "lock", "lockBase", "usageMs", "usageBucketsSeed"] {
                        contribution.removeValue(forKey: field)
                    }
                }
                applySyncLocked(program: peer.program, groupId: (obj["groupId"] as? String) ?? "",
                                contribution: contribution, ts: (obj["ts"] as? Double) ?? 0,
                                browserIdentity: peer.browserIdentity)
            }
            lock.unlock()
        case "group-link", "group-unlink":
            lock.lock()
            let prog = peers[key]?.program ?? ""
            lock.unlock()
            let groupId = (obj["groupId"] as? String) ?? ""
            if kind == "group-link" {
                linkGroupsWithBrowserIdentityPreflight(program: prog, groupId: groupId,
                    targetProgram: (obj["targetProgram"] as? String) ?? "", targetGroupId: (obj["targetGroupId"] as? String) ?? "") { [weak self] refusal in
                    if let refusal { self?.send(conn, dict: ["kind": "link-refused", "reason": refusal, "groupId": groupId]) }
                }
            } else {
                var requestID: String?
                if obj.keys.contains("requestID") {
                    guard let value = obj["requestID"] as? String, Self.isVisibleBridgeIdentifier(value, maximumLength: 128) else {
                        send(conn, dict: ["kind": "link-refused", "reason": "invalid-request", "groupId": groupId]); return
                    }
                    requestID = value
                }
                let refusal = unlinkGroup(program: prog, groupId: groupId, requestingPeerKey: key)
                if let requestID {
                    var response: [String: Any] = ["kind": "group-unlink-response", "requestID": requestID, "groupId": groupId, "ok": refusal == nil]
                    if let refusal { response["error"] = refusal }
                    send(conn, dict: response)
                } else if let refusal { send(conn, dict: ["kind": "link-refused", "reason": refusal, "groupId": groupId]) }
            }
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
        lock.lock()
        enqueueLocked(dict, to: [conn])
        lock.unlock()
    }

    /// Caller holds the hub lock. Freeze payload and authenticated destinations
    /// before submitting to the one FIFO, in the same order as state commits.
    /// Enqueueing after unlock would allow an older snapshot to arrive last.
    private func enqueueLocked(_ dict: [String: Any], to connections: [NWConnection]) {
        guard !connections.isEmpty || outboundDelivery != nil,
              let data = try? JSONSerialization.data(withJSONObject: dict) else { return }
        if let editorStaging {
            editorStaging.frames.append(EditorFrame(data: data, connections: connections))
            return
        }
        enqueueFrozenLocked(data, to: connections)
    }

    private func enqueueFrozenLocked(_ data: Data, to connections: [NWConnection]) {
        let deliver = outboundDelivery
        outboundQueue.async { [self] in
            // The producer may still own the lock when async begins. Wait for
            // its release, then perform transport/callback work without it.
            lock.lock()
            lock.unlock()
            if let deliver { deliver(data); return }
            for connection in connections {
                let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
                let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
                connection.send(content: data, contentContext: context, isComplete: true,
                                completion: .contentProcessed { _ in })
            }
        }
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
            // Capture both the authenticated peer and its current authority in
            // one admission step. Replacement cannot make an old session's
            // in-flight request write the newly assigned store.
            lock.lock()
            guard let peer = peers[key], peer.connected, Self.browserPrograms.contains(peer.program) else { lock.unlock(); return }
            let source = peer.connection, store = activityStoreValue
            lock.unlock()
            handleActivityRequest(source: source, store: store, requestID: requestID, operation: operation, body: body)
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
    /// store admits only native-known grants and clips intervals at OFF);
    /// `activity-settings` gets, or merges-and-sets, the recording settings.
    private func handleActivityRequest(source: NWConnection, store: ActivityStore?, requestID: String, operation: String, body: [String: Any]) {
        guard let store else {
            send(source, dict: ["kind": "classifier-response", "requestID": requestID, "operation": operation, "error": "activity-unavailable"])
            return
        }
        switch operation {
        case "activity-record":
            let entries = ActivityWire.browserRecords(from: body)
            let duplicateIDs = ActivityWire.duplicateBrowserRecordIDs(from: body)
            var stored = 0, acceptedIDs = Set<String>(), storedIDs = Set<String>(), pendingIDs = Set<String>()
            for entry in entries where !duplicateIDs.contains(entry.record.id) {
                let result = store.recordBrowser(entry)
                if result.accepted { acceptedIDs.insert(entry.record.id) }
                if result == .stored { stored += 1; storedIDs.insert(entry.record.id) }
                if result == .pending { pendingIDs.insert(entry.record.id) }
            }
            let ids = ActivityWire.browserRecordIDs(from: body)
            let fresh = entries.filter { storedIDs.contains($0.record.id) }
            let watchedKeys = fresh.filter { $0.record.category == .contentWatched }.map { $0.record.key }
            if !watchedKeys.isEmpty {
                DispatchQueue.main.async { MainActor.assumeIsolated { WatchedFactsRecorder.record(keys: watchedKeys, in: store) } }
            }
            let domains = Set(fresh.filter { $0.record.category == .webVisit }.map { $0.record.key })
            if let icons = body["icons"] as? [String: String] { store.mergeWebIcons(icons.filter { domains.contains($0.key) }) }
            send(source, dict: ["kind": "classifier-response", "requestID": requestID, "operation": operation, "body": [
                "stored": stored,
                "acceptedIDs": ids.filter { acceptedIDs.contains($0) },
                "rejectedIDs": ids.filter { !acceptedIDs.contains($0) && !pendingIDs.contains($0) },
                "pendingIDs": ids.filter { pendingIDs.contains($0) }
            ]])
        case "activity-settings":
            let snapshot: ActivitySettingsSnapshot
            if let settingsBody = body["settings"] as? [String: Any] {
                guard let committed = store.updateSettings({ $0 = ActivityWire.merged($0, with: settingsBody) }) else {
                    send(source, dict: ["kind": "classifier-response", "requestID": requestID, "operation": operation, "error": "activity-storage-unavailable"])
                    return
                }
                snapshot = committed
            } else { snapshot = store.settingsSnapshot() }
            send(source, dict: ["kind": "classifier-response", "requestID": requestID, "operation": operation, "body": ActivityWire.settingsSnapshotPayload(snapshot)])
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
              SharedBrowserBridgeOperation.relayableBroadcastOperations.contains(operation),
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
        enqueueLocked(["kind": "classifier-broadcast", "operation": operation, "body": body], to: browsers)
        lock.unlock()
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

    func expireBrowserRequest(_ requestID: String) {
        lock.lock()
        let pending = browserRequests.removeValue(forKey: requestID)
        lock.unlock()
        pending?.completion(.failure("browser-timeout"))
    }

    func removePeer(_ key: ObjectIdentifier) {
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
        for (source, requestID, operation) in replyTargets {
            enqueueLocked([
                "kind": "classifier-response",
                "requestID": requestID,
                "operation": operation,
                "error": "classifier-unavailable",
            ], to: [source])
        }
        if let program, !program.isEmpty {
            // Offline retains membership and runtime. The online state, roster
            // and affected snapshots must enqueue in this same transition.
            rosters.removeValue(forKey: program)
            for cluster in clusters.values where cluster.members.contains(program) {
                broadcastClusterLocked(clusterJSONObject(cluster))
            }
            broadcastToPeersLocked(["kind": "rosters", "rosters": rostersJSONObjectLocked()])
        }
        if removed != nil { broadcastPeersLocked() }
        lock.unlock()
        if removed != nil { Task { @MainActor in RuleAIService.shared.cancelInvalidRequests() } }
        for completion in strandedBrowserCompletions { completion(.failure("browser-unavailable")) }
    }

    /// Caller holds the hub lock.
    private func broadcastPeersLocked() {
        broadcastToPeersLocked(["kind": "peers", "peers": peerListJSONLocked()])
    }

    // MARK: Status

    /// Caller holds the hub lock.
    private func peerListJSONLocked() -> [[String: Any]] {
        peers.values.filter { $0.connected }.map {
            ["id": $0.id, "program": $0.program, "connected": $0.connected] as [String: Any]
        }
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
    /// cluster is gone once it drops below two members. A topology removal
    /// from a browser-app/Website budget first requires updated, synced peers.
    @discardableResult
    func setRoster(program: String, groups: [[String: Any]]) -> String? {
        guard !program.isEmpty else { return "invalid-program" }
        let infos = Self.rosterInfos(groups)
        do {
            try withMembershipDocument { document, save in
                self.lock.lock(); defer { self.lock.unlock() }
                try self.setRosterLocked(program: program, infos: infos, document: document, save: save)
            }
            return nil
        } catch GroupStoreError.invalidInput(let reason) { return reason }
        catch { return "local-storage-unavailable" }
    }

    func ruleAIContext(program: String, groupID: String) -> RuleAIContext? {
        lock.lock(); defer { lock.unlock() }
        guard let info = rosters[program]?.first(where: { $0.id == groupID }), info.custom, info.enabled else { return nil }
        let cluster = clusterLocked(program: program, groupId: groupID)
        if let enabled = cluster?.sharedScalars["enabled"] as? Bool, !enabled { return nil }
        if let type = cluster?.sharedScalars["groupType"] as? String, type != "custom" { return nil }
        // An explicit shared null removes the connection. Never resurrect a
        // member's stale pre-link selection while its next roster is in flight.
        let raw: [String: Any]?
        if let shared = cluster?.sharedScalars["ruleAI"] { raw = shared as? [String: Any] }
        else { raw = info.ruleAI }
        guard let raw, let data = try? JSONSerialization.data(withJSONObject: raw),
              let configuration = try? JSONDecoder().decode(RuleAIConfiguration.self, from: data) else { return nil }
        let members = cluster.map { value in value.memberGroupIds.map { $0.key + ":" + $0.value }.sorted() } ?? [program + ":" + groupID]
        // A browser reconnect creates a new response destination even if the
        // group's settings are byte-for-byte unchanged.
        let peerRevision = Self.browserPrograms.contains(program)
            ? (peers.values.first { $0.connected && $0.program == program }?.id ?? "offline") : "local"
        return RuleAIContext(configuration: configuration, members: members,
                             revision: info.aiEpoch + ":" + (cluster.map { $0.id + ":" + $0.aiEpoch } ?? "unlinked") + ":" + peerRevision)
    }

    private static func rosterInfos(_ groups: [[String: Any]]) -> [GroupInfo] {
        groups.map { GroupInfo(id: ($0["id"] as? String) ?? "", name: ($0["name"] as? String) ?? "",
                               frozen: ($0["frozen"] as? Bool) ?? false, timeState: $0["timeState"] as? [String: Any], custom: $0["groupType"] as? String == "custom", enabled: $0["enabled"] as? Bool == true, ruleAI: $0["ruleAI"] as? [String: Any]) }
    }

    /// Caller holds the canonical file lock, if one exists, then the hub lock.
    private func setRosterLocked(program: String, infos: [GroupInfo], document: [String: Any]?,
                                 save: ([String: Any]) throws -> Void) throws {
        let affected = clusters.values.filter { cluster in
            guard cluster.members.contains(program) else { return false }
            let pinned = cluster.memberGroupIds[program] ?? ""
            return pinned.isEmpty || !infos.contains(where: { $0.id == pinned })
        }
        for cluster in affected {
            if let refusal = browserIdentityUnlinkRefusalLocked(cluster) { throw GroupStoreError.invalidInput(refusal) }
        }
        try preserveDetachedLocalLocked(affected, removing: program, document: document, save: save)
        rosters[program] = infos.map { info in
            var next = info
            if let previous = rosters[program]?.first(where: { $0.id == info.id }), previous.enabled == info.enabled, previous.custom == info.custom,
               WebStoreDocument.canonicalJSON(previous.ruleAI ?? [:]) == WebStoreDocument.canonicalJSON(info.ruleAI ?? [:]) { next.aiEpoch = previous.aiEpoch }
            return next
        }
        rosterRevisions[program, default: 0] &+= 1
        let prefix = program + "/"
        var discarded = false
        for cluster in Array(clusters.values) {
            for member in cluster.detachedRuleTime.keys where member.hasPrefix(prefix) && !infos.contains(where: { $0.id == String(member.dropFirst(prefix.count)) }) {
                cluster.detachedRuleTime.removeValue(forKey: member); discarded = true
            }
            if cluster.members.isEmpty && cluster.detachedRuleTime.isEmpty { clusters.removeValue(forKey: cluster.id) }
        }
        for cluster in affected { removeMemberLocked(cluster, program: program) }
        if !affected.isEmpty || discarded { persistClustersLocked() }
        for cluster in affected { broadcastClusterLocked(clusterJSONObject(cluster)) }
        broadcastToPeersLocked(["kind": "rosters", "rosters": rostersJSONObjectLocked()])
        // All roster paths, including native document reconciliation, pass
        // here. The task runs after the caller releases the hub lock.
        Task { @MainActor in RuleAIService.shared.cancelInvalidRequests() }
    }

    private func withMembershipDocument<T>(_ operation: ([String: Any]?, ([String: Any]) throws -> Void) throws -> T) throws -> T {
        if let localWebStore {
            return try localWebStore.withLockedDocument { document, save in
                try withoutActuallyEscaping(save) { persist in try operation(document, persist) }
            }
        }
        return try operation(nil, { _ in })
    }

    /// File lock and hub lock are both held. Save the exact current native
    /// member before it leaves, including when another member's removal
    /// dissolves a two-member link. Never recreate a deleted local group.
    private func preserveDetachedLocalLocked(_ affected: [ClusterState], removing program: String,
                                             document: [String: Any]?, save: ([String: Any]) throws -> Void) throws {
        let old = affected.map { ($0, $0.detachedRuleTime) }
        do {
            try retainDetachedRuleTimeLocked(affected, removing: program)
            let detached = affected.filter {
                $0.members.contains(Self.localProgram) && (program == Self.localProgram || $0.members.count == 2)
            }
            guard !detached.isEmpty else { return }
            guard let document else {
                if localWebStoreValue != nil { throw GroupStoreError.invalidInput("local shared runtime cannot be preserved") }
                return
            }
            let nowMs = Date().timeIntervalSince1970 * 1000
            for cluster in detached { rollBudgetLocked(cluster, nowMs: nowMs); Self.countSnoozeLocked(cluster, nowMs: nowMs) }
            var retained = overlaySharedLocked(onto: document, clusters: detached, ownLinesOnly: true, nowMs: nowMs)
            var states = retained["cbRuleState"] as? [String: [String: Any]] ?? [:]
            let groups = retained["blockedGroups"] as? [[String: Any]] ?? []
            for cluster in detached {
                guard let id = cluster.memberGroupIds[Self.localProgram], groups.contains(where: { $0["id"] as? String == id && $0["groupType"] as? String == "custom" }),
                      !cluster.sharedRuleTime.isEmpty else { continue }
                var state = states[id] ?? [:]
                guard let final = finalRuleTimeLocked(cluster, program: Self.localProgram, groupID: id, seed: state["$vaultTime"] as? [String: Any])?["state"] as? [String: Any] else { throw GroupStoreError.invalidInput("Final custom time could not be preserved") }
                state["$vaultTime"] = final
                guard let data = try? JSONSerialization.data(withJSONObject: state), data.count <= 65536 else { throw GroupStoreError.invalidInput("Final time exceeds rule state capacity") }
                states[id] = state
            }
            retained["cbRuleState"] = states
            if WebStoreDocument.canonicalJSON(retained) != WebStoreDocument.canonicalJSON(document) { try save(retained) }
        } catch {
            for (cluster, snapshot) in old { cluster.detachedRuleTime = snapshot }
            throw error
        }
    }

    /// Caller must hold `lock`. Takes `program` out of the link; a link left
    /// with one member dissolves. A Mac group that leaves (or is left alone)
    /// is queued to keep only its own lines.
    private func invalidateRuleAIMembersLocked(_ cluster: ClusterState) {
        for (program, id) in cluster.memberGroupIds {
            if let index = rosters[program]?.firstIndex(where: { $0.id == id }) { rosters[program]?[index].aiEpoch = UUID().uuidString }
        }
        Task { @MainActor in RuleAIService.shared.cancelInvalidRequests() }
    }

    private func removeMemberLocked(_ cluster: ClusterState, program: String) {
        invalidateRuleAIMembersLocked(cluster)
        cluster.aiEpoch = UUID().uuidString
        if program == Self.localProgram, let id = cluster.memberGroupIds[program] {
            unlinkedLocal.insert(id)
            // Linked again later, it contributes afresh.
            localDefinitionSeen.removeValue(forKey: id)
        }
        if var confirmed = cluster.sharedRuleTime["confirmed"] as? [String: Any], let id = cluster.memberGroupIds[program] {
            confirmed.removeValue(forKey: program + "/" + id); cluster.sharedRuleTime["confirmed"] = confirmed
        }
        cluster.members.remove(program)
        cluster.memberGroupIds.removeValue(forKey: program)
        cluster.contributed.remove(program)
        cluster.originalUsagePending.remove(program)
        if Self.originalsReady(cluster) {
            cluster.joiningUsageBaseMs = nil
            cluster.joiningUsageDeltaMs = 0
            cluster.joiningSeedFloorMs = 0
            cluster.joiningBucketsBase = [:]
            cluster.joiningBucketDeltas = [:]
        }
        if cluster.members.count < 2 {
            if cluster.members.contains(Self.localProgram), let id = cluster.memberGroupIds[Self.localProgram] {
                unlinkedLocal.insert(id)
                localDefinitionSeen.removeValue(forKey: id)
            }
            if cluster.detachedRuleTime.isEmpty { clusters.removeValue(forKey: cluster.id) }
            cluster.members.removeAll()
            cluster.originalUsagePending.removeAll()
        }
    }

    /// The Mac's groups that are in a link now.
    func linkedLocalGroupIds() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return clusters.values.compactMap { $0.members.contains(Self.localProgram) ? $0.memberGroupIds[Self.localProgram] : nil }
    }

    /// The Mac groups that left a link since the last call.
    func takeUnlinkedLocalGroups() -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        let ids = unlinkedLocal
        unlinkedLocal = []
        return ids
    }

    /// Caller must hold `lock`. Every program's groups, for the Link picker.
    private func rostersJSONObjectLocked() -> [String: Any] {
        rosters.mapValues { infos in infos.map { ["id": $0.id, "name": $0.name, "frozen": $0.frozen] as [String: Any] } }
    }

    /// Caller holds the hub lock; recipients belong to this captured state.
    private func broadcastToPeersLocked(_ payload: [String: Any]) {
        enqueueLocked(payload, to: peers.values.filter { $0.connected }.map(\.connection))
    }

    // MARK: Links — made and removed by the user (owner 2026-09-27)

    private struct LinkIdentityPreflight {
        let program: String
        let groupID: String
        let targetProgram: String
        let targetGroupID: String
        let selectedGroups: [String: String]
        let peerIDs: [String: String]
        let revisions: [String: UInt64]
        let nativeID: String
        let nativeSignature: String
        let clusterSignature: String
        let deadlineUptime: UInt64
    }

    private final class LinkIdentityResponses {
        private let lock = NSLock()
        private var definitions: [String: LocalDefinition] = [:]
        private var refusal: String?
        func record(_ program: String, definition: LocalDefinition?, refusal: String?) {
            lock.lock(); defer { lock.unlock() }
            if let definition { definitions[program] = definition }
            if let refusal, self.refusal == nil { self.refusal = refusal }
        }
        func result() -> ([String: LocalDefinition], String?) {
            lock.lock(); defer { lock.unlock() }; return (definitions, refusal)
        }
    }

    private static func definitionSignature(_ definition: LocalDefinition?) -> String {
        guard let definition else { return "" }
        return WebStoreDocument.canonicalJSON(["scalars": definition.scalars, "scopes": definition.scopes, "lock": definition.lock])
    }

    private func linkClusterSignatureLocked(program: String, groupID: String, targetProgram: String, targetGroupID: String) -> String {
        let selected = [clusterLocked(program: program, groupId: groupID), clusterLocked(program: targetProgram, groupId: targetGroupID)].compactMap { $0 }
        return WebStoreDocument.canonicalJSON(selected.map { cluster in
            ["id": cluster.id, "members": cluster.members.sorted(), "groups": cluster.memberGroupIds,
             "scalars": cluster.sharedScalars, "scopes": cluster.sharedScopes, "ts": cluster.sharedTs, "lock": cluster.sharedLock] as [String: Any]
        })
    }

    private func nativeLinkDefinitionLocked(document: [String: Any]?, groupID: String) -> LocalDefinition? {
        if let group = (document?["blockedGroups"] as? [[String: Any]])?.first(where: { $0["id"] as? String == groupID }) {
            return Self.localDefinition(group)
        }
        return localWebStoreValue == nil ? localDefinitionSeen[groupID] : nil
    }

    /// Reads actual selected browser definitions before a potentially affected
    /// first link. The normal Link operation completes asynchronously; no hub
    /// or UI thread waits on a browser, and no tentative membership is created.
    func linkGroupsWithBrowserIdentityPreflight(program: String, groupId: String, targetProgram: String, targetGroupId: String,
                                                completion: @escaping (String?) -> Void) {
        var plan: LinkIdentityPreflight?
        var immediate: String?
        do {
            try withMembershipDocument { document, _ in
                self.lock.lock(); defer { self.lock.unlock() }
                guard self.localWebStoreValue == nil || document != nil else { immediate = "local-storage-unavailable"; return }
                guard !program.isEmpty, program != targetProgram, !groupId.isEmpty, !targetGroupId.isEmpty,
                      self.rosters[program]?.contains(where: { $0.id == groupId }) == true,
                      self.rosters[targetProgram]?.contains(where: { $0.id == targetGroupId }) == true else {
                    immediate = "group-not-found"; return
                }
                let existing = self.clusterLocked(program: program, groupId: groupId) ?? self.clusterLocked(program: targetProgram, groupId: targetGroupId)
                var selected = existing?.memberGroupIds ?? [:]
                selected[program] = groupId; selected[targetProgram] = targetGroupId
                let members = Set(selected.keys)
                let nativeID = selected[Self.localProgram] ?? ""
                let native = self.nativeLinkDefinitionLocked(document: document, groupID: nativeID)
                let legacy = self.peers.values.filter { $0.connected && $0.browserIdentity == nil && Self.requiresBrowserIdentityProof($0.program) && members.contains($0.program) }
                // This hypothetical Website only decides whether a read is
                // necessary. Admission below uses the real returned scopes.
                var potential = native?.scalars ?? existing?.sharedScalars ?? [:]
                potential["mode"] = "after-minutes"; potential["groupType"] = "site"
                let appScopes = (existing?.sharedScopes ?? []) + (native?.scopes ?? [])
                let needsRead = legacy.contains {
                    self.browserIdentityBudgetPredicate(potential, appScopes + [["surface": "site", "sites": [], "sitesExcept": true]], $0.program)
                }
                guard needsRead else {
                    immediate = self.linkGroupsLocked(program: program, groupId: groupId, targetProgram: targetProgram, targetGroupId: targetGroupId,
                                                      verifiedNativeDefinition: native)
                    return
                }
                let browsers = self.peers.values.filter { $0.connected && Self.browserPrograms.contains($0.program) && members.contains($0.program) }
                let peerIDs = Dictionary(uniqueKeysWithValues: browsers.map { ($0.program, $0.id) })
                let browserGroups = selected.filter { peerIDs[$0.key] != nil }
                plan = LinkIdentityPreflight(program: program, groupID: groupId, targetProgram: targetProgram, targetGroupID: targetGroupId,
                    selectedGroups: browserGroups, peerIDs: peerIDs,
                    revisions: Dictionary(uniqueKeysWithValues: selected.keys.map { ($0, self.rosterRevisions[$0] ?? 0) }),
                    nativeID: nativeID, nativeSignature: Self.definitionSignature(native),
                    clusterSignature: self.linkClusterSignatureLocked(program: program, groupID: groupId, targetProgram: targetProgram, targetGroupID: targetGroupId),
                    deadlineUptime: DispatchTime.now().uptimeNanoseconds + UInt64(Self.browserRelayTimeoutSeconds + 1) * 1_000_000_000)
            }
        } catch { completion("local-storage-unavailable"); return }
        guard let plan else { completion(immediate); return }
        let responses = LinkIdentityResponses()
        let pending = DispatchGroup()
        for (browser, groupID) in plan.selectedGroups {
            pending.enter()
            sendBrowserRequest(operation: "settings-get", body: [:], targetProgram: plan.peerIDs[browser]) { result in
                defer { pending.leave() }
                switch result {
                case .failure(let reason): responses.record(browser, definition: nil, refusal: reason)
                case .success(let body):
                    guard let groups = body["groups"] as? [[String: Any]],
                          let group = groups.first(where: { $0["id"] as? String == groupID }),
                          group["scopes"] is [[String: Any]] else {
                        responses.record(browser, definition: nil, refusal: "group-not-found"); return
                    }
                    responses.record(browser, definition: Self.localDefinition(group), refusal: nil)
                }
            }
        }
        pending.notify(queue: queue) { [weak self] in
            guard let self else { completion("macapp-unavailable"); return }
            guard DispatchTime.now().uptimeNanoseconds < plan.deadlineUptime else { completion("browser-timeout"); return }
            let (definitions, refusal) = responses.result()
            if let refusal { completion(refusal); return }
            var result: String?
            do {
                try self.withMembershipDocument { document, _ in
                    self.lock.lock(); defer { self.lock.unlock() }
                    guard self.localWebStoreValue == nil || document != nil else { result = "local-storage-unavailable"; return }
                    let native = self.nativeLinkDefinitionLocked(document: document, groupID: plan.nativeID)
                    guard plan.revisions.allSatisfy({ (self.rosterRevisions[$0.key] ?? 0) == $0.value }),
                          plan.peerIDs.allSatisfy({ program, id in self.peers.values.contains { $0.connected && $0.program == program && $0.id == id } }),
                          Self.definitionSignature(native) == plan.nativeSignature,
                          self.linkClusterSignatureLocked(program: program, groupID: groupId, targetProgram: targetProgram, targetGroupID: targetGroupId) == plan.clusterSignature else {
                        result = "link-target-changed"; return
                    }
                    result = self.linkGroupsLocked(program: program, groupId: groupId, targetProgram: targetProgram, targetGroupId: targetGroupId,
                                                  verifiedBrowserDefinitions: definitions, verifiedNativeDefinition: native)
                }
            } catch { result = "local-storage-unavailable" }
            completion(result)
        }
    }

    /// Links a group with a group of another program (the Link button or a
    /// tool). The initiator's settings win the first merge; the lines of both
    /// are unioned. Refused while either group or the link is locked, for a
    /// group already in another link, and for a second group of one program.
    /// Returns the refusal, or nil.
    // Internal synchronous core for isolated tests and the checked async path.
    // Every production Link entry point uses the authenticated preflight below.
    func linkGroups(program: String, groupId: String, targetProgram: String, targetGroupId: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return linkGroupsLocked(program: program, groupId: groupId, targetProgram: targetProgram, targetGroupId: targetGroupId)
    }

    private func linkGroupsLocked(program: String, groupId: String, targetProgram: String, targetGroupId: String,
                                  verifiedBrowserDefinitions: [String: LocalDefinition] = [:], verifiedNativeDefinition: LocalDefinition? = nil) -> String? {
        guard clusterStorageWritable else { return "unsupported-storage" }
        guard !program.isEmpty, !targetProgram.isEmpty, program != targetProgram, !groupId.isEmpty, !targetGroupId.isEmpty else { return "invalid-link" }
        guard let own = rosters[program]?.first(where: { $0.id == groupId }),
              let other = rosters[targetProgram]?.first(where: { $0.id == targetGroupId }) else { return "group-not-found" }
        if own.frozen || other.frozen { return "group-locked" }
        let ownCluster = clusterLocked(program: program, groupId: groupId)
        let otherCluster = clusterLocked(program: targetProgram, groupId: targetGroupId)
        if let ownCluster, let otherCluster {
            return ownCluster === otherCluster ? "already-linked" : "linked-elsewhere"
        }
        if let existing = ownCluster ?? otherCluster {
            if WebStoreDocument.isLocked(existing.sharedLock) { return "group-locked" }
            let joining = ownCluster == nil ? program : targetProgram
            if existing.members.contains(joining) { return "program-already-linked" }
        }
        let existing = ownCluster ?? otherCluster
        let members = (existing?.members ?? []).union([program, targetProgram])
        let nativeID = existing?.memberGroupIds[Self.localProgram]
            ?? (program == Self.localProgram ? groupId : targetProgram == Self.localProgram ? targetGroupId : nil)
        let native = verifiedNativeDefinition ?? nativeID.flatMap { localDefinitionSeen[$0] }
        let nativeScopes = (native?.scopes ?? []).filter { Self.lineOwner(line: $0) == "desktop" }
        let initiatingProgram = existing?.initiator.isEmpty == false ? existing!.initiator : program
        let firstScalars = initiatingProgram == Self.localProgram ? native?.scalars : verifiedBrowserDefinitions[initiatingProgram]?.scalars
        let browserScopes = verifiedBrowserDefinitions.values.flatMap { $0.scopes.filter { Self.lineOwner(line: $0) != "desktop" } }
        let initiatorPolicyKnown = existing.map { $0.contributed.contains($0.initiator) && !$0.sharedScalars.isEmpty } ?? false
        let initialPolicy = initiatorPolicyKnown ? existing!.sharedScalars : firstScalars ?? [:]
        if initialPolicy["mode"] as? String == "after-minutes", initialPolicy["groupType"] as? String != "custom",
           initialPolicy["rollingLimit"] as? Bool == true {
            let unsafe = peers.filter { _, peer in
                peer.connected && !peer.supportsOriginalUsage && Self.browserPrograms.contains(peer.program) && members.contains(peer.program)
                    && (existing?.members.contains(peer.program) != true || existing?.originalUsagePending.contains(peer.program) == true)
            }
            if !unsafe.isEmpty {
                for (key, peer) in unsafe { retireOriginalUsagePeerLocked(key, peer: peer) }
                broadcastPeersLocked()
                return "browser-upgrade-required"
            }
        }
        if browserIdentityPauseRequiredLocked(scalars: existing?.sharedScalars.isEmpty == false ? existing!.sharedScalars : firstScalars ?? [:],
                                             scopes: (existing?.sharedScopes ?? []) + nativeScopes + browserScopes, members: members) {
            return "browser-upgrade-required"
        }
        let initiatingID = existing?.memberGroupIds[initiatingProgram] ?? groupId
        let joining: [(String, String, GroupInfo)] = [(program, groupId, own), (targetProgram, targetGroupId, other)]
            .filter { existing?.members.contains($0.0) != true }
        let seeds = joining.map { ["member": $0.0 + "/" + $0.1,
                                  "state": self.prelinkRuleTimeLocked(program: $0.0, groupID: $0.1, seed: $0.2.timeState)] as [String: Any] }
        let previousTime: Any
        if let existing, !existing.sharedRuleTime.isEmpty { previousTime = existing.sharedRuleTime }
        else { previousTime = NSNull() }
        var timeState: [String: Any] = [:]
        let seededTime = seeds.contains { !(($0["state"] as? [String: Any])?["objects"] as? [String: Any] ?? [:]).isEmpty }
        if existing?.sharedRuleTime.isEmpty == false || seededTime {
            guard let merged = GroupActionsRuntime.shared.call("mergeTime", [
                previousTime,
                seeds, initiatingProgram + "/" + initiatingID, (Date().timeIntervalSince1970 * 1000).rounded(.down)
            ], module: "RuleCore") as? [String: Any], merged["ok"] as? Bool == true,
                  let mergedState = merged["state"] as? [String: Any] else { return "incompatible-custom-time" }
            timeState = mergedState
        }
        let before = clusters.mapValues { $0.editorCopy() }
        let cluster = ownCluster ?? otherCluster ?? {
            let created = ClusterState(id: UUID().uuidString, groupName: own.name)
            created.initiator = program
            clusters[created.id] = created
            return created
        }()
        // A new join window starts from the current authoritative budget.
        // Existing linked members' counters are already included in this base.
        if cluster.joiningUsageBaseMs == nil {
            cluster.joiningUsageBaseMs = cluster.sharedUsageMs
            cluster.joiningUsageDeltaMs = 0
            cluster.joiningSeedFloorMs = 0
            cluster.joiningBucketsBase = cluster.sharedBuckets
            cluster.joiningBucketDeltas = [:]
        }
        for member in [program, targetProgram] where !cluster.members.contains(member) && Self.browserPrograms.contains(member) {
            cluster.originalUsagePending.insert(member)
        }
        cluster.members.formUnion([program, targetProgram])
        cluster.aiEpoch = UUID().uuidString
        cluster.memberGroupIds[program] = groupId
        cluster.memberGroupIds[targetProgram] = targetGroupId
        invalidateRuleAIMembersLocked(cluster)
        cluster.sharedRuleTime = timeState
        persistClustersLocked()
        guard clusterStorageWritable else {
            clusters = before; return "local-storage-unavailable"
        }
        broadcastClusterLocked(clusterJSONObject(cluster))
        return nil
    }

    /// Takes a group out of its link (the Unlink button or a tool). Both keep
    /// the shared settings; each keeps only its own program's lines. Refused
    /// while the link is locked.
    func unlinkGroup(program: String, groupId: String, requestingPeerKey: ObjectIdentifier? = nil) -> String? {
        guard clusterStorageWritable else { return "unsupported-storage" }
        do {
            let refusal = try withMembershipDocument { document, save -> String? in
                self.lock.lock(); defer { self.lock.unlock() }
                if let requestingPeerKey {
                    guard let requester = self.peers[requestingPeerKey], requester.connected, requester.program == program else { return "browser-unavailable" }
                }
                guard let cluster = self.clusterLocked(program: program, groupId: groupId) else { return "not-linked" }
                if let refusal = self.browserIdentityUnlinkRefusalLocked(cluster) { return refusal }
                if WebStoreDocument.isLocked(cluster.sharedLock) { return "group-locked" }
                if let pinned = cluster.memberGroupIds[Self.localProgram],
                   let native = (document?["blockedGroups"] as? [[String: Any]])?.first(where: { ($0["id"] as? String) == pinned }),
                   ((native["lockVersion"] as? NSNumber)?.intValue ?? 0) > ((cluster.sharedLock["lockVersion"] as? NSNumber)?.intValue ?? 0),
                   WebStoreDocument.isLocked(native) { return "group-locked" }
                let before = self.clusters.mapValues { $0.editorCopy() }
                let oldUnlinked = self.unlinkedLocal, oldSeen = self.localDefinitionSeen
                do {
                    try self.preserveDetachedLocalLocked([cluster], removing: program, document: document, save: save)
                    self.removeMemberLocked(cluster, program: program)
                    self.persistClustersLocked()
                    guard self.clusterStorageWritable else { throw GroupStoreError.invalidInput("cluster-storage-unavailable") }
                    self.broadcastClusterLocked(self.clusterJSONObject(cluster))
                    return nil
                } catch {
                    self.clusters = before; self.unlinkedLocal = oldUnlinked; self.localDefinitionSeen = oldSeen
                    throw error
                }
            }
            return refusal
        } catch { return "local-storage-unavailable" }
    }

    /// Caller must hold `lock`.
    private func clusterLocked(program: String, groupId: String) -> ClusterState? {
        clusters.values.first { $0.members.contains(program) && $0.memberGroupIds[program] == groupId }
    }

    /// Number of live clusters (≥2 members). Used to warn the user before
    /// quitting, since quitting stops the hub and breaks links until relaunch.
    func activeClusterCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return clusters.values.filter { $0.members.count >= 2 }.count
    }

    /// Folds one member's contribution into the cluster's shared state and, if the
    /// shared snapshot changed, broadcasts it. This is the heart of the sync
    /// engine: scalars and scope lines are latest-edit-wins (a member's FIRST
    /// contribution unions its entries into the shared lines, so two groups that
    /// existed separately keep both sides' entries when they link), and the usage
    /// counter is a delta accumulator (the Mac is the budget authority).
    func applySync(program: String, groupId: String, contribution: [String: Any], ts: Double,
                   browserIdentity: BrowserApplicationIdentity? = nil) {
        lock.lock(); defer { lock.unlock() }
        applySyncLocked(program: program, groupId: groupId, contribution: contribution, ts: ts, browserIdentity: browserIdentity)
    }

    /// The caller holds the hub lock. Rebase and application of native intent
    /// use this same critical section, so an intervening browser edit cannot
    /// be overwritten by a frame prepared against an older shared snapshot.
    private func applySyncLocked(program: String, groupId: String, contribution: [String: Any], ts: Double,
                                 browserIdentity: BrowserApplicationIdentity? = nil) {
        guard !program.isEmpty, !groupId.isEmpty else { return }
        guard let cluster = clusterLocked(program: program, groupId: groupId) else {
            return
        }

        let before = clusterJSONObject(cluster)
        let pendingBefore = cluster.originalUsagePending.contains(program) ? cluster.editorCopy() : nil
        var contribution = contribution
        let paused = browserIdentityPauseRequiredLocked(cluster)
        let alreadyContributed = cluster.contributed.contains(program)
        if paused {
            contribution.removeValue(forKey: "snooze")
            contribution.removeValue(forKey: "snoozeTs")
            if alreadyContributed {
                contribution.removeValue(forKey: "lock")
                contribution.removeValue(forKey: "lockBase")
            }
        }
        if contribution["scalars"] != nil || contribution["scopes"] != nil {
            let owner = Self.lineOwner(program: program)
            let proposedScalars = contribution["scalars"] as? [String: Any] ?? cluster.sharedScalars
            let proposedScopes = (contribution["scopes"] as? [[String: Any]]).map { own in
                cluster.sharedScopes.filter { Self.lineOwner(line: $0) != owner } + own.filter { Self.lineOwner(line: $0) == owner }
            } ?? cluster.sharedScopes
            let wouldPause = browserIdentityPauseRequiredLocked(scalars: proposedScalars, scopes: proposedScopes, members: cluster.members)
            if alreadyContributed && (paused || wouldPause) {
                // Legacy consumers echo effective enabled=false as config.
                // Neither that echo nor an affected edit is canonical intent.
                for field in ["scalars", "scopes", "lock", "lockBase"] { contribution.removeValue(forKey: field) }
            } else if paused && !cluster.sharedScalars.isEmpty {
                // A joining original retains its own lines and history. Its
                // cached scalars cannot replace an established shared policy.
                contribution.removeValue(forKey: "scalars")
            }
        }
        // A pause stops new usage on every member, while tagged handovers and
        // original seeds still preserve eligible history measured previously.
        if paused && contribution["usageTransferId"] == nil && contribution["usageDeltaAnchorMs"] == nil {
            contribution.removeValue(forKey: "usageDeltaMs")
            contribution.removeValue(forKey: "usageBuckets")
        }

        // Definition contributions (scalars / scopes) only update when the
        // message actually carries them. Lightweight usage-only pings (sent by
        // the browser background when its popup is closed) must NOT clobber the
        // member's stored contribution.
        let scalarsPayload = contribution["scalars"] as? [String: Any]
        let scopesPayload = contribution["scopes"] as? [[String: Any]]
        let carriesConfig = scalarsPayload != nil || scopesPayload != nil
        let firstContribution = carriesConfig && !cluster.contributed.contains(program)
        // Timestamp zero is the original-definition handshake, not an edit.
        // A reconnect can repeat it before the late initiator has advanced the
        // shared timestamp; replay must not replace other members' originals.
        if carriesConfig && (firstContribution || ts != 0) {
            // The group whose Link button made the link: its settings win.
            let priority = firstContribution && program == cluster.initiator
            let wins = priority || ts >= cluster.sharedTs
            let scalarsBefore = cluster.sharedScalars
            cluster.contributed.insert(program)

            // Scalars: last writer wins, except the link initiator's settings
            // win the first merge.
            if let scalars = scalarsPayload {
                if priority {
                    cluster.sharedScalars = scalars
                    cluster.sharedTs = max(cluster.sharedTs, ts) + 1
                } else if ts >= cluster.sharedTs,
                          !(firstContribution && cluster.contributed.contains(cluster.initiator)) {
                    cluster.sharedScalars = scalars
                    cluster.sharedTs = ts
                }
            }
            let aiFields = ["ruleAI", "enabled", "groupType"]
            if WebStoreDocument.canonicalJSON(scalarsBefore.filter { aiFields.contains($0.key) }) != WebStoreDocument.canonicalJSON(cluster.sharedScalars.filter { aiFields.contains($0.key) }) {
                cluster.aiEpoch = UUID().uuidString
            }
            if let name = cluster.sharedScalars["name"] as? String, !name.isEmpty { cluster.groupName = name }
            // A changed budget (the editor's own rule, group-actions.js
            // budgetRestarts) restarts the shared budget for every device:
            // linked groups are one group.
            if !firstContribution, !scalarsBefore.isEmpty,
               GroupActionsRuntime.shared.call("budgetRestarts", [scalarsBefore, cluster.sharedScalars]) as? Bool == true {
                cluster.sharedUsageMs = 0
                if cluster.joiningUsageBaseMs != nil { cluster.joiningUsageBaseMs = 0; cluster.joiningUsageDeltaMs = 0 }
                cluster.joiningBucketsBase = [:]
                cluster.joiningBucketDeltas = [:]
                // The new period starts on the group's own grid (with midnight
                // re-anchoring that is today's grid, not this instant), as every
                // program computes it — else each would see a different period.
                let nowMs = (Date().timeIntervalSince1970 * 1000).rounded(.down)
                cluster.sharedUsageResetAtMs = Self.sharedPeriodStartMs(anchorMs: nowMs, scalars: cluster.sharedScalars, nowMs: nowMs).rounded(.down)
                if cluster.joiningUsageBaseMs != nil { cluster.joiningSeedFloorMs = cluster.sharedUsageResetAtMs }
                cluster.sharedBuckets = [:]
                cluster.usageSeeded = true
                cluster.bucketsSeeded = true
            }
            // Lines follow the scope line (owner 2026-09-27): a member brings
            // and edits only its own program's lines (Mac Vault the Apps lines,
            // a browser every other); the other program's stay as they are. A
            // first contribution joins its lines to those of its kind already
            // shared (union by entry); afterwards the latest edit wins.
            if let scopes = scopesPayload {
                let owner = Self.lineOwner(program: program)
                let own = scopes.filter { Self.lineOwner(line: $0) == owner }
                let theirs = cluster.sharedScopes.filter { Self.lineOwner(line: $0) != owner }
                if firstContribution {
                    cluster.sharedScopes = theirs + Self.unionOriginalScopes(
                        cluster.sharedScopes.filter { Self.lineOwner(line: $0) == owner }, incoming: own,
                        origins: &cluster.scopeOrigins, origin: Self.scopeOrigin(program: program, groupID: groupId, entry: ""),
                        preferIncomingBase: priority, retainedSeed: cluster.id)
                } else if wins {
                    cluster.sharedScopes = theirs + own
                    for line in own where (line["surface"] as? String) == "site" {
                        let key = Self.scopeEntryKey(line)
                        if cluster.scopeOrigins[key] == nil { cluster.scopeOrigins[key] = Self.scopeOrigin(program: program, groupID: groupId, entry: key) }
                    }
                }
                let surviving = Set(cluster.sharedScopes.filter { ($0["surface"] as? String) == "site" }.map(Self.scopeEntryKey))
                cluster.scopeOrigins = cluster.scopeOrigins.filter { surviving.contains($0.key) }
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
        // total back into each member's local counter produces no echo; the
        // whole-browser rule below handles nested website time. A newer
        // reset anchor rolls the whole budget over.
        // The hub owns the shared period: a member's anchor only seeds it when
        // the hub has none yet; from then on only the hub starts a new period.
        if cluster.sharedUsageResetAtMs == 0, let anchor = contribution["usageResetAtMs"] as? Double, anchor > 0 {
            cluster.sharedUsageResetAtMs = anchor.rounded(.down)
        }
        let nowMs = Date().timeIntervalSince1970 * 1000
        rollBudgetLocked(cluster, nowMs: nowMs)
        let transferID = contribution["usageTransferId"] as? String
        let transferKey = transferID.flatMap { !$0.isEmpty && $0.count <= 128 ? "\(program):\($0)" : nil }
        let receiptLifetime = max(86_400_000, ((cluster.sharedScalars["resetIntervalHours"] as? NSNumber)?.doubleValue ?? 24) * 10_800_000)
        cluster.usageTransferReceipts = cluster.usageTransferReceipts.filter { $0.value >= nowMs - receiptLifetime }
        let duplicateTransfer = transferKey.map { cluster.usageTransferReceipts[$0] != nil } ?? false
        // Time a browser counted while the hub was away arrives tagged with
        // its period: added only when that period is still the current one.
        let deltaPeriod = (contribution["usageDeltaAnchorMs"] as? NSNumber)?.doubleValue
        // The hub and extensions run on this same Mac. When the native Apps
        // line counts the whole browser, its frontmost-app sampler already
        // covers any website time from that browser. Keep offline handovers:
        // they were measured while the native sampler was unavailable.
        let browserCoveredByApp = deltaPeriod == nil && transferKey == nil &&
            Self.browserPrograms.contains(program) && Self.countsWholeBrowser(cluster.sharedScopes, program: program, browserIdentity: browserIdentity)
        let rollingOriginal = (cluster.sharedScalars["rollingLimit"] as? Bool) == true
        let absoluteSeed = contribution["usageMs"] as? Double
        let historySeed = UsageBudget.parseBuckets(contribution["usageBucketsSeed"])
        let firstUsageOriginal = cluster.originalUsagePending.contains(program) && transferKey == nil
            && (rollingOriginal ? historySeed != nil : absoluteSeed.map { $0.isFinite && $0 >= 0 } == true)
        var admittedOriginalUsage = false
        if !duplicateTransfer, !browserCoveredByApp, !(firstUsageOriginal && !rollingOriginal),
           let delta = contribution["usageDeltaMs"] as? Double, delta != 0,
           deltaPeriod == nil || deltaPeriod!.rounded(.down) == cluster.sharedUsageResetAtMs.rounded(.down) {
            // Nonpending/native reports keep their delta-or-seed contract.
            // A pending browser absolute includes its delta and seeds once.
            if (cluster.sharedScalars["rollingLimit"] as? Bool) != true {
                Self.countBudgetSnoozeLocked(cluster, beforeMs: cluster.sharedUsageMs, addedMs: delta, nowMs: nowMs)
            }
            cluster.sharedUsageMs = max(0, cluster.sharedUsageMs + delta)
            if cluster.joiningUsageBaseMs != nil { cluster.joiningUsageDeltaMs += delta }
            cluster.usageSeeded = true
        } else if !duplicateTransfer, (!browserCoveredByApp || firstContribution || firstUsageOriginal),
                  let seed = absoluteSeed, seed.isFinite, seed >= 0,
                  (!cluster.usageSeeded || firstContribution || firstUsageOriginal) {
            // An observed expired original completes retention, but cannot seed
            // usage back into a later authoritative period.
            if cluster.joiningSeedFloorMs == 0 || ((contribution["usageResetAtMs"] as? Double) ?? 0) >= cluster.joiningSeedFloorMs {
                if let base = cluster.joiningUsageBaseMs {
                    cluster.joiningUsageBaseMs = max(base, seed)
                    cluster.sharedUsageMs = max(0, max(base, seed) + cluster.joiningUsageDeltaMs)
                } else if seed > cluster.sharedUsageMs { cluster.sharedUsageMs = seed }
                cluster.usageSeeded = true
            }
            if !rollingOriginal { admittedOriginalUsage = firstUsageOriginal }
        }
        let rollingPolicy = BlockGroup(
            id: "", groupType: .site, name: "", enabled: true, mode: .afterMinutes,
            allowedMinutes: 0,
            resetIntervalHours: (cluster.sharedScalars["resetIntervalHours"] as? NSNumber)?.doubleValue ?? 24,
            resetAtMidnight: (cluster.sharedScalars["resetAtMidnight"] as? Bool) == true
        )
        let rollingBefore = UsageBudget.usedMs(UsageBudget.pruneBuckets(cluster.sharedBuckets, group: rollingPolicy, nowMs: nowMs))
        if !duplicateTransfer {
            var bucketContribution = contribution
            if browserCoveredByApp {
                bucketContribution.removeValue(forKey: "usageBuckets")
                if !firstContribution && !firstUsageOriginal { bucketContribution.removeValue(forKey: "usageBucketsSeed") }
            }
            applyBucketContributionLocked(cluster, bucketContribution, firstContribution: firstContribution || firstUsageOriginal)
            if rollingOriginal && firstUsageOriginal,
               (UsageBudget.parseBuckets(bucketContribution["usageBuckets"]) ?? [:]).isEmpty { admittedOriginalUsage = true }
        }
        if !duplicateTransfer, !browserCoveredByApp, (cluster.sharedScalars["rollingLimit"] as? Bool) == true,
           let deltas = UsageBudget.parseBuckets(contribution["usageBuckets"]), !deltas.isEmpty {
            let rollingAfter = UsageBudget.usedMs(UsageBudget.pruneBuckets(cluster.sharedBuckets, group: rollingPolicy, nowMs: nowMs))
            Self.countBudgetSnoozeLocked(cluster, beforeMs: rollingBefore, addedMs: max(0, rollingAfter - rollingBefore), nowMs: nowMs)
        }

        // Active snooze: newest start wins. A member only carries `snoozeTs` when
        // it actually has an active/cooling snooze entry, so usage-only pings and
        // members without a snooze never clobber a snooze started elsewhere.
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
        if admittedOriginalUsage { cluster.originalUsagePending.remove(program) }
        if cluster.members.isSubset(of: cluster.contributed), !Self.requiresOriginalBudgetUsage(cluster) { cluster.originalUsagePending.removeAll() }
        if Self.originalsReady(cluster) {
            cluster.joiningUsageBaseMs = nil
            cluster.joiningUsageDeltaMs = 0
            cluster.joiningSeedFloorMs = 0
            cluster.joiningBucketsBase = [:]
            cluster.joiningBucketDeltas = [:]
        }
        if let transferKey { cluster.usageTransferReceipts[transferKey] = nowMs }
        // Receipts and the usage they acknowledge are saved together before
        // the snapshot lets a sender remove its durable outbox batch.
        if carriesConfig || transferKey != nil || admittedOriginalUsage { persistClustersLocked() }
        if admittedOriginalUsage, !clusterStorageWritable, let pendingBefore {
            clusters[cluster.id] = pendingBefore
            enqueueLocked(["kind": "group-sync-refused", "groupId": groupId, "reason": "local-storage-unavailable"],
                          to: peers.values.filter { $0.connected && $0.program == program }.map(\.connection))
            return
        }
        retireUnsafeRollingOriginalPeersLocked(cluster)
        let after = clusterJSONObject(cluster)
        if !NSDictionary(dictionary: before).isEqual(to: after) || paused != browserIdentityPauseRequiredLocked(cluster) {
            broadcastClusterLocked(after)
        }
    }

    /// The entry a scope line belongs to: "apps" for the app list, "site" for
    /// the website list, else its platform id.
    static func scopeEntryKey(_ line: [String: Any]) -> String {
        if (line["surface"] as? String) == "site" {
            if let entry = line["entryID"] as? String,
               entry.range(of: "^site:[A-Za-z0-9_-]{1,80}$", options: .regularExpression) != nil { return entry }
            return "site"
        }
        if let entry = line["entryID"] as? String, !entry.isEmpty { return entry }
        if (line["surface"] as? String) == "apps" { return "apps" }
        if let platform = line["platform"] as? String, !platform.isEmpty { return platform }
        return "site"
    }

    /// Union of two line lists by entry: entries only `existing` names are kept,
    /// entries `incoming` names come from `incoming`. Line ids are renumbered per
    /// surface so the merged list has unique ids.
    /// The owner of a line (group-scopes.js lineOwner) and of a program's lines.
    static func lineOwner(line: [String: Any]) -> String {
        (line["surface"] as? String) == "apps" ? "desktop" : "browser"
    }
    static func lineOwner(program: String) -> String {
        program == localProgram ? "desktop" : "browser"
    }

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

    /// Independent original lists are OR branches at first join. Compatible
    /// include lists for the same entry keep every target; acknowledged edits
    /// still use replacement and can intentionally delete a target.
    private static func unionCompatibleOriginalScopes(_ existing: [[String: Any]], incoming: [[String: Any]]) -> [[String: Any]] {
        let adjusted = incoming.map { line -> [String: Any] in
            let key = scopeEntryKey(line)
            let old = existing.filter { scopeEntryKey($0) == key }
            guard old.count == 1, incoming.filter({ scopeEntryKey($0) == key }).count == 1 else { return line }
            let target: String
            if (line["surface"] as? String) == "site", (line["sitesExcept"] as? Bool) != true { target = "sites" }
            else if (line["surface"] as? String) == "apps", (line["appsExcept"] as? Bool) != true { target = "apps" }
            else { return line }
            var oldShape = old[0]; var newShape = line
            for field in ["id", "entryID", target] { oldShape.removeValue(forKey: field); newShape.removeValue(forKey: field) }
            let except = target == "sites" ? "sitesExcept" : "appsExcept"
            guard (oldShape[except] as? Bool) != true,
                  (oldShape["action"] as? String ?? "block") == "block",
                  (newShape["action"] as? String ?? "block") == "block" else { return line }
            for field in [except, "action"] { oldShape.removeValue(forKey: field); newShape.removeValue(forKey: field) }
            if oldShape["platform"] is NSNull { oldShape.removeValue(forKey: "platform") }
            if newShape["platform"] is NSNull { newShape.removeValue(forKey: "platform") }
            guard WebStoreDocument.canonicalJSON(oldShape) == WebStoreDocument.canonicalJSON(newShape) else { return line }
            var merged = line
            if target == "sites" {
                var seen = Set<String>()
                merged[target] = ((old[0][target] as? [String] ?? []) + (line[target] as? [String] ?? [])).filter { seen.insert($0).inserted }
            } else {
                var seen = Set<String>()
                merged[target] = ((old[0][target] as? [[String: Any]] ?? []) + (line[target] as? [[String: Any]] ?? [])).filter {
                    guard let id = $0["id"] as? String else { return false }
                    return seen.insert(id).inserted
                }
            }
            return merged
        }
        return unionScopes(existing, incoming: adjusted)
    }


    static func scopeOrigin(program: String, groupID: String, entry: String) -> String {
        program + "\0" + groupID + "\0" + entry
    }

    static func originalScopeAlias(origin: String) -> String {
        "site:linked_" + SHA256.hash(data: Data(origin.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private static func entryContent(_ lines: [[String: Any]]) -> [String] {
        lines.map { line in
            var copy = line; copy.removeValue(forKey: "id"); copy.removeValue(forKey: "entryID")
            if (copy["surface"] as? String) == "site" {
                if copy["platform"] is NSNull { copy.removeValue(forKey: "platform") }
                if (copy["action"] as? String ?? "block") == "block" { copy.removeValue(forKey: "action") }
                if (copy["sitesExcept"] as? Bool) != true { copy.removeValue(forKey: "sitesExcept") }
                // Target order and duplicates do not change a Website branch.
                // Normalize only comparison, never its stored predicate.
                copy["sites"] = Array(Set(copy["sites"] as? [String] ?? [])).sorted()
            }
            return WebStoreDocument.canonicalJSON(copy)
        }.sorted()
    }

    static func unionOriginalScopes(_ existing: [[String: Any]], incoming: [[String: Any]]) -> [[String: Any]] {
        var origins: [String: String] = [:]
        return unionOriginalScopes(existing, incoming: incoming, origins: &origins,
                                   origin: scopeOrigin(program: "", groupID: "", entry: ""))
    }

    /// Website originals with different predicates/actions stay independent OR
    /// entries. Existing aliases survive adoption/rejoin unchanged. Only the
    /// first initiator may claim the unqualified Website entry from an earlier
    /// original; ordinary acknowledged edits still replace all browser lines.
    static func unionOriginalScopes(_ existing: [[String: Any]], incoming: [[String: Any]],
                                    origins: inout [String: String], origin: String,
                                    preferIncomingBase: Bool = false, retainedSeed: String = "") -> [[String: Any]] {
        let sites = incoming.filter { ($0["surface"] as? String) == "site" }
        let nonSites = incoming.filter { ($0["surface"] as? String) != "site" }
        var result = unionCompatibleOriginalScopes(existing, incoming: nonSites)
        var reserved = Set((existing + incoming).map(scopeEntryKey))
        var keys: [String] = []
        for line in sites { let key = scopeEntryKey(line); if !keys.contains(key) { keys.append(key) } }
        func lines(_ key: String) -> [[String: Any]] { result.filter { scopeEntryKey($0) == key } }
        func source(_ key: String) -> String { origin + key }
        func retag(_ entry: [[String: Any]], _ key: String) -> [[String: Any]] {
            entry.map { var copy = $0; copy["entryID"] = key; return copy }
        }
        func alias(_ seed: String, _ entry: [[String: Any]]) -> String {
            let stem = originalScopeAlias(origin: seed)
            var key = stem; var suffix = 2
            while reserved.contains(key) {
                if !lines(key).isEmpty && entryContent(lines(key)) == entryContent(entry) { return key }
                key = stem + "_" + String(suffix); suffix += 1
            }
            reserved.insert(key); return key
        }
        for key in keys {
            let added = sites.filter { scopeEntryKey($0) == key }
            let prior = lines(key)
            if prior.isEmpty {
                result += added; origins[key] = source(key); continue
            }
            let compatible = unionCompatibleOriginalScopes(prior, incoming: added)
            // The compatible helper only unions included block lists. Check its
            // actual result against the incoming shape before using replacement.
            let oldLine = prior.count == 1 ? prior[0] : [:]
            let newLine = added.count == 1 ? added[0] : [:]
            let joinedTargets = compatible.first?["sites"] as? [String] ?? []
            let oldTargets = oldLine["sites"] as? [String] ?? []
            let newTargets = newLine["sites"] as? [String] ?? []
            var oldShape = oldLine, newShape = newLine
            for field in ["id", "entryID", "sites", "sitesExcept", "action"] {
                oldShape.removeValue(forKey: field); newShape.removeValue(forKey: field)
            }
            if oldShape["platform"] is NSNull { oldShape.removeValue(forKey: "platform") }
            if newShape["platform"] is NSNull { newShape.removeValue(forKey: "platform") }
            let canUnion = prior.count == 1 && added.count == 1 &&
                (oldLine["sitesExcept"] as? Bool) != true && (newLine["sitesExcept"] as? Bool) != true &&
                (oldLine["action"] as? String ?? "block") == "block" && (newLine["action"] as? String ?? "block") == "block" &&
                WebStoreDocument.canonicalJSON(oldShape) == WebStoreDocument.canonicalJSON(newShape) &&
                Set(oldTargets + newTargets).isSubset(of: Set(joinedTargets))
            if canUnion || entryContent(prior) == entryContent(added) {
                result.removeAll { scopeEntryKey($0) == key }; result += canUnion ? compatible : prior
                if origins[key] == nil || preferIncomingBase && key == "site" { origins[key] = source(key) }
                continue
            }
            if preferIncomingBase && key == "site" {
                let seed = origins[key] ?? "retained\0" + retainedSeed + "\0" + key
                let retainedKey = alias(seed, prior)
                result.removeAll { scopeEntryKey($0) == key }
                if lines(retainedKey).isEmpty { result += retag(prior, retainedKey) }
                if let priorOrigin = origins.removeValue(forKey: key), origins[retainedKey] == nil { origins[retainedKey] = priorOrigin }
                result += added; origins[key] = source(key)
            } else {
                let addedKey = alias(source(key), added)
                if lines(addedKey).isEmpty { result += retag(added, addedKey); origins[addedKey] = source(key) }
            }
        }
        let surviving = Set(result.filter { ($0["surface"] as? String) == "site" }.map(scopeEntryKey))
        origins = origins.filter { surviving.contains($0.key) }
        return unionScopes([], incoming: result)
    }


    /// The policy settings a linked group shares: group-scopes.js
    /// SYNC_SCALAR_FIELDS, the one list (read from the editor's code).
    static let syncScalarFields: [String] = {
        let fields = GroupActionsRuntime.shared.constant("SYNC_SCALAR_FIELDS", module: "CBGroupScopes") as? [String] ?? []
        precondition(!fields.isEmpty, "group-scopes.js is not bundled")
        return fields
    }()

    /// The Mac's roster last given to the hub (canonical JSON).
    private var lastLocalRoster = ""

    private struct LocalDefinition {
        var scalars: [String: Any]
        var scopes: [[String: Any]]
        var lock: [String: Any]
    }
    /// Exact stored definitions observed, or successfully adopted. They are
    /// the common base for pending explicit changes, not a publication clock.
    private var localDefinitionSeen: [String: LocalDefinition] = [:]

    private static func localDefinition(_ group: [String: Any]) -> LocalDefinition {
        var scalars: [String: Any] = [:]
        for field in syncScalarFields where group[field] != nil { scalars[field] = group[field] }
        var unit: [String: Any] = [:]
        if group["lockVersion"] != nil {
            for field in WebStoreDocument.lockFieldNames { unit[field] = group[field] ?? NSNull() }
        }
        return LocalDefinition(scalars: scalars, scopes: group["scopes"] as? [[String: Any]] ?? [], lock: unit)
    }

    private static func localDefinitionJSON(_ group: [String: Any]) -> [String: Any] {
        let definition = localDefinition(group)
        return ["scalars": definition.scalars, "scopes": definition.scopes, "lock": definition.lock]
    }

    /// An owned canonical store ignores a stale tick snapshot: capture,
    /// contribution and adoption share the existing file -> hub transaction.
    func contributeLocalDefinitions(document: [String: Any], nowMs: Double) {
        if let store = localWebStore { _ = reconcileLocalStore(store, nowMs: nowMs); return }
        // Explicit transport-only fixtures have no canonical persistence owner.
        lock.lock(); defer { lock.unlock() }
        reconcileDefinitionsLocked(document: document, nowMs: nowMs)
    }

    @discardableResult
    private func reconcileLocalStore(_ store: BlockerWebStore, nowMs: Double) -> Bool {
        guard localWebStore === store else { return false }
        do {
            return try store.withLockedDocument { stored, save in
                // withLockedDocument preserves unsupported bytes by presenting
                // nil; never turn the caller's old document into a fallback.
                guard var document = stored else { return false }
                self.lock.lock(); defer { self.lock.unlock() }
                guard self.localWebStoreValue === store else { return false }
                return try self.reconcileLocalDocumentLocked(&document, nowMs: nowMs, save: save)
            }
        } catch { return false }
    }

    /// Caller owns the canonical file lock and hub lock. A staged editor writer
    /// captures intermediate documents without touching the file until commit.
    private func reconcileLocalDocumentLocked(_ document: inout [String: Any], nowMs: Double,
                                               save: ([String: Any]) throws -> Void) throws -> Bool {
        guard let groups = Self.canonicalLocalGroups(document) else { return false }
        let roster = Self.localRoster(groups, document: document)
        let rosterKey = WebStoreDocument.canonicalJSON(roster)
        if rosterKey != self.lastLocalRoster {
            try self.setRosterLocked(program: Self.localProgram, infos: Self.rosterInfos(roster), document: document) { updated in
                try save(updated)
                document = updated
            }
            self.lastLocalRoster = rosterKey
        }
        self.reconcileDefinitionsLocked(document: document, nowMs: nowMs, updateRoster: false)
        let adopted = self.overlaySharedLocked(onto: document, clusters: Array(self.clusters.values), ownLinesOnly: false, nowMs: nowMs)
        var next = document
        for key in BlockerWebStore.sharedAdoptionKeys where adopted[key] != nil { next[key] = adopted[key] }
        let changed = BlockerWebStore.sharedAdoptionKeys.contains {
            WebStoreDocument.canonicalJSON(next[$0]) != WebStoreDocument.canonicalJSON(document[$0])
        }
        if changed { try save(next) }
        // Only an exact successful saved (or unchanged) document can
        // advance adoption. First-original definitions remain pending.
        self.acknowledgeLocalAdoptionLocked(next)
        document = next
        return changed
    }

    /// Synchronous JavaScript admission and all native reconciliation run on
    /// copied hub state while the canonical file and hub locks are held. A
    /// refused request/save therefore cannot publish an intermediate snapshot.
    private func applyEditorDefinitionRequest(_ request: [String: Any], store: BlockerWebStore) throws -> [[String: Any]] {
        try store.withLockedDocument { raw, save in
            guard var document = raw, Self.canonicalLocalGroups(document) != nil else {
                throw GroupStoreError.invalidInput("local-storage-unavailable")
            }
            self.lock.lock(); defer { self.lock.unlock() }
            guard self.localWebStoreValue === store, self.editorStaging == nil else {
                throw GroupStoreError.invalidInput("native-editor-unavailable")
            }
            // A recognizable unsupported registry cannot be overwritten by
            // an editor transaction. UserDefaults has no physical durability
            // acknowledgment; successful file commit retains its existing API.
            let schema = StorageSchemaPolicy(format: "hub.clusters", currentSchema: 3)
            guard self.clusterStorageWritable,
                  self.registryDefaults.data(forKey: Self.clustersDefaultsKey).map({ (try? schema.payload(from: $0)) != nil }) ?? true else {
                throw GroupStoreError.invalidInput("cluster-storage-unavailable")
            }
            let oldClusters = self.clusters
            let oldRosters = self.rosters
            let oldRosterRevisions = self.rosterRevisions
            let oldSeen = self.localDefinitionSeen
            let oldRosterKey = self.lastLocalRoster
            let oldUnlinked = self.unlinkedLocal
            let oldPeers = self.peers
            let staging = EditorStaging()
            self.clusters = oldClusters.mapValues { $0.editorCopy() }
            self.editorStaging = staging
            do {
                let nowMs = (Date().timeIntervalSince1970 * 1000).rounded(.down)
                let capture: ([String: Any]) throws -> Void = { updated in
                    try SharedAppGroupStore.webSchema.validateFlat(updated)
                    guard JSONSerialization.isValidJSONObject(updated) else { throw GroupStoreError.invalidInput("invalid-web-store") }
                }
                _ = try self.reconcileLocalDocumentLocked(&document, nowMs: nowMs, save: capture)
                let before = document
                document = try BlockerWebStore.documentApplyingEditorRequest(document, request: request, nowMs: nowMs)
                let oldGroups = before["blockedGroups"] as? [[String: Any]] ?? []
                for group in document["blockedGroups"] as? [[String: Any]] ?? [] {
                    guard let id = group["id"] as? String,
                          let cluster = self.clusterLocked(program: Self.localProgram, groupId: id),
                          let old = oldGroups.first(where: { ($0["id"] as? String) == id }),
                          WebStoreDocument.canonicalJSON(Self.localDefinitionJSON(group)) != WebStoreDocument.canonicalJSON(Self.localDefinitionJSON(old)) else { continue }
                    let candidate = Self.localDefinition(group)
                    let scopes = cluster.sharedScopes.filter { Self.lineOwner(line: $0) != "desktop" }
                        + candidate.scopes.filter { Self.lineOwner(line: $0) == "desktop" }
                    if self.browserIdentityPauseRequiredLocked(cluster)
                        || self.browserIdentityPauseRequiredLocked(scalars: candidate.scalars, scopes: scopes, members: cluster.members) {
                        throw GroupStoreError.invalidInput("browser-upgrade-required")
                    }
                }
                let linked = self.clusters.values.compactMap { $0.members.contains(Self.localProgram) ? $0.memberGroupIds[Self.localProgram] : nil }
                document = BlockerWebStore.finishedEditorMutation(before: before, after: document, nowMs: nowMs, linkedGroupIds: linked)
                _ = try self.reconcileLocalDocumentLocked(&document, nowMs: nowMs, save: capture)
                guard Self.canonicalLocalGroups(document) != nil else { throw GroupStoreError.invalidInput("invalid-web-store") }
                try SharedAppGroupStore.webSchema.validateFlat(document)
                try save(document)
                self.editorStaging = nil
                if staging.persistRegistry { self.persistClustersLocked() }
                for frame in staging.frames { self.enqueueFrozenLocked(frame.data, to: frame.connections) }
                return document["blockedGroups"] as? [[String: Any]] ?? []
            } catch {
                self.clusters = oldClusters
                self.rosters = oldRosters
                self.rosterRevisions = oldRosterRevisions
                self.localDefinitionSeen = oldSeen
                self.lastLocalRoster = oldRosterKey
                self.unlinkedLocal = oldUnlinked
                self.peers = oldPeers
                self.editorStaging = nil
                throw error
            }
        }
    }

    /// A malformed scope payload cannot become an explicit empty Apps edit.
    /// Missing or empty scopes remain compatible original documents.
    private static func canonicalLocalGroups(_ document: [String: Any]) -> [[String: Any]]? {
        guard let groups = document["blockedGroups"] as? [[String: Any]] else { return nil }
        let ids = groups.compactMap { $0["id"] as? String }
        guard ids.count == groups.count, ids.allSatisfy({ !$0.isEmpty }), Set(ids).count == ids.count else { return nil }
        guard groups.allSatisfy({ $0["scopes"] == nil || $0["scopes"] is [[String: Any]] }) else { return nil }
        return groups
    }

    private static func localRoster(_ groups: [[String: Any]], document: [String: Any] = [:]) -> [[String: Any]] {
        groups.compactMap { group in
            guard let id = group["id"] as? String else { return nil }
            let states = document["cbRuleState"] as? [String: [String: Any]] ?? [:]
            return ["id": id, "name": (group["name"] as? String) ?? "", "frozen": WebStoreDocument.isLocked(group),
                    "groupType": group["groupType"] ?? "site", "enabled": group["enabled"] ?? false, "ruleAI": group["ruleAI"] ?? NSNull(),
                    "timeState": states[id]?["$vaultTime"] as? [String: Any] ?? ["version": 1, "objects": [:]]]
        }
    }

    private func acknowledgeLocalAdoptionLocked(_ document: [String: Any]) {
        let groups = document["blockedGroups"] as? [[String: Any]] ?? []
        for cluster in clusters.values where cluster.members.contains(Self.localProgram) && cluster.contributed.contains(Self.localProgram) {
            guard let id = cluster.memberGroupIds[Self.localProgram], let group = groups.first(where: { ($0["id"] as? String) == id }) else { continue }
            localDefinitionSeen[id] = Self.localDefinition(group)
        }
    }

    /// Caller holds the hub lock (and the canonical file lock, if present).
    /// Only fields changed against the exact stored common base are local
    /// intent; a stale untouched field cannot undo a newer browser edit.
    private func reconcileDefinitionsLocked(document: [String: Any], nowMs: Double, updateRoster: Bool = true) {
        let groups = document["blockedGroups"] as? [[String: Any]] ?? []
        let linked = Set(clusters.values.compactMap { $0.memberGroupIds[Self.localProgram] })
        for group in groups {
            if let id = group["id"] as? String, !linked.contains(id) { localDefinitionSeen[id] = Self.localDefinition(group) }
        }
        if updateRoster {
            let roster = Self.localRoster(groups, document: document)
            let key = WebStoreDocument.canonicalJSON(roster)
            if key != lastLocalRoster {
                do { try setRosterLocked(program: Self.localProgram, infos: Self.rosterInfos(roster), document: nil, save: { _ in }) }
                catch { return }
                lastLocalRoster = key
            }
        }
        for cluster in Array(clusters.values) where cluster.members.contains(Self.localProgram) {
            guard let id = cluster.memberGroupIds[Self.localProgram], let group = groups.first(where: { ($0["id"] as? String) == id }) else { continue }
            if let entry = (document["groupSnoozes"] as? [String: Any])?[id] as? [String: Any] {
                let changedAt = Self.snoozeChangeTs(entry)
                if changedAt > cluster.sharedSnoozeTs {
                    applySyncLocked(program: Self.localProgram, groupId: id, contribution: ["snooze": entry, "snoozeTs": changedAt], ts: 0)
                }
            }
            let raw = Self.localDefinition(group)
            let previous = localDefinitionSeen[id]
            let joined = cluster.contributed.contains(Self.localProgram)
            // The file actually contains this definition, even if a later
            // adoption save is refused. Do not republish the same accepted edit.
            localDefinitionSeen[id] = raw
            var scalars = raw.scalars
            let own = raw.scopes.filter { Self.lineOwner(line: $0) == "desktop" }
            var scopes = own
            var lockUnit = raw.lock
            if joined {
                guard let previous else { continue } // restart: first sight is no edit
                let scalarChanges = Self.syncScalarFields.filter {
                    WebStoreDocument.canonicalJSON(raw.scalars[$0]) != WebStoreDocument.canonicalJSON(previous.scalars[$0])
                }
                let oldOwn = previous.scopes.filter { Self.lineOwner(line: $0) == "desktop" }
                let appsChanged = WebStoreDocument.canonicalJSON(own) != WebStoreDocument.canonicalJSON(oldOwn)
                let lockChanged = WebStoreDocument.canonicalJSON(raw.lock) != WebStoreDocument.canonicalJSON(previous.lock)
                guard !scalarChanges.isEmpty || appsChanged || lockChanged else { continue }
                scalars = cluster.sharedScalars
                for field in scalarChanges { scalars[field] = raw.scalars[field] }
                if !appsChanged { scopes = cluster.sharedScopes.filter { Self.lineOwner(line: $0) == "desktop" } }
                if !lockChanged { lockUnit = [:] }
                let unchanged = WebStoreDocument.canonicalJSON(scalars) == WebStoreDocument.canonicalJSON(cluster.sharedScalars)
                    && WebStoreDocument.canonicalJSON(scopes) == WebStoreDocument.canonicalJSON(cluster.sharedScopes.filter { Self.lineOwner(line: $0) == "desktop" })
                    && (lockUnit.isEmpty || WebStoreDocument.canonicalJSON(lockUnit) == WebStoreDocument.canonicalJSON(cluster.sharedLock))
                if unchanged { continue }
            }
            var contribution: [String: Any] = ["scalars": scalars, "scopes": scopes]
            if !joined {
                contribution["usageMs"] = (document["usageTimersMs"] as? [String: Any])?[id] ?? 0
                if let anchor = (document["usageResetAtMs"] as? [String: Any])?[id] { contribution["usageResetAtMs"] = anchor }
                if let buckets = (document["usageBucketsMs"] as? [String: Any])?[id] { contribution["usageBucketsSeed"] = buckets }
            }
            if !lockUnit.isEmpty {
                contribution["lock"] = lockUnit
                contribution["lockBase"] = (group["lockSyncedVersion"] as? NSNumber)?.intValue ?? 0
            }
            applySyncLocked(program: Self.localProgram, groupId: id, contribution: contribution, ts: joined ? nowMs : 0)
        }
    }

    /// The stored document with each linked group's live shared definition
    /// (policy scalars and entry lines) and any newer shared snooze laid over
    /// it — what the editor would adopt if it were open. Mac enforcement reads
    /// through this, so a closed editor window never leaves the Mac enforcing a
    /// stale definition or missing a snooze started on another device.
    func overlayShared(onto document: [String: Any]) -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return overlaySharedLocked(onto: document, clusters: Array(clusters.values), ownLinesOnly: false,
                                   nowMs: Date().timeIntervalSince1970 * 1000)
    }

    /// Caller holds the hub lock. First-join originals remain intact until
    /// acknowledged; detaching snapshots preserve their own lines and unknown
    /// local fields while retaining shared settings and authoritative runtime.
    private func overlaySharedLocked(onto document: [String: Any], clusters selected: [ClusterState],
                                     ownLinesOnly: Bool, nowMs: Double) -> [String: Any] {
        var groups = document["blockedGroups"] as? [[String: Any]] ?? []
        guard !groups.isEmpty else { return document }
        var snoozes = document["groupSnoozes"] as? [String: Any] ?? [:]
        var snoozeTotals = document["groupSnoozeTotalsMs"] as? [String: Any] ?? [:]
        var timers = document["usageTimersMs"] as? [String: Any] ?? [:]
        var anchors = document["usageResetAtMs"] as? [String: Any] ?? [:]
        var buckets = document["usageBucketsMs"] as? [String: Any] ?? [:]
        var changed = false
        for cluster in selected where cluster.members.contains(Self.localProgram) {
            let pinned = cluster.memberGroupIds[Self.localProgram] ?? ""
            guard !pinned.isEmpty, let index = groups.firstIndex(where: { ($0["id"] as? String) == pinned }) else { continue }
            // Preserve the local original until its first contribution is
            // accepted, including across a restart during an interrupted join.
            let originalOwnLines = (groups[index]["scopes"] as? [[String: Any]] ?? []).filter { Self.lineOwner(line: $0) == "desktop" }
            if cluster.contributed.contains(Self.localProgram) || ownLinesOnly {
                for (field, value) in cluster.sharedScalars { groups[index][field] = value }
                if cluster.members.isSubset(of: cluster.contributed) { groups[index]["scopes"] = cluster.sharedScopes }
                // Detaching must not erase an unreported newer local lock
                // unit. Equal or newer shared versions remain authoritative,
                // including a shared unlock clearing the previous local PIN.
                let preserveLocalLock = ownLinesOnly &&
                    ((groups[index]["lockVersion"] as? NSNumber)?.intValue ?? 0) >
                    ((cluster.sharedLock["lockVersion"] as? NSNumber)?.intValue ?? 0)
                if !cluster.sharedLock.isEmpty && !preserveLocalLock {
                    for field in WebStoreDocument.lockFieldNames { groups[index][field] = cluster.sharedLock[field] ?? NSNull() }
                    groups[index]["lockSyncedVersion"] = cluster.sharedLock["lockVersion"]
                }
            }
            if ownLinesOnly {
                groups[index]["scopes"] = originalOwnLines
            }
            // Ending a snooze is authoritative even before this Mac's first
            // definition is acknowledged; it must not restart an old break.
            if cluster.sharedSnoozeTs > 0,
               cluster.sharedSnoozeTs > Self.snoozeChangeTs(snoozes[pinned] as? [String: Any]) {
                snoozes[pinned] = cluster.sharedSnooze
                snoozeTotals[pinned] = cluster.sharedSnoozeTotalMs
            }
            if cluster.contributed.contains(Self.localProgram) || ownLinesOnly {
                // Adoption does not accrue or seed usage. Disabled members
                // keep the same live budget, anchor, snooze and rolling history
                // as enabled members; unlinking cannot resurrect an old total.
                let id = pinned
                let policy = BlockGroup(id: id, groupType: .site, name: "", enabled: true, mode: .afterMinutes,
                                        allowedMinutes: 0,
                                        resetIntervalHours: (cluster.sharedScalars["resetIntervalHours"] as? NSNumber)?.doubleValue ?? 24,
                                        resetAtMidnight: (cluster.sharedScalars["resetAtMidnight"] as? Bool) == true)
                let currentBuckets = UsageBudget.pruneBuckets(cluster.sharedBuckets, group: policy, nowMs: nowMs)
                timers[id] = (cluster.sharedScalars["rollingLimit"] as? Bool) == true
                    ? UsageBudget.usedMs(currentBuckets) : max(0, cluster.sharedUsageMs)
                anchors[id] = cluster.sharedUsageResetAtMs > 0 ? cluster.sharedUsageResetAtMs : nil
                buckets[id] = UsageBudget.bucketJSON(currentBuckets)
                if ownLinesOnly || cluster.sharedSnoozeTs >= Self.snoozeChangeTs(snoozes[id] as? [String: Any]) {
                    snoozes[id] = cluster.sharedSnooze
                }
                snoozeTotals[id] = cluster.sharedSnoozeTotalMs
            }
            changed = true
        }
        guard changed else { return document }
        var overlaid = document
        overlaid["blockedGroups"] = groups
        overlaid["groupSnoozes"] = snoozes
        overlaid["groupSnoozeTotalsMs"] = snoozeTotals
        overlaid["usageTimersMs"] = timers
        overlaid["usageResetAtMs"] = anchors
        overlaid["usageBucketsMs"] = buckets
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
        contribution["groupId"] = groupID
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

    private func prelinkRuleTimeLocked(program: String, groupID: String, seed: [String: Any]?) -> [String: Any] {
        if seed?["detachedReceipt"] != nil { return seed ?? ["version": 1, "objects": [:]] }
        let member = program + "/" + groupID
        let latest = clusters.values.filter { $0.detachedRuleTime[member] != nil }.max {
            ($0.detachedRuleTime[member]?["atMs"] as? Double ?? 0) < ($1.detachedRuleTime[member]?["atMs"] as? Double ?? 0)
        }
        if let latest, let final = finalRuleTimeLocked(latest, program: program, groupID: groupID, seed: seed)?["state"] as? [String: Any] { return final }
        return seed ?? ["version": 1, "objects": [:]]
    }

    private func finalRuleTimeLocked(_ cluster: ClusterState, program: String, groupID: String,
                                     seed: [String: Any]?, acknowledged: Bool = false) -> [String: Any]? {
        let member = program + "/" + groupID
        guard let record = cluster.detachedRuleTime[member], let state = record["state"] as? [String: Any],
              let token = record["token"] as? String, let initiator = record["initiator"] as? String,
              let result = GroupActionsRuntime.shared.call("detachTime", [seed ?? ["version": 1, "objects": [:]], state,
                member, initiator, cluster.id, token, (Date().timeIntervalSince1970 * 1000).rounded(.down), acknowledged], module: "RuleCore") as? [String: Any],
              result["ok"] as? Bool == true, let final = result["state"] as? [String: Any] else { return nil }
        return ["linked": false, "detached": true, "clusterId": cluster.id, "state": final,
            "relinkClusterId": clusterLocked(program: program, groupId: groupID)?.id ?? "",
            "handoverPending": clusters.values.contains { $0.id != cluster.id && $0.detachedRuleTime[member] != nil }]
    }

    private func retainDetachedRuleTimeLocked(_ affected: [ClusterState], removing program: String) throws {
        var sequence = max((Date().timeIntervalSince1970 * 1000).rounded(.down),
            (clusters.values.flatMap { $0.detachedRuleTime.values }.compactMap { $0["atMs"] as? Double }.max() ?? 0) + 1)
        for cluster in affected where !cluster.sharedRuleTime.isEmpty {
            let leaving = cluster.members.count == 2 ? cluster.members : Set([program])
            for peer in leaving {
                guard let id = cluster.memberGroupIds[peer] else { continue }
                let member = peer + "/" + id
                let initiating = cluster.initiator + "/" + (cluster.memberGroupIds[cluster.initiator] ?? "")
                cluster.detachedRuleTime[member] = ["version": 1, "token": UUID().uuidString, "state": cluster.sharedRuleTime,
                    "initiator": initiating, "atMs": sequence]
            }
            sequence += 1
        }
        let retained = clusters.values.map { $0.detachedRuleTime }
        guard clusters.values.reduce(0, { $0 + $1.detachedRuleTime.count }) <= 1024,
              let bytes = try? JSONSerialization.data(withJSONObject: retained), bytes.count <= 8 * 1024 * 1024 else {
            throw GroupStoreError.invalidInput("Reconnect detached members before unlinking more groups")
        }
    }

    /// One serialized authenticated transaction for a linked time object.
    /// Pure RuleCore policy is shared with browser/native rule engines. No
    /// acknowledgment is returned before the registry includes its receipt.
    func syncRuleTime(program: String = ConnectionHub.localProgram, groupID: String,
                      clusterID: String? = nil, seed: [String: Any]?, commands: [[String: Any]],
                      usage: [String: Any]? = nil) -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        guard clusterStorageWritable, editorStaging == nil else { return ["linked": true, "ready": false, "clusterId": seed?["scope"] ?? clusterID ?? "unavailable"] }
        let receipt = seed?["detachedReceipt"] as? [String: Any]
        let memberKey = program + "/" + groupID
        // Drain old links in order, even if the member already sees a newer link.
        let discovered = clusters.values.filter { $0.detachedRuleTime[memberKey] != nil }.min {
            let left = $0.detachedRuleTime[memberKey]?["atMs"] as? Double ?? 0
            let right = $1.detachedRuleTime[memberKey]?["atMs"] as? Double ?? 0
            return left == right ? $0.id < $1.id : left < right
        }?.id
        let remembered = receipt?["clusterId"] as? String ?? discovered ?? seed?["scope"] as? String ?? (clusterID?.isEmpty == false ? clusterID : nil)
        if let remembered, let retired = clusters[remembered], let record = retired.detachedRuleTime[program + "/" + groupID] {
            let matched = receipt?["token"] as? String == record["token"] as? String
            guard let final = finalRuleTimeLocked(retired, program: program, groupID: groupID, seed: seed, acknowledged: matched) else {
                return ["linked": true, "ready": false, "clusterId": remembered, "error": "detached-time-refused"]
            }
            if matched {
                retired.detachedRuleTime.removeValue(forKey: program + "/" + groupID)
                if retired.members.count < 2 && retired.detachedRuleTime.isEmpty { clusters.removeValue(forKey: retired.id) }
                persistClustersLocked()
                guard clusterStorageWritable else { return ["linked": true, "ready": false, "clusterId": remembered] }
            }
            return final
        }
        if let receipt, clusterLocked(program: program, groupId: groupID)?.id != receipt["clusterId"] as? String {
            var final = seed ?? [:]; final.removeValue(forKey: "detachedReceipt")
            return ["linked": false, "detached": true, "clusterId": receipt["clusterId"] ?? "", "state": final,
                "relinkClusterId": clusterLocked(program: program, groupId: groupID)?.id ?? "",
                "handoverPending": clusters.values.contains { $0.detachedRuleTime[memberKey] != nil }]
        }
        guard let cluster = clusterLocked(program: program, groupId: groupID) else {
            if let remembered = seed?["scope"] as? String, !remembered.isEmpty { return ["linked": true, "ready": false, "clusterId": remembered] }
            return ["linked": false]
        }
        let unavailable: [String: Any] = ["linked": true, "ready": false, "clusterId": cluster.id]
        guard clusterStorageWritable, editorStaging == nil, commands.count <= 64,
              clusterID == nil || clusterID == cluster.id else { return unavailable }
        guard let body = try? JSONSerialization.data(withJSONObject: ["seed": seed as Any? ?? NSNull(), "commands": commands, "usage": usage as Any? ?? NSNull()]),
              body.count <= 96_000 else { return unavailable.merging(["error": "custom-time-request-too-large"]) { _, new in new } }
        let member = program + "/" + groupID
        let initiatorProgram = cluster.members.contains(cluster.initiator) ? cluster.initiator : cluster.members.sorted().first!
        let initiator = initiatorProgram + "/" + (cluster.memberGroupIds[initiatorProgram] ?? "")
        let members = cluster.members.sorted().map { $0 + "/" + (cluster.memberGroupIds[$0] ?? "") }
        let seeds = cluster.members.sorted().map { program -> [String: Any] in
            let id = cluster.memberGroupIds[program] ?? ""
            let saved = rosters[program]?.first { $0.id == id }?.timeState
            return ["member": program + "/" + id, "state": saved ?? ["version": 1, "objects": [:]]]
        }
        let enabled = cluster.sharedScalars["enabled"] as? Bool ?? true
        if !enabled && commands.contains(where: { !["ensure", "assign"].contains($0["op"] as? String ?? "") }) { return unavailable }
        let request: [String: Any] = ["member": member, "members": members, "initiator": initiator,
            "seed": seed ?? ["version": 1, "objects": [:]], "seeds": seeds,
            "commands": commands.filter { $0["scope"] as? String == cluster.id },
            "usage": enabled ? (usage as Any? ?? NSNull()) : NSNull(),
            "nowMs": (Date().timeIntervalSince1970 * 1000).rounded(.down)]
        let previous: Any = cluster.sharedRuleTime.isEmpty ? NSNull() : cluster.sharedRuleTime as Any
        guard let result = GroupActionsRuntime.shared.call("syncTime", [previous, request], module: "RuleCore") as? [String: Any],
              result["ok"] as? Bool == true, let state = result["state"] as? [String: Any] else {
            return unavailable.merging(["error": "custom-time-policy-refused"]) { _, new in new }
        }
        if WebStoreDocument.canonicalJSON(state) != WebStoreDocument.canonicalJSON(cluster.sharedRuleTime) {
            let before = cluster.sharedRuleTime
            cluster.sharedRuleTime = state
            persistClustersLocked()
            // UserDefaults is the existing cluster writer. Verify its exact
            // supported envelope; a refusal freezes new requests until repair.
            let saved = self.registryDefaults.data(forKey: Self.clustersDefaultsKey)
                .flatMap { try? StorageSchemaPolicy(format: "hub.clusters", currentSchema: 3).payload(from: $0) }
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] }
            guard let stored = saved?.first(where: { $0["id"] as? String == cluster.id })?["sharedRuleTime"] as? [String: Any],
                  WebStoreDocument.canonicalJSON(stored) == WebStoreDocument.canonicalJSON(state) else {
                cluster.sharedRuleTime = before; clusterStorageWritable = false
                return unavailable.merging(["error": "custom-time-save-failed"]) { _, new in new }
            }
            broadcastClusterLocked(clusterJSONObject(cluster))
        }
        return ["linked": true, "ready": result["ready"] as? Bool ?? false, "clusterId": cluster.id,
                "state": state, "acknowledgedSerial": result["acknowledgedSerial"] ?? 0]
    }

    /// The link a Mac group belongs to — matched by its pinned id, as the
    /// overlay and the contributions match it.
    private func localCluster(groupID: String) -> ClusterState? {
        guard !groupID.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return clusterLocked(program: Self.localProgram, groupId: groupID)
    }

    /// Folds a member's rolling usage into the cluster: `usageBuckets` are
    /// per-minute increments; `usageBucketsSeed` is a member's absolute history,
    /// used (max per minute) only until the first real increment arrives so a
    /// group that already had rolling usage keeps it when it links. Minutes older
    /// than any window the group can use (its interval, at least a day) are pruned.
    private func applyBucketContributionLocked(_ cluster: ClusterState, _ contribution: [String: Any], firstContribution: Bool = false) {
        if let deltas = UsageBudget.parseBuckets(contribution["usageBuckets"]), !deltas.isEmpty {
            for (minute, delta) in deltas {
                let next = (cluster.sharedBuckets[minute] ?? 0) + delta
                cluster.sharedBuckets[minute] = next > 0 ? next : nil
                if cluster.joiningUsageBaseMs != nil { cluster.joiningBucketDeltas[minute, default: 0] += delta }
            }
            cluster.bucketsSeeded = true
        } else if !cluster.bucketsSeeded || firstContribution,
                  cluster.joiningSeedFloorMs == 0 || ((contribution["usageResetAtMs"] as? Double) ?? 0) >= cluster.joiningSeedFloorMs,
                  let seed = UsageBudget.parseBuckets(contribution["usageBucketsSeed"]) {
            for (minute, used) in seed {
                if cluster.joiningUsageBaseMs != nil {
                    let base = max(used, cluster.joiningBucketsBase[minute] ?? 0)
                    cluster.joiningBucketsBase[minute] = base
                    cluster.sharedBuckets[minute] = max(0, base + (cluster.joiningBucketDeltas[minute] ?? 0))
                } else if used > (cluster.sharedBuckets[minute] ?? 0) { cluster.sharedBuckets[minute] = used }
            }
        }
        guard !cluster.sharedBuckets.isEmpty else { return }
        let intervalHours = (cluster.sharedScalars["resetIntervalHours"] as? NSNumber)?.doubleValue ?? 24
        let horizonMs = max(intervalHours, 24) * 3_600_000 + 60_000
        let cutoff = Date().timeIntervalSince1970 * 1000 - horizonMs
        cluster.sharedBuckets = cluster.sharedBuckets.filter { $0.key > cutoff }
        cluster.joiningBucketsBase = cluster.joiningBucketsBase.filter { $0.key > cutoff }
        cluster.joiningBucketDeltas = cluster.joiningBucketDeltas.filter { $0.key > cutoff }
    }

    /// The links and every program's groups (for the Link picker), pushed to
    /// the Mac's own web editor each tick.
    func clustersJSON() -> String {
        lock.lock()
        let payload: [String: Any] = ["clusters": clusters.values.filter { $0.members.count >= 2 }.map {
            browserIdentityProjectionLocked(clusterJSONObject($0))
        }, "rosters": rostersJSONObjectLocked()]
        lock.unlock()
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            return "{\"clusters\":[]}"
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
                groupId: frame["groupId"] as? String ?? "",
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
        if let editorStaging { editorStaging.persistRegistry = true; return }
        let arr: [[String: Any]] = clusters.values.map { c in
            [
                "id": c.id,
                "groupName": c.groupName,
                "initiator": c.initiator,
                "members": Array(c.members),
                "memberGroupIds": c.memberGroupIds,
                "contributed": Array(c.contributed),
                "originalUsagePending": Array(c.originalUsagePending),
                "sharedScalars": c.sharedScalars,
                "sharedScopes": c.sharedScopes,
                "scopeOrigins": c.scopeOrigins,
                "sharedLock": c.sharedLock,
                "sharedTs": c.sharedTs,
                "sharedSnooze": c.sharedSnooze,
                "sharedSnoozeTs": c.sharedSnoozeTs,
                "sharedSnoozeTotalMs": c.sharedSnoozeTotalMs,
                "snoozeCountedStartMs": c.snoozeCountedStartMs,
                "sharedUsageMs": c.sharedUsageMs,
                "sharedUsageResetAtMs": c.sharedUsageResetAtMs,
                "sharedBuckets": UsageBudget.bucketJSON(c.sharedBuckets),
                "sharedRuleTime": c.sharedRuleTime,
                "detachedRuleTime": c.detachedRuleTime,
                "usageSeeded": c.usageSeeded,
                "joiningUsageBaseMs": c.joiningUsageBaseMs as Any? ?? NSNull(),
                "joiningUsageDeltaMs": c.joiningUsageDeltaMs,
                "joiningSeedFloorMs": c.joiningSeedFloorMs,
                "joiningBucketsBase": UsageBudget.bucketJSON(c.joiningBucketsBase),
                "joiningBucketDeltas": UsageBudget.bucketJSON(c.joiningBucketDeltas),
                "usageTransferReceipts": c.usageTransferReceipts,
                "bucketsSeeded": c.bucketsSeeded
            ]
        }
        let schema = StorageSchemaPolicy(format: "hub.clusters", currentSchema: 3)
        guard clusterStorageWritable else { return }
        guard let payload = try? JSONSerialization.data(withJSONObject: arr, options: [.sortedKeys]),
              let data = try? schema.wrap(payload) else { clusterStorageWritable = false; return }
        guard data != lastPersistedClusters else { return }
        if let existing = self.registryDefaults.data(forKey: ConnectionHub.clustersDefaultsKey), (try? schema.payload(from: existing)) == nil { clusterStorageWritable = false; return }
        self.registryDefaults.set(data, forKey: ConnectionHub.clustersDefaultsKey)
        guard self.registryDefaults.synchronize(), self.registryDefaults.data(forKey: ConnectionHub.clustersDefaultsKey) == data else {
            clusterStorageWritable = false; return
        }
        lastPersistedClusters = data
    }

    /// Caller must hold `lock`. Rebuilds the cluster registry (and the running
    /// budgets) from disk when the hub starts.
    func restoreClustersLocked() {
        // The automatic links of v1 are dropped (owner 2026-09-27): each Mac
        // group in one keeps only its own lines, as after an Unlink.
        if let old = self.registryDefaults.data(forKey: ConnectionHub.droppedClustersDefaultsKey) {
            let arr = (try? JSONSerialization.jsonObject(with: old)) as? [[String: Any]] ?? []
            for obj in arr {
                if let id = (obj["memberGroupIds"] as? [String: String])?[Self.localProgram] { unlinkedLocal.insert(id) }
            }
            self.registryDefaults.removeObject(forKey: ConnectionHub.droppedClustersDefaultsKey)
        }
        guard let data = self.registryDefaults.data(forKey: ConnectionHub.clustersDefaultsKey),
              let payload = try? StorageSchemaPolicy(format: "hub.clusters", currentSchema: 3).payload(from: data),
              let arr = (try? JSONSerialization.jsonObject(with: payload)) as? [[String: Any]] else {
            if self.registryDefaults.data(forKey: ConnectionHub.clustersDefaultsKey) != nil { clusterStorageWritable = false }
            return
        }
        let storedRoot = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let storedSchema = ((storedRoot?["storageMetadata"] as? [String: Any])?["schemaVersion"] as? Int) ?? 0
        if storedSchema >= 3 && arr.contains(where: { $0["originalUsagePending"] == nil }) { clusterStorageWritable = false; return }
        let retainedRows = arr.compactMap { $0["detachedRuleTime"] as? [String: Any] }
        guard retainedRows.reduce(0, { $0 + $1.count }) <= 1024,
              let retainedBytes = try? JSONSerialization.data(withJSONObject: retainedRows), retainedBytes.count <= 8 * 1024 * 1024 else { clusterStorageWritable = false; return }
        // Optional old registries need no migration. A malformed present
        // provenance ledger is preserved read-only, never silently overwritten.
        for obj in arr where obj["scopeOrigins"] != nil {
            guard let origins = obj["scopeOrigins"] as? [String: String], origins.allSatisfy({ key, value in
                let parts = value.split(separator: "\0", omittingEmptySubsequences: false)
                return (key == "site" || key.range(of: "^site:[A-Za-z0-9_-]{1,80}$", options: .regularExpression) != nil) &&
                    parts.count == 3 && parts.allSatisfy { !$0.isEmpty && $0.count <= 128 } &&
                    Self.browserPrograms.contains(String(parts[0]))
            }) else { clusterStorageWritable = false; return }
        }
        for obj in arr {
            guard let id = obj["id"] as? String,
                  let groupName = obj["groupName"] as? String else { continue }
            // Registries written before 2026-09-24 carry a `groupType` and
            // per-member sites/apps pools; both are ignored (the definition is
            // re-shared by the members' next contribution).
            let cluster = ClusterState(id: id, groupName: groupName)
            cluster.initiator = (obj["initiator"] as? String) ?? ""
            if let members = obj["members"] as? [String] { cluster.members = Set(members) }
            if let ids = obj["memberGroupIds"] as? [String: String] { cluster.memberGroupIds = ids }
            // (Registries before 2026-09-26 kept each whole contribution.)
            cluster.contributed = Set(obj["contributed"] as? [String]
                ?? ((obj["contributions"] as? [String: Any]).map { Array($0.keys) } ?? []))
            if obj.keys.contains("originalUsagePending") {
                guard let pending = obj["originalUsagePending"] as? [String], pending.count <= Self.browserPrograms.count,
                      Set(pending).count == pending.count,
                      pending.allSatisfy({ Self.browserPrograms.contains($0) && cluster.members.contains($0) }) else { clusterStorageWritable = false; return }
                cluster.originalUsagePending = Set(pending)
            } else if !cluster.members.isSubset(of: cluster.contributed) {
                // Established historical rows already pooled their originals.
                cluster.originalUsagePending = cluster.members.intersection(Self.browserPrograms).subtracting(cluster.contributed)
            }
            if let scalars = obj["sharedScalars"] as? [String: Any] { cluster.sharedScalars = scalars }
            if let scopes = obj["sharedScopes"] as? [[String: Any]] { cluster.sharedScopes = scopes }
            let surviving = Set(cluster.sharedScopes.filter { ($0["surface"] as? String) == "site" }.map(Self.scopeEntryKey))
            cluster.scopeOrigins = (obj["scopeOrigins"] as? [String: String] ?? [:]).filter { surviving.contains($0.key) }
            if let lock = obj["sharedLock"] as? [String: Any] { cluster.sharedLock = lock }
            cluster.sharedTs = (obj["sharedTs"] as? Double) ?? 0
            if let snooze = obj["sharedSnooze"] as? [String: Any] { cluster.sharedSnooze = snooze }
            cluster.sharedSnoozeTs = (obj["sharedSnoozeTs"] as? Double) ?? 0
            cluster.sharedSnoozeTotalMs = (obj["sharedSnoozeTotalMs"] as? Double) ?? 0
            cluster.snoozeCountedStartMs = (obj["snoozeCountedStartMs"] as? Double) ?? 0
            cluster.sharedUsageMs = (obj["sharedUsageMs"] as? Double) ?? 0
            cluster.sharedUsageResetAtMs = (obj["sharedUsageResetAtMs"] as? Double) ?? 0
            cluster.sharedBuckets = UsageBudget.parseBuckets(obj["sharedBuckets"]) ?? [:]
            cluster.sharedRuleTime = obj["sharedRuleTime"] as? [String: Any] ?? [:]
            if obj["detachedRuleTime"] != nil {
                guard let retained = obj["detachedRuleTime"] as? [String: [String: Any]], retained.count <= 16,
                      retained.allSatisfy({ member, record in
                          let parts = member.split(separator: "/", maxSplits: 1)
                          return parts.count == 2 && !parts[1].isEmpty && (Self.browserPrograms.contains(String(parts[0])) || String(parts[0]) == Self.localProgram) &&
                              record["version"] as? Int == 1 && !(record["token"] as? String ?? "").isEmpty &&
                              (record["state"] as? [String: Any])?["version"] as? Int == 1 &&
                              (record["state"] as? [String: Any])?["objects"] is [String: Any] && !(record["initiator"] as? String ?? "").isEmpty &&
                              (record["atMs"] as? Double ?? -1) >= 0
                      }) else { clusterStorageWritable = false; return }
                cluster.detachedRuleTime = retained
            }
            cluster.usageSeeded = (obj["usageSeeded"] as? Bool) ?? false
            cluster.usageTransferReceipts = (obj["usageTransferReceipts"] as? [String: Double]) ?? [:]
            cluster.bucketsSeeded = (obj["bucketsSeeded"] as? Bool) ?? false
            if !Self.originalsReady(cluster) {
                cluster.joiningUsageBaseMs = (obj["joiningUsageBaseMs"] as? Double) ?? cluster.sharedUsageMs
                cluster.joiningUsageDeltaMs = (obj["joiningUsageDeltaMs"] as? Double) ?? 0
                cluster.joiningSeedFloorMs = (obj["joiningSeedFloorMs"] as? Double) ?? 0
                cluster.joiningBucketsBase = UsageBudget.parseBuckets(obj["joiningBucketsBase"]) ?? cluster.sharedBuckets
                cluster.joiningBucketDeltas = UsageBudget.parseBuckets(obj["joiningBucketDeltas"]) ?? [:]
            }
            // Only restore clusters that still have ≥2 members (a 1-member
            // cluster is meaningless and would never broadcast).
            if cluster.members.count >= 2 || !cluster.detachedRuleTime.isEmpty { clusters[id] = cluster }
        }
    }

    /// Caller must hold `lock`. Programs with a live connected peer, plus the Mac
    /// host itself (always online while the hub runs). Used to flag cluster
    /// members online/offline.
    private func onlineProgramsLocked() -> Set<String> {
        Set(peers.values.filter { $0.connected && !$0.program.isEmpty }.map(\.program)).union([Self.localProgram])
    }

    private static func requiresOriginalBudgetUsage(_ cluster: ClusterState) -> Bool {
        cluster.sharedScalars["groupType"] as? String != "custom" && cluster.sharedScalars["mode"] as? String == "after-minutes"
    }

    private static func originalsReady(_ cluster: ClusterState) -> Bool {
        cluster.members.isSubset(of: cluster.contributed)
            && (!requiresOriginalBudgetUsage(cluster) || cluster.originalUsagePending.isEmpty)
    }

    private func unsafeLegacyRollingOriginalLocked(_ cluster: ClusterState, program: String) -> Bool {
        cluster.originalUsagePending.contains(program) && Self.requiresOriginalBudgetUsage(cluster)
            && cluster.sharedScalars["rollingLimit"] as? Bool == true
            && cluster.contributed.contains(cluster.initiator)
    }

    private func retireOriginalUsagePeerLocked(_ key: ObjectIdentifier, peer: Peer) {
        peers[key]?.connected = false
        peers[key]?.browserIdentity = nil
        peers[key]?.browserIdentitySnapshots = [:]
        enqueueLocked(["kind": "rejected", "reason": "browser-upgrade-required"], to: [peer.connection])
        queue.asyncAfter(deadline: .now() + .milliseconds(100)) { peer.connection.cancel() }
    }

    /// A legacy rolling consumer cannot pause without replacing its unsent
    /// history. Close before any shared projection; completed links are safe.
    private func retireUnsafeRollingOriginalPeersLocked(_ cluster: ClusterState) {
        var retired = false
        for (key, peer) in peers where peer.connected && !peer.supportsOriginalUsage
            && unsafeLegacyRollingOriginalLocked(cluster, program: peer.program) {
            retireOriginalUsagePeerLocked(key, peer: peer)
            retired = true
        }
        if retired { broadcastPeersLocked() }
    }

    private func browserIdentityPauseRequiredLocked(scalars: [String: Any], scopes: [[String: Any]], members: Set<String>) -> Bool {
        peers.values.contains { peer in
            peer.connected && Self.browserPrograms.contains(peer.program) && members.contains(peer.program)
                && Self.requiresBrowserIdentityProof(peer.program) && peer.browserIdentity == nil && browserIdentityBudgetPredicate(scalars, scopes, peer.program)
        }
    }

    private func browserIdentityPauseRequiredLocked(_ cluster: ClusterState) -> Bool {
        browserIdentityPauseRequiredLocked(scalars: cluster.sharedScalars, scopes: cluster.sharedScopes, members: cluster.members)
    }

    /// Structural recognition also applies while disconnected: a persisted
    /// legacy disabled echo cannot be repaired safely by an offline unlink.
    /// The ACK proves durable bootstrap/recovery adoption, not every later
    /// usage tick. Updated clients serialize the final ordinary unlink state.
    private func browserIdentityUnlinkRefusalLocked(_ cluster: ClusterState) -> String? {
        let browsers = cluster.members.filter { Self.browserPrograms.contains($0) }.sorted()
        guard affectsBrowserBudgetLocked(cluster) else { return nil }
        let live = peers.values.filter { $0.connected }
        for program in browsers {
            guard let peer = live.first(where: { $0.program == program }) else { return "browser-connect-required" }
            guard !Self.requiresBrowserIdentityProof(program) || peer.browserIdentity != nil else { return "browser-upgrade-required" }
            guard let snapshot = peer.browserIdentitySnapshots[cluster.id], snapshot.applied,
                  snapshot.definitionReady, Self.originalsReady(cluster),
                  snapshot.paused == browserIdentityPauseRequiredLocked(cluster) else { return "browser-sync-required" }
        }
        return nil
    }

    private func affectsBrowserBudgetLocked(_ cluster: ClusterState) -> Bool {
        cluster.members.contains {
            Self.browserPrograms.contains($0) && browserIdentityBudgetPredicate(cluster.sharedScalars, cluster.sharedScopes, $0)
        }
    }

    /// Called under the file lock by explicit native/MCP/side-effect writers.
    /// Ordinary clock expiry and engine accounting never enter this gate.
    func mutationRefusal(before: [String: Any], after: [String: Any]) -> String? {
        lock.lock(); defer { lock.unlock() }
        let old = before["blockedGroups"] as? [[String: Any]] ?? []
        let updated = after["blockedGroups"] as? [[String: Any]] ?? []
        for cluster in clusters.values {
            guard let id = cluster.memberGroupIds[Self.localProgram],
                  let original = old.first(where: { $0["id"] as? String == id }) else { continue }
            let candidate = updated.first(where: { $0["id"] as? String == id })
            if candidate == nil, let refusal = browserIdentityUnlinkRefusalLocked(cluster) { return refusal }
            let definitionChanged = WebStoreDocument.canonicalJSON(original) != WebStoreDocument.canonicalJSON(candidate)
            let runtimeChanged = ["groupSnoozes", "usageTimersMs", "usageResetAtMs", "usageBucketsMs", "groupSnoozeTotalsMs"].contains { key in
                WebStoreDocument.canonicalJSON((before[key] as? [String: Any])?[id]) != WebStoreDocument.canonicalJSON((after[key] as? [String: Any])?[id])
            }
            guard definitionChanged || runtimeChanged else { continue }
            if browserIdentityPauseRequiredLocked(cluster) { return "browser-upgrade-required" }
            if let candidate {
                let definition = Self.localDefinition(candidate)
                let scopes = cluster.sharedScopes.filter { Self.lineOwner(line: $0) != "desktop" }
                    + definition.scopes.filter { Self.lineOwner(line: $0) == "desktop" }
                if browserIdentityPauseRequiredLocked(scalars: definition.scalars, scopes: scopes, members: cluster.members) { return "browser-upgrade-required" }
            }
        }
        return nil
    }

    private func browserIdentityTransitionPendingLocked(_ cluster: ClusterState) -> Bool {
        let paused = browserIdentityPauseRequiredLocked(cluster)
        let ready = Self.originalsReady(cluster)
        return peers.values.contains { peer in
            peer.connected && Self.browserPrograms.contains(peer.program)
                && peer.browserIdentitySnapshots[cluster.id].map { $0.paused != paused || $0.definitionReady != ready } == true
        }
    }

    /// Enforcement uses this transient projection after canonical adoption.
    /// It is never passed to a file writer, a detach snapshot or reconciliation.
    func runtimeGroups(_ groups: [BlockGroup]) -> [BlockGroup] {
        lock.lock(); defer { lock.unlock() }
        for cluster in clusters.values where browserIdentityTransitionPendingLocked(cluster) {
            broadcastClusterLocked(clusterJSONObject(cluster))
        }
        let paused = Set(clusters.values.compactMap { cluster -> String? in
            guard browserIdentityPauseRequiredLocked(cluster) else { return nil }
            return cluster.memberGroupIds[Self.localProgram]
        })
        return groups.map { group in
            guard paused.contains(group.id) else { return group }
            var effective = group
            effective.enabled = false
            return effective
        }
    }

    private func browserIdentitySnapshotAppliedLocked(peerKey: ObjectIdentifier, groupID: String, contribution: [String: Any]) -> Bool {
        guard let peer = peers[peerKey], peer.connected,
              let cluster = clusterLocked(program: peer.program, groupId: groupID),
              let expected = peer.browserIdentitySnapshots[cluster.id],
              expected.paused == browserIdentityPauseRequiredLocked(cluster),
              expected.definitionReady == Self.originalsReady(cluster),
              let ack = contribution["browserIdentitySnapshotApplied"] as? [String: Any],
              Set(ack.keys) == ["generation"],
              let generation = ack["generation"] as? String else { return false }
        guard generation == expected.generation else { return false }
        peers[peerKey]?.browserIdentitySnapshots[cluster.id]?.applied = true
        return true
    }

    /// Canonical serialization remains separate from the effective wire view.
    /// The generation belongs to one connection and cluster, and rotates only
    /// on bootstrap/completion or a pause/recovery transition, not on usage
    /// broadcasts. An original-retention ACK is not a full-union adoption ACK.
    private func browserIdentityProjectionLocked(_ snapshot: [String: Any], peerKey: ObjectIdentifier? = nil,
                                                 effectivePause: Bool = false) -> [String: Any] {
        guard let id = snapshot["id"] as? String, let cluster = clusters[id] else { return snapshot }
        let paused = browserIdentityPauseRequiredLocked(cluster)
        let ready = Self.originalsReady(cluster)
        if let peerKey, let peer = peers[peerKey], !peer.supportsOriginalUsage,
           cluster.originalUsagePending.contains(peer.program),
           (!cluster.members.isSubset(of: cluster.contributed) || unsafeLegacyRollingOriginalLocked(cluster, program: peer.program)) {
            var retained = snapshot; retained.removeValue(forKey: "shared"); return retained
        }
        var generation = "local"
        if let peerKey, let peer = peers[peerKey], Self.browserPrograms.contains(peer.program) {
            let prior = peer.browserIdentitySnapshots[id]
            if let prior, prior.paused == paused, prior.definitionReady == ready { generation = prior.generation }
            else {
                generation = UUID().uuidString
                peers[peerKey]?.browserIdentitySnapshots[id] = BrowserIdentitySnapshot(generation: generation, paused: paused, definitionReady: ready)
            }
        }
        var result = snapshot
        var shared = result["shared"] as? [String: Any] ?? [:]
        var scalars = shared["scalars"] as? [String: Any] ?? [:]
        shared["browserIdentityStatus"] = ["state": paused ? "upgrade-required" : "ready", "generation": generation,
            "canonicalEnabled": (scalars["enabled"] as? Bool) ?? true, "affectsBrowserBudget": affectsBrowserBudgetLocked(cluster)]
        if effectivePause && paused { scalars["enabled"] = false }
        shared["scalars"] = scalars
        if let peerKey, let peer = peers[peerKey], !peer.supportsOriginalUsage,
           cluster.originalUsagePending.contains(peer.program), Self.requiresOriginalBudgetUsage(cluster) {
            for field in ["usageMs", "usageResetAtMs", "usageBuckets"] { shared.removeValue(forKey: field) }
        }
        result["shared"] = shared
        return result
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
                    "contributed": cluster.contributed.contains($0) && (!Self.requiresOriginalBudgetUsage(cluster) || !cluster.originalUsagePending.contains($0))
                ] as [String: Any]
            }
        ]
        if hasShared || !cluster.sharedRuleTime.isEmpty || cluster.sharedUsageMs > 0
            || !cluster.sharedBuckets.isEmpty
            || cluster.sharedSnoozeTs > 0 || cluster.sharedSnoozeTotalMs > 0 || !cluster.usageTransferReceipts.isEmpty {
            var shared: [String: Any] = [
                "scalars": cluster.sharedScalars,
                "ts": cluster.sharedTs,
                "usageMs": cluster.sharedUsageMs,
                "usageResetAtMs": cluster.sharedUsageResetAtMs,
                "usageBuckets": UsageBudget.bucketJSON(cluster.sharedBuckets),
                "ruleTime": cluster.sharedRuleTime,
                "snooze": cluster.sharedSnooze,
                "snoozeTs": cluster.sharedSnoozeTs,
                "snoozeTotalMs": cluster.sharedSnoozeTotalMs
            ]
            // Publish the union only after every member brought its original
            // lines. Afterwards an empty list represents an explicit deletion.
            shared["usageTransferReceipts"] = cluster.usageTransferReceipts
            if cluster.members.isSubset(of: cluster.contributed) { shared["scopes"] = cluster.sharedScopes }
            if !cluster.sharedLock.isEmpty { shared["lock"] = cluster.sharedLock }
            dict["shared"] = shared
        }
        return dict
    }

    /// Caller holds the hub lock. The Mac's editor still polls clustersJSON.
    private func broadcastClusterLocked(_ snapshot: [String: Any]) {
        // Each browser owns a separate bootstrap generation, so its durable
        // adoption ACK cannot be borrowed from another connection.
        let destinations = peers.filter { $0.value.connected }
        if destinations.isEmpty {
            enqueueLocked(["kind": "cluster-updated", "cluster": snapshot], to: [])
        }
        for (key, peer) in destinations {
            let projected = Self.browserPrograms.contains(peer.program)
                ? browserIdentityProjectionLocked(snapshot, peerKey: key, effectivePause: true) : snapshot
            enqueueLocked(["kind": "cluster-updated", "cluster": projected], to: [peer.connection])
        }
    }

    /// Captures a full reconnect snapshot in the same ordered stream as updates.
    func sendClustersSnapshot(_ conn: NWConnection) {
        lock.lock()
        sendClustersSnapshotLocked(conn)
        lock.unlock()
    }

    /// Caller holds the hub lock, including while authenticating a new peer.
    private func sendClustersSnapshotLocked(_ conn: NWConnection) {
        let key = ObjectIdentifier(conn)
        let snapshots = clusters.values.filter { $0.members.count >= 2 }.map { cluster in
            let snapshot = clusterJSONObject(cluster)
            return Self.browserPrograms.contains(peers[key]?.program ?? "")
                ? browserIdentityProjectionLocked(snapshot, peerKey: key, effectivePause: true) : snapshot
        }
        enqueueLocked(["kind": "clusters", "clusters": snapshots,
                       "rosters": rostersJSONObjectLocked()], to: [conn])
    }

}
#endif
