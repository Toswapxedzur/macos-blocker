import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import VaultClassifierCore

protocol DictionaryHTTP: Sendable {
    func request(path: String, method: String, body: Data?) async throws -> Data
}

private final class DictionaryRequestCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var cancelled = false
    func start(_ task: URLSessionDataTask) {
        let cancel = lock.withLock { self.task = task; return cancelled }
        if cancel { task.cancel() }
        task.resume()
    }
    func cancel() {
        let task = lock.withLock { cancelled = true; return self.task }
        task?.cancel()
    }
}

final class DictionaryHTTPClient: NSObject, DictionaryHTTP, URLSessionDataDelegate, @unchecked Sendable {
    private let baseURL: URL
    private let lock = NSLock()
    private struct Pending {
        var data = Data()
        var error: Error?
        let continuation: CheckedContinuation<Data, Error>
    }
    private var pending: [Int: Pending] = [:]
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5; config.timeoutIntervalForResource = 60
        config.httpCookieAcceptPolicy = .never; config.httpShouldSetCookies = false
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()
    init(baseURL: URL = URL(string: "https://customblocker.com/api/vault-classifier/")!) { self.baseURL = baseURL }
    private func sameOrigin(_ url: URL?) -> Bool {
        url?.scheme == baseURL.scheme && url?.host == baseURL.host && url?.port == baseURL.port
    }
    func request(path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL, sameOrigin(url) else { throw DictionaryError.unavailable }
        var request = URLRequest(url: url); request.httpMethod = method; request.httpBody = body
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let cancellation = DictionaryRequestCancellation()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                // Plain delegate tasks work on both Foundation and
                // FoundationNetworking, with cancellation and transfer limits.
                let task = lock.withLock { () -> URLSessionDataTask in
                    let task = session.dataTask(with: request)
                    pending[task.taskIdentifier] = Pending(continuation: continuation)
                    return task
                }
                cancellation.start(task)
            }
        }, onCancel: { cancellation.cancel() })
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let error: DictionaryError?
        if let response = response as? HTTPURLResponse, response.statusCode == 200, sameOrigin(response.url) {
            error = response.expectedContentLength > 8*1024*1024 ? .tooLarge : nil
        } else { error = .unavailable }
        if let error { lock.withLock { pending[dataTask.taskIdentifier]?.error = error } }
        completionHandler(error == nil ? .allow : .cancel)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let tooLarge = lock.withLock { () -> Bool in
            guard var entry = pending[dataTask.taskIdentifier], entry.error == nil else { return true }
            guard data.count <= 8*1024*1024-entry.data.count else {
                pending[dataTask.taskIdentifier]?.error = DictionaryError.tooLarge
                return true
            }
            entry.data.append(data); pending[dataTask.taskIdentifier] = entry
            return false
        }
        if tooLarge { dataTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let entry = lock.withLock({ pending.removeValue(forKey: task.taskIdentifier) }) else { return }
        if let error = entry.error ?? error { entry.continuation.resume(throwing: error) }
        else { entry.continuation.resume(returning: entry.data) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(sameOrigin(request.url) ? request : nil)
    }
}

/// Separate public pack/cache service. Neither titles nor personal knowledge enter HTTP requests.
actor OfficialDictionaryService: DictionaryEvidenceProviding {
    nonisolated let disk: DictionaryDiskStore
    private let http: any DictionaryHTTP
    private var available: [KnowledgeEntryKind: DictionaryManifest] = [:]
    private var inFlight: [String: Task<Void, Never>] = [:]
    private var contributionSends: [UUID: Task<Bool, Never>] = [:]
    private struct Contribution {
        var token: UUID
        var count: Int64?
    }
    private var contributions: [String: Contribution] = [:]
    private var pendingCounts: [String: Int64] = [:]
    private var lookupUnavailableUntil = Date.distantPast
    private var failureUntil: [String: Date] = [:]
    private struct SubmissionLedger: Codable {
        var day: String = ""
        var sent: [String] = []
        var counts: [String: Int64]?
        var attempts: Int?
    }
    private var ledgerWritable = true
    private var ledger: SubmissionLedger
    private let ledgerFile: URL
    init(disk: DictionaryDiskStore, http: any DictionaryHTTP = DictionaryHTTPClient()) {
        self.disk = disk; self.http = http
        ledgerFile = disk.root.appendingPathComponent("contribution-ledger.json")
        ledger = .init()
        if FileManager.default.fileExists(atPath: ledgerFile.path) {
            do {
                let payload = try StorageSchemaPolicy(format: "dictionary.contribution-ledger").payload(from: Data(contentsOf: ledgerFile))
                ledger = try JSONDecoder().decode(SubmissionLedger.self, from: payload)
            } catch { ledgerWritable = false }
        }
    }
    nonisolated func localEvidence(title: String, creatorID: String) -> DictionaryEvidence { disk.localEvidence(title: title, creatorID: creatorID) }
    func checkUpdates() async throws -> [String: Any] {
        for kind in KnowledgeEntryKind.allCases {
            let data = try await http.request(path: "dictionaries/\(kind.rawValue)/manifest", method: "GET", body: nil)
            let manifest = try JSONDecoder().decode(DictionaryManifest.self, from: data); try manifest.validate()
            guard manifest.kind == kind else { throw DictionaryError.invalidPack }
            available[kind] = manifest
        }
        return status()
    }
    func status() -> [String: Any] {
        let rows: [[String: Any]] = KnowledgeEntryKind.allCases.map { kind in
            let installed = disk.manifest(kind), latest = available[kind]
            return ["kind": kind.rawValue, "installedVersion": installed?.version ?? "", "availableVersion": latest?.version ?? "",
                    "entryCount": latest?.entryCount ?? installed?.entryCount ?? 0,
                    "byteCount": latest?.totalByteCount ?? installed?.totalByteCount ?? 0,
                    "updateAvailable": latest != nil && latest?.version != installed?.version]
        }
        return ["packs": rows, "cachedCreators": disk.cachedCreatorCount, "fullCreatorReady": disk.creatorFullDownloadReady]
    }
    func update(_ kind: KnowledgeEntryKind) async throws -> [String: Any] {
        if available[kind] == nil { _ = try await checkUpdates() }
        guard let manifest = available[kind] else { throw DictionaryError.unavailable }
        if kind == .creator && disk.settings().creatorMode == .cache {
            try disk.activateCacheManifest(manifest)
        } else {
            let stage = disk.root.appendingPathComponent("staging-" + UUID().uuidString, isDirectory: true)
            try VaultPrivateFile.createDirectory(at: stage)
            defer { try? FileManager.default.removeItem(at: stage) }
            for file in manifest.files {
                let data = try await http.request(path: "dictionaries/\(kind.rawValue)/\(manifest.version)/files/\(file.name)", method: "GET", body: nil)
                guard data.count == file.byteCount, DictionaryKeys.digest(data) == file.sha256 else { throw DictionaryError.invalidPack }
                let url = stage.appendingPathComponent(file.name); try data.write(to: url); try VaultPrivateFile.restrict(url)
            }
            try disk.install(manifest, stagedDirectory: stage)
        }
        return status()
    }
    func evidence(title: String, creatorID: String, subscriberCount: Int64?) async -> DictionaryEvidence {
        guard DictionaryKeys.isPublicCreatorID(creatorID) else { return localEvidence(title: title, creatorID: creatorID) }
        let settings = disk.settings()
        if settings.creatorMode == .cache && !disk.hasCachedCreator(creatorID) {
            if let existing = inFlight[creatorID] { await existing.value }
            else if lookupUnavailableUntil <= Date() && failureUntil[creatorID].map({ $0 > Date() }) != true {
                let task = Task { await self.lookupCreator(creatorID) }
                inFlight[creatorID] = task; await task.value; inFlight[creatorID] = nil
            }
        }
        let result = localEvidence(title: title, creatorID: creatorID)
        if result.creator == nil {
            // Contribution is independent of lookups. Full mode does not perform remote definition lookup.
            contribute(creatorID, subscriberCount: subscriberCount)
        }
        return result
    }
    private func lookupCreator(_ id: String) async {
        do {
            if disk.manifest(.creator) == nil {
                let data = try await http.request(path: "dictionaries/creator/manifest", method: "GET", body: nil)
                let manifest = try JSONDecoder().decode(DictionaryManifest.self, from: data)
                try disk.activateCacheManifest(manifest)
            }
            guard let manifest = disk.manifest(.creator) else { return }
            var components = URLComponents(); components.path = "dictionary-creator"
            components.queryItems = [.init(name: "creator_id", value: id), .init(name: "version", value: manifest.version)]
            guard let path = components.string else { return }
            struct Reply: Decodable { var version: String; var entry: OfficialDictionaryEntry? }
            let data = try await http.request(path: path, method: "GET", body: nil)
            let reply = try JSONDecoder().decode(Reply.self, from: data)
            guard reply.version == manifest.version else { throw DictionaryError.invalidPack }
            guard !Task.isCancelled, disk.settings().creatorMode == .cache else { return }
            try disk.cacheCreator(id, entry: reply.entry, version: reply.version)
        } catch {
            if !Task.isCancelled { lookupUnavailableUntil = Date().addingTimeInterval(60) }
            failureUntil[id] = Date().addingTimeInterval(60)
            if failureUntil.count > 1000 {
                failureUntil = Dictionary(uniqueKeysWithValues: failureUntil.sorted { $0.value > $1.value }.prefix(1000).map { ($0.key, $0.value) })
            }
        }
    }
    func configure(_ settings: DictionarySettings) throws {
        try disk.configure(settings)
        if settings.creatorMode == .full {
            for task in inFlight.values { task.cancel() }
            inFlight.removeAll()
        }
        if !settings.contributionEnabled || !settings.contributionChoiceMade {
            for task in contributionSends.values { task.cancel() }
            pendingCounts.removeAll()
        }
    }
    private func saveLedger() throws {
        let schema = StorageSchemaPolicy(format: "dictionary.contribution-ledger")
        try schema.checkDestination(ledgerFile)
        guard ledgerWritable else { throw StorageSchemaError.unsupported("contribution ledger") }
        try schema.wrap(JSONEncoder().encode(ledger)).write(to: ledgerFile, options: .atomic)
        try VaultPrivateFile.restrict(ledgerFile)
    }
    private func contribute(_ id: String, subscriberCount: Int64?) {
        guard ledgerWritable else { return }
        let settings = disk.settings()
        guard settings.contributionEnabled && settings.contributionChoiceMade else { return }
        if let active = contributions[id] {
            if let subscriberCount {
                pendingCounts[id] = subscriberCount != active.count ? subscriberCount : nil
            }
            return
        }
        let day = String(Int(Date().timeIntervalSince1970) / 86400)
        if ledger.day != day { ledger = .init(day: day, sent: []) }
        guard (ledger.attempts ?? ledger.sent.count) < 50 else { return }
        if ledger.sent.contains(id) {
            // A feed may submit an unknown count; a later watch page can enrich
            // it without repeatedly submitting the same known value.
            guard let subscriberCount, ledger.counts?[id] != subscriberCount else { return }
        }
        // Sample one in four IDs deterministically per day, so repeated sightings do not multiply uploads.
        let sample = DictionaryKeys.digest(Data((day + id).utf8)).prefix(2)
        guard (Int(sample, radix: 16) ?? 0) % 4 == 0 else { return }
        let row: [String: Any] = ["creatorID": id, "subscriberCount": subscriberCount.map { $0 as Any } ?? NSNull()]
        guard let data = try? JSONSerialization.data(withJSONObject: ["creators": [row]]) else { return }
        // Re-read the gate at the send boundary. No stored user/device ID, title or term is sent.
        guard disk.settings().contributionEnabled && disk.settings().contributionChoiceMade else { return }
        ledger.attempts = (ledger.attempts ?? ledger.sent.count) + 1
        do { try saveLedger() } catch { ledgerWritable = false; return }
        let token = UUID()
        contributions[id] = Contribution(token: token, count: subscriberCount)
        let task = Task { [http, disk] in
            guard !Task.isCancelled, disk.settings().contributionEnabled, disk.settings().contributionChoiceMade else { return false }
            do {
                _ = try await http.request(path: "creator-contributions", method: "POST", body: data)
                return !Task.isCancelled
            } catch { return false }
        }
        contributionSends[token] = task
        // Telemetry must not hold up local tagging while the server responds.
        Task {
            let succeeded = await task.value
            self.finishContribution(id, token: token, day: day, subscriberCount: subscriberCount, succeeded: succeeded)
        }
    }
    private func finishContribution(_ id: String, token: UUID, day: String, subscriberCount: Int64?, succeeded: Bool) {
        guard contributions[id]?.token == token else { return }
        contributionSends[token] = nil
        contributions[id] = nil
        if succeeded, ledger.day == day {
            if !ledger.sent.contains(id) { ledger.sent.append(id) }
            if let subscriberCount { var counts = ledger.counts ?? [:]; counts[id] = subscriberCount; ledger.counts = counts }
            try? saveLedger()
        }
        if let count = pendingCounts.removeValue(forKey: id) {
            contribute(id, subscriberCount: count)
        }
    }
}
