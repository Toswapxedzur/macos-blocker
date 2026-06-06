import Foundation

#if canImport(EndpointSecurity) && os(macOS)
import EndpointSecurity
import Darwin
#endif

/// Wraps an Endpoint Security client that denies `exec` of blocked apps — the
/// kernel-enforced "Layer 1" that prevents a blocked app from ever launching.
///
/// This only *runs* inside a process that holds the
/// `com.apple.developer.endpoint-security.client` entitlement and runs as root
/// (the system extension / privileged daemon). It still *compiles* everywhere;
/// `start()` reports `.unavailable` / `.notEntitled` rather than crashing when
/// those conditions aren't met, so the rest of the app builds and runs normally.
public final class EndpointSecurityClient: @unchecked Sendable {
    public enum StartError: Error, Equatable {
        /// Built without the EndpointSecurity framework (non-macOS).
        case unavailable
        /// Missing `com.apple.developer.endpoint-security.client` entitlement.
        case notEntitled
        /// Not running as root.
        case notPrivileged
        /// TCC / SIP / not approved as a System Extension.
        case notPermitted
        case tooManyClients
        case subscribeFailed
        case internalError(Int32)
    }

    /// Guarded snapshot of the active policy. The ES callback runs on an
    /// internal dispatch queue, so reads/writes are serialized by this lock.
    private let lock = NSLock()
    private var policy: GuardPolicy
    /// Optional callback invoked (off the main thread) when a launch is denied.
    private let onDeny: ((_ bundleIdentifier: String?, _ path: String?) -> Void)?

    #if canImport(EndpointSecurity) && os(macOS)
    private var client: OpaquePointer?
    #endif

    public init(
        policy: GuardPolicy = GuardPolicy(),
        onDeny: ((_ bundleIdentifier: String?, _ path: String?) -> Void)? = nil
    ) {
        self.policy = policy
        self.onDeny = onDeny
    }

    /// Hot-swaps the policy consulted on every `exec`. Cheap and lock-guarded,
    /// so the control plane can push updates without restarting the client.
    public func update(policy newPolicy: GuardPolicy) {
        lock.lock()
        policy = newPolicy
        lock.unlock()
    }

    private func currentPolicy() -> GuardPolicy {
        lock.lock()
        defer { lock.unlock() }
        return policy
    }

    public func start() throws {
        #if canImport(EndpointSecurity) && os(macOS)
        guard client == nil else { return }

        var newClient: OpaquePointer?
        let result = es_new_client(&newClient) { [weak self] client, message in
            self?.handle(client: client, message: message)
        }

        switch result {
        case ES_NEW_CLIENT_RESULT_SUCCESS:
            break
        case ES_NEW_CLIENT_RESULT_ERR_NOT_ENTITLED:
            throw StartError.notEntitled
        case ES_NEW_CLIENT_RESULT_ERR_NOT_PRIVILEGED:
            throw StartError.notPrivileged
        case ES_NEW_CLIENT_RESULT_ERR_NOT_PERMITTED:
            throw StartError.notPermitted
        case ES_NEW_CLIENT_RESULT_ERR_TOO_MANY_CLIENTS:
            throw StartError.tooManyClients
        default:
            throw StartError.internalError(Int32(bitPattern: result.rawValue))
        }

        guard let created = newClient else {
            throw StartError.internalError(-1)
        }
        client = created

        var events = [ES_EVENT_TYPE_AUTH_EXEC]
        let subscribed = events.withUnsafeBufferPointer { buffer in
            es_subscribe(created, buffer.baseAddress!, UInt32(buffer.count))
        }
        guard subscribed == ES_RETURN_SUCCESS else {
            es_delete_client(created)
            client = nil
            throw StartError.subscribeFailed
        }
        #else
        throw StartError.unavailable
        #endif
    }

    public func stop() {
        #if canImport(EndpointSecurity) && os(macOS)
        if let client {
            es_unsubscribe_all(client)
            es_delete_client(client)
            self.client = nil
        }
        #endif
    }

    #if canImport(EndpointSecurity) && os(macOS)
    private func handle(client: OpaquePointer, message: UnsafePointer<es_message_t>) {
        guard message.pointee.event_type == ES_EVENT_TYPE_AUTH_EXEC else {
            return
        }
        let target = message.pointee.event.exec.target.pointee
        let path = Self.string(target.executable.pointee.path)
        let team = Self.string(target.team_id)
        let signing = Self.string(target.signing_id)
        let bundleID = path.flatMap { Self.bundleIdentifier(forExecutablePath: $0) }

        let deny = currentPolicy().shouldDenyLaunch(
            bundleIdentifier: bundleID,
            teamIdentifier: team,
            signingIdentifier: signing,
            executablePath: path
        )

        let authResult: es_auth_result_t = deny ? ES_AUTH_RESULT_DENY : ES_AUTH_RESULT_ALLOW
        // cache == false: re-evaluate every exec so policy changes take effect
        // immediately (and a blocked app can't be cached as "allowed").
        es_respond_auth_result(client, message, authResult, false)

        if deny {
            onDeny?(bundleID, path)
        }
    }

    private static func string(_ token: es_string_token_t) -> String? {
        guard let data = token.data, token.length > 0 else { return nil }
        return data.withMemoryRebound(to: UInt8.self, capacity: token.length) { ptr in
            String(decoding: UnsafeBufferPointer(start: ptr, count: token.length), as: UTF8.self)
        }
    }

    /// Resolves the bundle identifier from an executable path by walking up to
    /// the enclosing `.app` bundle. Daemons / non-bundled binaries return nil
    /// (and are therefore never denied — we only block identifiable apps).
    private static func bundleIdentifier(forExecutablePath path: String) -> String? {
        var url = URL(fileURLWithPath: path)
        while url.pathExtension != "app" && url.path != "/" {
            url.deleteLastPathComponent()
        }
        guard url.pathExtension == "app", let bundle = Bundle(url: url) else {
            return nil
        }
        return bundle.bundleIdentifier
    }
    #endif
}
