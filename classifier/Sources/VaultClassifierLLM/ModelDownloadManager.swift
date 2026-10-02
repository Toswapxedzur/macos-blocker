import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import VaultClassifierCore

public struct ModelDownloadProgress: Equatable, Sendable {
    public let bytesReceived: Int64
    public let totalBytes: Int64

    public init(bytesReceived: Int64, totalBytes: Int64) {
        self.bytesReceived = max(0, bytesReceived)
        self.totalBytes = max(0, totalBytes)
    }

    public var fraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(bytesReceived) / Double(totalBytes)))
    }
}

/// Injectable transport boundary. Production uses a URLSession download task;
/// tests return local temporary files and never touch the network.
public protocol ModelDownloadTransport: Sendable {
    func download(
        from url: URL,
        progress: @escaping @Sendable (ModelDownloadProgress) -> Void
    ) async throws -> URL
}

public enum ModelDownloadManagerError: Error, Equatable, LocalizedError {
    case alreadyDownloading
    case invalidHTTPStatus(Int)
    case modelsDirectoryUnavailable
    case invalidTemporaryFile

    public var errorDescription: String? {
        switch self {
        case .alreadyDownloading:
            return "That model is already downloading."
        case .invalidHTTPStatus(let status):
            return "The model server returned HTTP \(status)."
        case .modelsDirectoryUnavailable:
            return "The local model folder is unavailable."
        case .invalidTemporaryFile:
            return "The downloaded model file is unavailable."
        }
    }
}

/// Downloads with a plain download task on its own session, whose delegate gets
/// the progress and the finished file. (The async `download(for:delegate:)`
/// convenience never called the task delegate: no progress, and the finished
/// file was never picked up — every in-app model download failed at the end.)
public struct URLSessionModelDownloadTransport: ModelDownloadTransport, @unchecked Sendable {
    private let configuration: URLSessionConfiguration

    public init(configuration: URLSessionConfiguration = .default) {
        self.configuration = configuration
    }

    public func download(
        from url: URL,
        progress: @escaping @Sendable (ModelDownloadProgress) -> Void
    ) async throws -> URL {
        let delegate = DownloadDelegate(progress: progress)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.start(continuation)
                session.downloadTask(with: request).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
    }
}

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: @Sendable (ModelDownloadProgress) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var result: Result<URL, Error>?

    init(progress: @escaping @Sendable (ModelDownloadProgress) -> Void) {
        self.progress = progress
    }

    func start(_ continuation: CheckedContinuation<URL, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        progress(ModelDownloadProgress(bytesReceived: totalBytesWritten, totalBytes: totalBytesExpectedToWrite))
    }

    // The file is only valid inside this callback: keep it (or the HTTP error).
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            record(.failure(ModelDownloadManagerError.invalidHTTPStatus(http.statusCode)))
            return
        }
        let kept = FileManager.default.temporaryDirectory
            .appendingPathComponent("vault-model-\(UUID().uuidString).download")
        do {
            try FileManager.default.moveItem(at: location, to: kept)
            record(.success(kept))
        } catch {
            record(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            // A cancelled download is a cancellation, not an error to show.
            record(.failure((error as? URLError)?.code == .cancelled ? CancellationError() : error))
        }
        lock.lock()
        let outcome = result ?? .failure(ModelDownloadManagerError.invalidTemporaryFile)
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(with: outcome)
    }

    // The first outcome counts; a later failure replaces a kept file (and
    // deletes it).
    private func record(_ outcome: Result<URL, Error>) {
        lock.lock()
        defer { lock.unlock() }
        switch (result, outcome) {
        case (nil, _):
            result = outcome
        case (.success(let kept)?, .failure):
            try? FileManager.default.removeItem(at: kept)
            result = outcome
        default:
            break
        }
    }
}

public actor ModelDownloadManager {
    public typealias ModelsDirectoryProvider = @Sendable () -> URL?
    public typealias ProgressHandler = @Sendable (ModelDownloadProgress) -> Void

    private struct ActiveDownload {
        let token: UUID
        let fileName: String
        let task: Task<URL, Error>
    }

    private let transport: any ModelDownloadTransport
    private let modelsDirectoryProvider: ModelsDirectoryProvider
    private var activeDownloads: [String: ActiveDownload] = [:]
    private var cancelledTokens: Set<UUID> = []
    private var progressByID: [String: ModelDownloadProgress] = [:]
    private var stagingFiles: [UUID: URL] = [:]

    public init(
        transport: any ModelDownloadTransport = URLSessionModelDownloadTransport(),
        modelsDirectoryProvider: @escaping ModelsDirectoryProvider = {
            VaultLocalLLMEngine.modelsDirectory()
        }
    ) {
        self.transport = transport
        self.modelsDirectoryProvider = modelsDirectoryProvider
    }

    public func inProgressDownloads() -> [String: Double] {
        progressByID.mapValues(\.fraction)
    }

    @discardableResult
    public func download(
        _ entry: LocalModelCatalogEntry,
        progress progressHandler: @escaping ProgressHandler = { _ in }
    ) async throws -> URL {
        let remoteURL = try entry.downloadURL
        guard LocalModelCatalog.isSafeGGUFFileName(entry.ggufFileName) else {
            throw LocalModelCatalogValidationError.invalidGGUFFileName
        }
        guard let modelsDirectory = modelsDirectoryProvider(), modelsDirectory.isFileURL else {
            throw ModelDownloadManagerError.modelsDirectoryUnavailable
        }
        try FileManager.default.createDirectory(
            at: modelsDirectory,
            withIntermediateDirectories: true
        )
        let destination = modelsDirectory.appendingPathComponent(entry.ggufFileName, isDirectory: false)
        if FileManager.default.fileExists(atPath: destination.path) {
            return destination
        }
        guard activeDownloads[entry.id] == nil,
              !activeDownloads.values.contains(where: { $0.fileName == entry.ggufFileName }) else {
            throw ModelDownloadManagerError.alreadyDownloading
        }

        let token = UUID()
        let initialProgress = ModelDownloadProgress(
            bytesReceived: 0,
            totalBytes: entry.downloadSizeBytes
        )
        progressByID[entry.id] = initialProgress
        progressHandler(initialProgress)

        let transport = self.transport
        let transportTask = Task<URL, Error> {
            try await transport.download(from: remoteURL) { update in
                Task {
                    await self.recordProgress(
                        update,
                        fallbackTotalBytes: entry.downloadSizeBytes,
                        id: entry.id,
                        token: token,
                        handler: progressHandler
                    )
                }
            }
        }
        activeDownloads[entry.id] = ActiveDownload(
            token: token,
            fileName: entry.ggufFileName,
            task: transportTask
        )

        var temporaryURL: URL?
        do {
            let downloadedURL = try await withTaskCancellationHandler {
                try await transportTask.value
            } onCancel: {
                transportTask.cancel()
            }
            temporaryURL = downloadedURL
            try ensureActive(id: entry.id, token: token)
            let publishedURL = try publish(
                temporaryURL: downloadedURL,
                destination: destination,
                modelsDirectory: modelsDirectory,
                id: entry.id,
                token: token
            )
            finish(id: entry.id, token: token)
            return publishedURL
        } catch {
            transportTask.cancel()
            removeIfPresent(temporaryURL)
            cleanupStagingFile(token: token)
            finish(id: entry.id, token: token)
            throw error
        }
    }

    public func cancel(id: String) {
        guard let active = activeDownloads[id] else { return }
        cancelledTokens.insert(active.token)
        progressByID.removeValue(forKey: id)
        active.task.cancel()
    }

    public func deleteModelFile(fileName: String) throws {
        guard LocalModelCatalog.isSafeGGUFFileName(fileName) else {
            throw LocalModelCatalogValidationError.invalidGGUFFileName
        }
        for (id, active) in activeDownloads where active.fileName == fileName {
            cancelledTokens.insert(active.token)
            progressByID.removeValue(forKey: id)
            active.task.cancel()
        }
        guard let modelsDirectory = modelsDirectoryProvider(), modelsDirectory.isFileURL else {
            throw ModelDownloadManagerError.modelsDirectoryUnavailable
        }
        let destination = modelsDirectory.appendingPathComponent(fileName, isDirectory: false)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
    }

    private func recordProgress(
        _ progress: ModelDownloadProgress,
        fallbackTotalBytes: Int64,
        id: String,
        token: UUID,
        handler: ProgressHandler
    ) {
        guard activeDownloads[id]?.token == token,
              !cancelledTokens.contains(token) else { return }
        let totalBytes = progress.totalBytes > 0 ? progress.totalBytes : fallbackTotalBytes
        let normalized = ModelDownloadProgress(
            bytesReceived: progress.bytesReceived,
            totalBytes: totalBytes
        )
        if let current = progressByID[id], normalized.bytesReceived < current.bytesReceived {
            return
        }
        progressByID[id] = normalized
        handler(normalized)
    }

    private func publish(
        temporaryURL: URL,
        destination: URL,
        modelsDirectory: URL,
        id: String,
        token: UUID
    ) throws -> URL {
        guard temporaryURL.isFileURL,
              FileManager.default.fileExists(atPath: temporaryURL.path) else {
            throw ModelDownloadManagerError.invalidTemporaryFile
        }
        try ensureActive(id: id, token: token)
        let stagingURL = modelsDirectory.appendingPathComponent(
            ".\(destination.lastPathComponent).\(token.uuidString).download",
            isDirectory: false
        )
        stagingFiles[token] = stagingURL
        do {
            try FileManager.default.moveItem(at: temporaryURL, to: stagingURL)
            try ensureActive(id: id, token: token)
            if FileManager.default.fileExists(atPath: destination.path) {
                removeIfPresent(stagingURL)
            } else {
                // The staging file already lives beside the destination, so
                // this final rename is the only operation that publishes a
                // picker-visible *.gguf file.
                try FileManager.default.moveItem(at: stagingURL, to: destination)
            }
            stagingFiles.removeValue(forKey: token)
            return destination
        } catch {
            cleanupStagingFile(token: token)
            throw error
        }
    }

    private func ensureActive(id: String, token: UUID) throws {
        guard activeDownloads[id]?.token == token,
              !cancelledTokens.contains(token),
              !Task.isCancelled else {
            throw CancellationError()
        }
    }

    private func finish(id: String, token: UUID) {
        if activeDownloads[id]?.token == token {
            activeDownloads.removeValue(forKey: id)
            progressByID.removeValue(forKey: id)
        }
        cancelledTokens.remove(token)
        stagingFiles.removeValue(forKey: token)
    }

    private func cleanupStagingFile(token: UUID) {
        guard let stagingURL = stagingFiles.removeValue(forKey: token) else { return }
        removeIfPresent(stagingURL)
    }

    private func removeIfPresent(_ url: URL?) {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
