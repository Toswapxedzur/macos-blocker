import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import VaultClassifierCore

protocol DictionaryHTTP: Sendable {
    func request(path: String, method: String, body: Data?) async throws -> Data
}

final class DictionaryHTTPClient: NSObject, DictionaryHTTP, URLSessionDownloadDelegate, @unchecked Sendable {
    private let baseURL: URL
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5; config.timeoutIntervalForResource = 60
        config.httpCookieAcceptPolicy = .never; config.httpShouldSetCookies = false
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()
    init(baseURL: URL = URL(string: "https://customblocker.com/api/vault-classifier/")!) { self.baseURL = baseURL }
    func request(path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL,
              url.scheme == baseURL.scheme, url.host == baseURL.host, url.port == baseURL.port else { throw DictionaryError.unavailable }
        var request = URLRequest(url: url); request.httpMethod = method; request.httpBody = body
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (file, response) = try await session.download(for: request)
        defer { try? FileManager.default.removeItem(at: file) }
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 8*1024*1024 else { throw DictionaryError.unavailable }
        return try Data(contentsOf: file)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > 8*1024*1024 || totalBytesExpectedToWrite > 8*1024*1024 { downloadTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let url = request.url
        completionHandler(url?.scheme == baseURL.scheme && url?.host == baseURL.host && url?.port == baseURL.port ? request : nil)
    }
}

/// Separate public pack/cache service. Neither titles nor personal knowledge enter HTTP requests.
actor OfficialDictionaryService: DictionaryEvidenceProviding {
    nonisolated let disk: DictionaryDiskStore
    private let http: any DictionaryHTTP
    private var available: [KnowledgeEntryKind: DictionaryManifest] = [:]
    private var inFlight: [String: Task<Void, Never>] = [:]
    private var contributionSends: [UUID: Task<Void, Never>] = [:]
    private var failureUntil: [String: Date] = [:]
    private struct SubmissionLedger: Codable { var day: String = ""; var sent: [String] = [] }
    private var ledger: SubmissionLedger
    private let ledgerFile: URL
    init(disk: DictionaryDiskStore, http: any DictionaryHTTP = DictionaryHTTPClient()) {
        self.disk = disk; self.http = http
        ledgerFile = disk.root.appendingPathComponent("contribution-ledger.json")
        ledger = (try? JSONDecoder().decode(SubmissionLedger.self, from: Data(contentsOf: ledgerFile))) ?? .init()
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
            else if failureUntil[creatorID].map({ $0 > Date() }) != true {
                let task = Task { await self.lookupCreator(creatorID) }
                inFlight[creatorID] = task; await task.value; inFlight[creatorID] = nil
            }
        }
        let result = localEvidence(title: title, creatorID: creatorID)
        if result.creator == nil {
            // Contribution is independent of lookups. Full mode does not perform remote definition lookup.
            await contribute(creatorID, subscriberCount: subscriberCount)
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
        if !settings.contributionEnabled {
            for task in contributionSends.values { task.cancel() }
            contributionSends.removeAll()
        }
    }
    private func saveLedger() throws {
        try JSONEncoder().encode(ledger).write(to: ledgerFile, options: .atomic)
        try VaultPrivateFile.restrict(ledgerFile)
    }
    private func contribute(_ id: String, subscriberCount: Int64?) async {
        let settings = disk.settings()
        guard settings.contributionEnabled && settings.contributionChoiceMade else { return }
        let day = String(Int(Date().timeIntervalSince1970) / 86400)
        if ledger.day != day { ledger = .init(day: day, sent: []) }
        guard ledger.sent.count < 50, !ledger.sent.contains(id) else { return }
        // Sample one in four IDs deterministically per day, so repeated sightings do not multiply uploads.
        let sample = DictionaryKeys.digest(Data((day + id).utf8)).prefix(2)
        guard (Int(sample, radix: 16) ?? 0) % 4 == 0 else { return }
        ledger.sent.append(id); try? saveLedger()
        let row: [String: Any] = ["creatorID": id, "subscriberCount": subscriberCount.map { $0 as Any } ?? NSNull()]
        guard let data = try? JSONSerialization.data(withJSONObject: ["creators": [row]]) else { return }
        // Re-read the gate at the send boundary. No stored user/device ID, title or term is sent.
        guard disk.settings().contributionEnabled && disk.settings().contributionChoiceMade else { return }
        let token = UUID()
        let task = Task { [http, disk] in
            guard !Task.isCancelled, disk.settings().contributionEnabled, disk.settings().contributionChoiceMade else { return }
            _ = try? await http.request(path: "creator-contributions", method: "POST", body: data)
        }
        contributionSends[token] = task
        await task.value
        contributionSends[token] = nil
    }
}
