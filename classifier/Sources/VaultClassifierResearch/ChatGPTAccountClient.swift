import Foundation
import VaultClassifierCore
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public struct ChatGPTAccountStatus: Sendable {
    public init() {}
    public var accountID: String = ""
    public var email: String = ""
    public var connected = false
    public var planUsageEnabled = false
    public var signingIn = false
    public var models: [ChatGPTPlanProtocol.Model] = []
    public var requestsToday = 0
    public var needsRetry = false
    public var needsWelcome = false
    public var issue: String?
}

private struct ChatGPTCredential: Codable, CustomStringConvertible {
    var schemaVersion: Int
    var clientID: String; var subject: String; var email: String?
    var accessToken: String; var refreshToken: String; var idToken: String
    var scopes: [String]; var expiresAt: Date; var earliestRefreshAt: Date?
    var accountID: String {
        ChatGPTOAuth.base64URL(Data(SHA256.hash(data: Data((clientID + "\n" + subject).utf8))))
    }
    var description: String { "ChatGPT credentials (redacted)" }
}

/// A separate private store; no credential is part of LocalClassifierState.
/// macOS uses 0700/0600, Windows additionally encrypts with current-user DPAPI.
private struct ChatGPTAccountStore: Sendable {
    let directory: URL
    func read(_ name: String) throws -> Data? {
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw ChatGPTPlanError.invalidAuthorization }
        let data = try Data(contentsOf: url)
        guard data.count <= 262144 else { throw ChatGPTPlanError.invalidAuthorization }
        #if os(Windows)
        return try VaultPrivateFile.protectedData(data, decrypt: true)
        #else
        return data
        #endif
    }
    func write(_ data: Data, name: String) throws {
        try VaultPrivateFile.createDirectory(at: directory)
        guard try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw ChatGPTPlanError.invalidAuthorization }
        try VaultPrivateFile.restrict(directory, directory: true)
        let target = directory.appendingPathComponent(name)
        #if os(Windows)
        try VaultPrivateFile.protectedData(data).write(to: target, options: .atomic)
        #else
        try data.write(to: target, options: .atomic)
        #endif
        try VaultPrivateFile.restrict(target)
    }
    func delete(_ name: String) throws {
        let target = directory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
    }
}

public actor ChatGPTAccountClient: CloudClassificationEngineResolving {
    private let store: ChatGPTAccountStore
    private let http: ChatGPTHTTPClient
    private let onChange: @Sendable () -> Void
    private var credential: ChatGPTCredential?
    private var registration: String?
    private let hostID: String
    private var models: [ChatGPTPlanProtocol.Model] = []
    private var issue: String?
    private var signInTask: Task<Void, Never>?
    private var generation = UUID()
    private var credentialRevision = UUID()
    private var signInGeneration = UUID()
    private var dataRequests: [UUID: Task<Data, Error>] = [:]
    private var isShuttingDown = false
    private var requestBusy = false
    private var dailyRequestLimit: Int?
    private var failureHold = false
    private var activeRequests: [UUID: Task<(String, Int?), Error>] = [:]
    private struct Usage: Codable { var schemaVersion: Int; var day: String; var requests: Int }
    private var usage: Usage
    private var welcomeAccounts: Set<String>
    private struct Welcome: Codable { let schemaVersion: Int; let accounts: Set<String> }

    public init(directory: URL, dailyRequestLimit: Int? = nil, http: ChatGPTHTTPClient = .init(), onChange: @escaping @Sendable () -> Void = {}) throws {
        let store = ChatGPTAccountStore(directory: directory)
        self.store = store; self.http = http; self.onChange = onChange
        self.dailyRequestLimit = dailyRequestLimit
        if let data = try store.read("host.json") {
            let id = try JSONDecoder().decode(String.self, from: data)
            guard id.hasPrefix("urn:uuid:"), UUID(uuidString: String(id.dropFirst(9))) != nil else { throw ChatGPTPlanError.invalidAuthorization }
            self.hostID = id
        } else {
            let id = "urn:uuid:" + UUID().uuidString.lowercased()
            try store.write(JSONEncoder().encode(id), name: "host.json"); self.hostID = id
        }
        credential = try store.read("account.json").map { try JSONDecoder().decode(ChatGPTCredential.self, from: $0) }
        registration = try store.read("registration.json").map { try JSONDecoder().decode(String.self, from: $0) }
        usage = try store.read("usage.json").map { try JSONDecoder().decode(Usage.self, from: $0) } ?? Usage(schemaVersion: 1, day: Self.day(), requests: 0)
        let welcome = try store.read("welcome.json").map { try JSONDecoder().decode(Welcome.self, from: $0) } ?? Welcome(schemaVersion: 1, accounts: [])
        welcomeAccounts = welcome.accounts
        guard credential == nil || credential?.schemaVersion == 1,
              usage.schemaVersion == 1, welcome.schemaVersion == 1, welcomeAccounts.count <= 1024,
              (0...1_000_000).contains(usage.requests) else { throw ChatGPTPlanError.invalidResponse }
    }

    private static func day() -> String {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withFullDate]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: Date())
    }

    public func status() -> ChatGPTAccountStatus {
        var status = ChatGPTAccountStatus()
        status.accountID = credential?.accountID ?? ""; status.email = credential?.email ?? ""
        status.connected = credential != nil
        status.planUsageEnabled = credential?.scopes.contains(ChatGPTPlanProtocol.requiredPlanScope) == true
        status.signingIn = signInTask != nil; status.models = models; status.issue = issue
        status.requestsToday = usage.day == Self.day() ? usage.requests : 0
        status.needsRetry = failureHold
        status.needsWelcome = status.planUsageEnabled && !welcomeAccounts.contains(status.accountID)
        return status
    }

    public func beginSignIn() throws -> URL {
        guard !isShuttingDown else { throw CancellationError() }
        signInTask?.cancel()
        signInGeneration = UUID(); let currentGeneration = signInGeneration
        let listener = try ChatGPTLoopback()
        let verifier = try ChatGPTOAuth.random()
        let attempt = try ChatGPTPlanProtocol.AuthorizationAttempt(
            callbackURL: URL(string: "http://127.0.0.1:\(listener.port)/auth/callback")!, hostID: hostID,
            state: ChatGPTOAuth.random(), nonce: ChatGPTOAuth.random(), verifier: verifier,
            s256Challenge: ChatGPTOAuth.base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))), issuedClientID: registration)
        issue = nil
        signInTask = Task { [weak self] in
            do {
                let callback = try await listener.receive(attempt: attempt)
                try Task.checkCancellation()
                try await self?.completeSignIn(callback, attempt: attempt, generation: currentGeneration)
            } catch {
                await self?.signInFailed(error, generation: currentGeneration)
            }
        }
        onChange()
        return attempt.authorizationURL
    }

    private struct TokenReply: Decodable {
        let access_token: String; let refresh_token: String; let id_token: String?
        let token_type: String; let expires_in: Double; let scope: String?
        let earliest_refresh_at: Double?
    }

    private func fetch(_ request: ChatGPTPlanProtocol.Request, token: String? = nil, limit: Int = 262144) async throws -> Data {
        guard !isShuttingDown else { throw CancellationError() }
        let id = UUID()
        let work = Task { try await http.data(request, token: token, limit: limit) }
        dataRequests[id] = work
        defer { dataRequests[id] = nil }
        return try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
    }

    private func tokenReply(_ request: ChatGPTPlanProtocol.Request) async throws -> TokenReply {
        let data = try await fetch(request)
        guard let reply = try? JSONDecoder().decode(TokenReply.self, from: data),
              reply.token_type.lowercased() == "bearer", !reply.access_token.isEmpty,
              !reply.refresh_token.isEmpty, reply.expires_in > 0, reply.expires_in <= 86400 else {
            throw ChatGPTPlanError.invalidAuthorization
        }
        return reply
    }

    private func identity(_ token: String, clientID: String, nonce: String?, subject: String?) async throws -> ChatGPTOAuth.Identity {
        let request = ChatGPTPlanProtocol.Request(url: URL(string: "https://auth.openai.com/.well-known/jwks.json")!, method: "GET", contentType: nil, body: nil)
        let jwks = try await fetch(request)
        return try ChatGPTOAuth.verifyIdentity(token, jwks: jwks, clientID: clientID, nonce: nonce, expectedSubject: subject)
    }

    private func completeSignIn(_ callback: (clientID: String, request: ChatGPTPlanProtocol.Request), attempt: ChatGPTPlanProtocol.AuthorizationAttempt, generation pending: UUID) async throws {
        guard pending == signInGeneration, !isShuttingDown else { throw CancellationError() }
        // Retain dynamic registration even when code exchange expires. The
        // active identity/credentials remain untouched until validation passes.
        try store.write(JSONEncoder().encode(callback.clientID), name: "registration.json")
        registration = callback.clientID
        let reply = try await tokenReply(callback.request)
        guard let token = reply.id_token else { throw ChatGPTPlanError.invalidAuthorization }
        let identity = try await identity(token, clientID: callback.clientID, nonce: attempt.nonce, subject: credential?.subject)
        guard pending == signInGeneration, !isShuttingDown else { throw CancellationError() }
        let connected = ChatGPTCredential(schemaVersion: 1, clientID: callback.clientID, subject: identity.subject, email: identity.email,
            accessToken: reply.access_token, refreshToken: reply.refresh_token, idToken: token,
            scopes: reply.scope?.split(separator: " ").map(String.init) ?? [],
            expiresAt: Date().addingTimeInterval(reply.expires_in), earliestRefreshAt: reply.earliest_refresh_at.map(Date.init(timeIntervalSince1970:)))
        try store.write(JSONEncoder().encode(connected), name: "account.json")
        credentialRevision = UUID()
        credential = connected; models = []; signInTask = nil; issue = nil; failureHold = false; onChange()
        try await refreshModels()
    }

    private func signInFailed(_ error: Error, generation pending: UUID) {
        guard pending == signInGeneration else { return }
        signInTask = nil
        issue = error is CancellationError ? nil : error.localizedDescription
        onChange()
    }

    public func disconnect() throws {
        generation = UUID(); credentialRevision = UUID(); signInGeneration = UUID(); signInTask?.cancel(); signInTask = nil
        activeRequests.values.forEach { $0.cancel() }
        try store.delete("account.json"); try store.delete("registration.json")
        credential = nil; registration = nil; models = []; issue = nil; failureHold = false; onChange()
    }

    public func cancelSignIn() {
        signInGeneration = UUID(); signInTask?.cancel(); signInTask = nil; issue = nil; onChange()
    }

    public func retryFailedRequests() { failureHold = false; issue = nil; onChange() }
    public func acknowledgePlanUsage() throws {
        guard let credential, credential.scopes.contains(ChatGPTPlanProtocol.requiredPlanScope) else { return }
        var next = welcomeAccounts; next.insert(credential.accountID)
        guard next.count <= 1024 else { throw ChatGPTPlanError.invalidResponse }
        try store.write(JSONEncoder().encode(Welcome(schemaVersion: 1, accounts: next)), name: "welcome.json")
        welcomeAccounts = next; onChange()
    }
    func recordClassificationFailure(_ error: Error) { failureHold = true; issue = error.localizedDescription; onChange() }
    public func setDailyRequestLimit(_ value: Int?) { dailyRequestLimit = value }

    private func accessToken() async throws -> String {
        guard var current = credential, current.scopes.contains(ChatGPTPlanProtocol.requiredPlanScope), !isShuttingDown else {
            throw CloudClassificationError.signInRequired
        }
        if current.expiresAt.timeIntervalSinceNow > 60 { return current.accessToken }
        if let earliest = current.earliestRefreshAt, earliest > Date() {
            guard current.expiresAt > Date() else { throw CloudClassificationError.signInRequired }
            return current.accessToken
        }
        let pending = generation
        let revision = credentialRevision
        let reply = try await tokenReply(ChatGPTPlanProtocol.refreshRequest(clientID: current.clientID, refreshToken: current.refreshToken))
        if let token = reply.id_token {
            _ = try await identity(token, clientID: current.clientID, nonce: nil, subject: current.subject)
            current.idToken = token
        }
        guard pending == generation, !isShuttingDown else { throw CancellationError() }
        if revision != credentialRevision { return try await accessToken() }
        current.accessToken = reply.access_token; current.refreshToken = reply.refresh_token
        current.expiresAt = Date().addingTimeInterval(reply.expires_in)
        current.earliestRefreshAt = reply.earliest_refresh_at.map(Date.init(timeIntervalSince1970:))
        if let scope = reply.scope { current.scopes = scope.split(separator: " ").map(String.init) }
        try store.write(JSONEncoder().encode(current), name: "account.json"); credential = current; credentialRevision = UUID()
        guard current.scopes.contains(ChatGPTPlanProtocol.requiredPlanScope) else { throw CloudClassificationError.signInRequired }
        return current.accessToken
    }

    private func acquire() async throws {
        while requestBusy { try await Task.sleep(nanoseconds: 25_000_000) }
        try Task.checkCancellation()
        guard !isShuttingDown else { throw CancellationError() }
        requestBusy = true
    }

    public func refreshModels() async throws {
        try await acquire(); defer { requestBusy = false }
        do {
            let pending = generation
            let token = try await accessToken()
            let data = try await fetch(ChatGPTPlanProtocol.modelRequest(), token: token, limit: 2_097_152)
            guard pending == generation else { throw CancellationError() }
            models = try ChatGPTPlanProtocol.parseModels(data); issue = nil; onChange()
        } catch { issue = error.localizedDescription; onChange(); throw error }
    }

    public func resolveCloudEngine(for type: ClassifierTypeAsset) async throws -> any OnDeviceLLM {
        try type.chatGPT.validate()
        guard credential?.accountID == type.chatGPT.accountID else { throw CloudClassificationError.signInRequired }
        return ChatGPTClassificationEngine(client: self, configuration: type.chatGPT, modelVersion: type.cloudModelVersion)
    }

    func classify(configuration: ChatGPTClassificationSettings, request: ChatGPTPlanProtocol.Request) async throws -> String {
        try await acquire(); defer { requestBusy = false; onChange() }
        guard credential?.accountID == configuration.accountID else { throw CloudClassificationError.signInRequired }
        guard !failureHold else { throw ChatGPTPlanError.failedResponse }
        let pending = generation
        if usage.day != Self.day() { usage = Usage(schemaVersion: 1, day: Self.day(), requests: 0) }
        if let limit = dailyRequestLimit, usage.requests >= limit { throw CloudClassificationError.usageLimit }
        let token: String
        do { token = try await accessToken() }
        catch { issue = error.localizedDescription; failureHold = !(error is CancellationError); throw error }
        guard pending == generation, credential?.accountID == configuration.accountID else { throw CancellationError() }
        usage.requests += 1
        try store.write(JSONEncoder().encode(usage), name: "usage.json") // Reserve before dispatch; failures count too.
        let id = UUID()
        let work = Task { try await http.inference(request, token: token) }
        activeRequests[id] = work
        defer { activeRequests[id] = nil }
        do {
            let output = try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
            guard pending == generation, !isShuttingDown else { throw CancellationError() }
            issue = nil
            return output.0
        } catch {
            if pending != generation, !isShuttingDown { throw CloudClassificationError.signInRequired }
            issue = error is CancellationError ? nil : error.localizedDescription
            failureHold = !(error is CancellationError); throw error
        }
    }

    public func shutdown() async {
        isShuttingDown = true; generation = UUID(); credentialRevision = UUID(); signInGeneration = UUID()
        let signIn = signInTask; signIn?.cancel(); signInTask = nil
        let data = Array(dataRequests.values); data.forEach { $0.cancel() }
        let requests = Array(activeRequests.values); requests.forEach { $0.cancel() }
        await signIn?.value
        for request in requests { _ = try? await request.value }
        for request in data { _ = try? await request.value }
    }
}
