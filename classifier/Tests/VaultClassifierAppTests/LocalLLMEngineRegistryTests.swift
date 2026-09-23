import XCTest
import VaultClassifierCore
@testable import VaultClassifierLLM

final class LocalLLMEngineRegistryTests: XCTestCase {
    func testPickerListsManualAndDownloadedCatalogGGUFFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let catalogFile = try XCTUnwrap(LocalModelCatalog.curated.first?.ggufFileName)
        XCTAssertTrue(FileManager.default.createFile(
            atPath: directory.appendingPathComponent(catalogFile).path,
            contents: Data()
        ))
        XCTAssertTrue(FileManager.default.createFile(
            atPath: directory.appendingPathComponent("manual.gguf").path,
            contents: Data()
        ))
        XCTAssertTrue(FileManager.default.createFile(
            atPath: directory.appendingPathComponent("not-a-model.bin").path,
            contents: Data()
        ))
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("not-a-file.gguf", isDirectory: true),
            withIntermediateDirectories: true
        )
        // A symlinked model (e.g. into the Hugging Face cache) must be listed:
        // its target is a regular file.
        let linkTarget = directory.appendingPathComponent("target-store.gguf")
        XCTAssertTrue(FileManager.default.createFile(atPath: linkTarget.path, contents: Data()))
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("linked.gguf"),
            withDestinationURL: linkTarget
        )

        XCTAssertEqual(
            VaultLocalLLMEngine.availableModelFiles(in: directory),
            [catalogFile, "manual.gguf", "target-store.gguf", "linked.gguf"].sorted()
        )
    }

    func testResidencyIndexTracksDeterministicLRUOrder() {
        var index = LocalLLMEngineRegistry.ResidencyIndex()
        index.touch("a.gguf")
        index.touch("b.gguf")
        index.touch("a.gguf")

        XCTAssertEqual(index.pathsInLRUOrder, ["b.gguf", "a.gguf"])
        XCTAssertEqual(index.leastRecentlyUsed(excluding: ["a.gguf"]), "b.gguf")

        index.remove("b.gguf")
        XCTAssertEqual(index.pathsInLRUOrder, ["a.gguf"])
    }

    func testResidentCacheReusesLoadedEngineAndEvictsLeastRecentlyUsed() {
        final class Engine {}
        let a = Engine()
        let b = Engine()
        let c = Engine()
        var cache = LocalLLMEngineRegistry.ResidentEngineCache<Engine>()
        cache.insert(a, at: "a.gguf")
        cache.insert(b, at: "b.gguf")

        XCTAssertTrue(cache.value(for: "a.gguf") === a, "a cache hit must reuse the loaded engine")
        cache.insert(c, at: "c.gguf")
        let evictions = cache.evictIfNeeded(capacity: 2, protecting: ["c.gguf"])

        XCTAssertEqual(evictions.map(\.path), ["b.gguf"])
        XCTAssertNil(cache.value(for: "b.gguf"))
        XCTAssertTrue(cache.value(for: "a.gguf") === a)
        XCTAssertTrue(cache.value(for: "c.gguf") === c)
        XCTAssertEqual(cache.count, 2)
    }

    func testPinnedDefaultCountsTowardOneModelCapacity() {
        final class Engine {}
        let defaultEngine = Engine()
        let selectedEngine = Engine()
        var cache = LocalLLMEngineRegistry.ResidentEngineCache<Engine>()
        cache.insert(defaultEngine, at: "default.gguf")
        cache.insert(selectedEngine, at: "selected.gguf")

        let evictions = cache.evictIfNeeded(
            capacity: 1,
            protecting: ["default.gguf"]
        )

        XCTAssertEqual(evictions.map(\.path), ["selected.gguf"])
        XCTAssertTrue(cache.value(for: "default.gguf") === defaultEngine)
        XCTAssertNil(cache.value(for: "selected.gguf"))
    }

    func testMissingSelectedFileFallsBackToConfiguredGlobalModel() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let globalFileName = LocalLLMSettings(speedQuality: .balanced).modelFileName
        let global = directory.appendingPathComponent(globalFileName)
        XCTAssertTrue(FileManager.default.createFile(atPath: global.path, contents: Data()))

        let resolved = try LocalLLMEngineRegistry.resolvedModelPath(
            requestedFileName: "missing.gguf",
            configuration: .init(speedQuality: .balanced),
            modelsDirectory: directory,
            environment: [:],
            availableModelFiles: [globalFileName]
        )

        XCTAssertEqual(resolved, global.path)
    }
}
