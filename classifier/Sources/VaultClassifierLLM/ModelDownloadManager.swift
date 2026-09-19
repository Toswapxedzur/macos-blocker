import Foundation
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

public struct URLSessionModelDownloadTransport: ModelDownloadTransport, @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func download(
        from url: URL,
        progress: @escaping @Sendable (ModelDownloadProgress) -> Void
    ) async throws -> URL {
        let delegate = DownloadProgressDelegate(progress: progress)
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        do {
            let (_, response) = try await session.download(for: request, delegate: delegate)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                throw ModelDownloadManagerError.invalidHTTPStatus(
                    (response as? HTTPURLResponse)?.statusCode ?? 0
                )
            }
            return try delegate.takeDownloadedFileURL()
        } catch {
            delegate.discardDownloadedFile()
            throw error
        }
    }
}

private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: @Sendable (ModelDownloadProgress) -> Void
    private let resultLock = NSLock()
    private var downloadedFileURL: URL?
    private var downloadedFileError: Error?

    init(progress: @escaping @Sendable (ModelDownloadProgress) -> Void) {
        self.progress = progress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        progress(ModelDownloadProgress(
            bytesReceived: totalBytesWritten,
            totalBytes: totalBytesExpectedToWrite
        ))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let persistentURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vault-model-\(UUID().uuidString).download")
        do {
            try FileManager.default.moveItem(at: location, to: persistentURL)
            resultLock.lock()
            downloadedFileURL = persistentURL
            resultLock.unlock()
        } catch {
            resultLock.lock()
            downloadedFileError = error
            resultLock.unlock()
        }
    }

    func takeDownloadedFileURL() throws -> URL {
        resultLock.lock()
        defer { resultLock.unlock() }
        if let downloadedFileError { throw downloadedFileError }
        guard let downloadedFileURL else {
            throw ModelDownloadManagerError.invalidTemporaryFile
        }
        self.downloadedFileURL = nil
        return downloadedFileURL
    }

    func discardDownloadedFile() {
        resultLock.lock()
        let fileURL = downloadedFileURL
        downloadedFileURL = nil
        resultLock.unlock()
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }
}

/// Owns user-initiated catalog downloads and publishes only complete GGUF
/// files. The actor never starts work on its own and performs no network access
/// until `download` is called explicitly.
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
