import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
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

private final class DownloadProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [ModelDownloadProgress] = []

    var values: [ModelDownloadProgress] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func append(_ value: ModelDownloadProgress) {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(value)
    }
}

/// A real loopback HTTP response exercises FoundationNetworking's download
/// delegate on Windows, where URLSession deliberately does not accept file URLs.
private final class ModelDownloadHTTPFixture {
    let process = Process()
    let url: URL

    init(directory: URL, fileName: String) throws {
        let environment = ProcessInfo.processInfo.environment
        let interpreter: URL
        if let explicit = environment["VAULT_TEST_PYTHON"], !explicit.isEmpty {
            interpreter = URL(fileURLWithPath: explicit)
        } else {
            #if os(Windows)
            let programs = URL(fileURLWithPath: environment["LOCALAPPDATA"] ?? "")
                .appendingPathComponent("Programs/Python", isDirectory: true)
            let installs = try FileManager.default.contentsOfDirectory(at: programs, includingPropertiesForKeys: nil)
            interpreter = try XCTUnwrap(installs.sorted { $0.path < $1.path }
                .map { $0.appendingPathComponent("python.exe") }
                .first { FileManager.default.fileExists(atPath: $0.path) }, "Python is required for the loopback download fixture")
            #else
            interpreter = URL(fileURLWithPath: "/usr/bin/python3")
            #endif
        }
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Worker/download_fixture.py")
        let output = Pipe()
        process.executableURL = interpreter
        process.arguments = [script.path, directory.path]
        process.standardOutput = output
        try process.run()
        let port = try XCTUnwrap(String(data: output.fileHandleForReading.availableData, encoding: .utf8)
            .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) })
        url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/\(fileName)"))
    }

    deinit {
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
    }
}

final class ModelDownloadManagerTests: XCTestCase {
    /// The real transport hands back the finished file (a regression: the async
    /// URLSession convenience never called its delegate, so every in-app model
    /// download failed at the end with "the downloaded model file is unavailable").
    func testTheURLSessionTransportReturnsTheFinishedFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("model.gguf")
        let bytes = Data((0..<3_000_000).map { UInt8($0 % 251) })
        try bytes.write(to: source)
        let fixture = try ModelDownloadHTTPFixture(directory: root, fileName: "model.gguf")
        defer { withExtendedLifetime(fixture) {} }

        let recorder = DownloadProgressRecorder()
        let downloaded = try await URLSessionModelDownloadTransport().download(from: fixture.url) { update in
            recorder.append(update)
        }
        defer { try? FileManager.default.removeItem(at: downloaded) }
        XCTAssertEqual(try Data(contentsOf: downloaded), bytes, "the whole file, kept past the callback")
        XCTAssertNotEqual(downloaded, source)
    }

    func testTheURLSessionTransportFailsForAMissingFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try ModelDownloadHTTPFixture(directory: root, fileName: "missing.gguf")
        defer { withExtendedLifetime(fixture) {} }
        do {
            _ = try await URLSessionModelDownloadTransport().download(from: fixture.url) { _ in }
            XCTFail("a missing source can't download")
        } catch let error as ModelDownloadManagerError {
            XCTAssertEqual(error, .invalidHTTPStatus(404))
        }
    }

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
                recorder.append(progress)
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

        // Record in the callback itself; separately scheduled tasks can reorder
        // the initial zero update behind the transport's first progress update.
        let values = recorder.values
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
