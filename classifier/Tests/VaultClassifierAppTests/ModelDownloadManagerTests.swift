import XCTest
import VaultClassifierCore
@testable import VaultClassifierLLM

private actor ControlledModelDownloadTransport: ModelDownloadTransport {
    private let temporaryURL: URL
    private var released = false
    private(set) var started = false

    init(temporaryURL: URL) {
        self.temporaryURL = temporaryURL
    }

    func download(
        from url: URL,
        progress: @escaping @Sendable (ModelDownloadProgress) -> Void
    ) async throws -> URL {
        started = true
        progress(ModelDownloadProgress(bytesReceived: 25, totalBytes: 100))
        do {
            while !released {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            progress(ModelDownloadProgress(bytesReceived: 100, totalBytes: 100))
            return temporaryURL
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    func release() {
        released = true
    }
}

private actor DownloadProgressRecorder {
    private(set) var values: [ModelDownloadProgress] = []

    func append(_ value: ModelDownloadProgress) {
        values.append(value)
    }
}

final class ModelDownloadManagerTests: XCTestCase {
    func testInjectedTransportReportsProgressAndAtomicallyPublishesGGUF() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let modelsDirectory = root.appendingPathComponent("models", isDirectory: true)
        let temporaryURL = root.appendingPathComponent("transport.partial")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("complete-gguf".utf8).write(to: temporaryURL)
        defer { try? FileManager.default.removeItem(at: root) }

        let entry = try XCTUnwrap(LocalModelCatalog.curated.first)
        let transport = ControlledModelDownloadTransport(temporaryURL: temporaryURL)
        let recorder = DownloadProgressRecorder()
        let manager = ModelDownloadManager(
            transport: transport,
            modelsDirectoryProvider: { modelsDirectory }
        )
        let download = Task {
            try await manager.download(entry) { progress in
                Task { await recorder.append(progress) }
            }
        }

        var observedFraction: Double?
        for _ in 0..<1_000 {
            observedFraction = await manager.inProgressDownloads()[entry.id]
            if observedFraction == 0.25 { break }
            await Task.yield()
        }
        XCTAssertEqual(observedFraction, 0.25)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: modelsDirectory.appendingPathComponent(entry.ggufFileName).path
        ))

        await transport.release()
        let destination = try await download.value
        XCTAssertEqual(destination.lastPathComponent, entry.ggufFileName)
        XCTAssertEqual(try Data(contentsOf: destination), Data("complete-gguf".utf8))
        let finishedProgress = await manager.inProgressDownloads()
        XCTAssertTrue(finishedProgress.isEmpty)
        let publishedNames = try FileManager.default.contentsOfDirectory(atPath: modelsDirectory.path)
        XCTAssertEqual(publishedNames, [entry.ggufFileName])

        for _ in 0..<1_000 where await recorder.values.count < 2 {
            await Task.yield()
        }
        let values = await recorder.values
        XCTAssertEqual(values.first?.bytesReceived, 0)
        XCTAssertTrue(values.contains { $0.bytesReceived == 25 && $0.totalBytes == 100 })
    }

    func testCancelRemovesProgressAndNeverPublishesPartialFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let modelsDirectory = root.appendingPathComponent("models", isDirectory: true)
        let temporaryURL = root.appendingPathComponent("transport.partial")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: temporaryURL)
        defer { try? FileManager.default.removeItem(at: root) }

        let entry = try XCTUnwrap(LocalModelCatalog.curated.first)
        let transport = ControlledModelDownloadTransport(temporaryURL: temporaryURL)
        let manager = ModelDownloadManager(
            transport: transport,
            modelsDirectoryProvider: { modelsDirectory }
        )
        let download = Task { try await manager.download(entry) }

        for _ in 0..<1_000 {
            if await transport.started { break }
            await Task.yield()
        }
        await manager.cancel(id: entry.id)
        do {
            _ = try await download.value
            XCTFail("A cancelled download must not complete")
        } catch is CancellationError {
            // Expected.
        }

        let cancelledProgress = await manager.inProgressDownloads()
        XCTAssertTrue(cancelledProgress.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: modelsDirectory.appendingPathComponent(entry.ggufFileName).path
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryURL.path))
    }

    func testDeleteRemovesOnlyValidatedGGUFInsideModelsDirectory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let modelsDirectory = root.appendingPathComponent("models", isDirectory: true)
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let modelURL = modelsDirectory.appendingPathComponent("local.gguf")
        let siblingURL = root.appendingPathComponent("outside.gguf")
        try Data("model".utf8).write(to: modelURL)
        try Data("outside".utf8).write(to: siblingURL)
        let manager = ModelDownloadManager(
            transport: ControlledModelDownloadTransport(temporaryURL: root.appendingPathComponent("unused")),
            modelsDirectoryProvider: { modelsDirectory }
        )

        try await manager.deleteModelFile(fileName: "local.gguf")
        XCTAssertFalse(FileManager.default.fileExists(atPath: modelURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: siblingURL.path))
        do {
            try await manager.deleteModelFile(fileName: "../outside.gguf")
            XCTFail("Traversal must be rejected")
        } catch let error as LocalModelCatalogValidationError {
            XCTAssertEqual(error, .invalidGGUFFileName)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: siblingURL.path))
    }
}
