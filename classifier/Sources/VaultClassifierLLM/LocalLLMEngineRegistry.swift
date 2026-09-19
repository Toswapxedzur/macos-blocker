import Foundation
import VaultClassifierCore

/// Keeps one llama model/context resident per distinct GGUF path. Actor
/// isolation covers the cache, in-flight loads, and LRU bookkeeping; model
/// loading itself runs outside the actor executor.
public actor LocalLLMEngineRegistry: OnDeviceLLMEngineResolving {
    struct ResidencyIndex: Equatable {
        private(set) var accessByPath: [String: UInt64] = [:]
        private var clock: UInt64 = 0

        mutating func touch(_ path: String) {
            clock &+= 1
            accessByPath[path] = clock
        }

        mutating func remove(_ path: String) {
            accessByPath.removeValue(forKey: path)
        }

        func leastRecentlyUsed(excluding excludedPaths: Set<String> = []) -> String? {
            accessByPath
                .filter { !excludedPaths.contains($0.key) }
                .min { lhs, rhs in
                    lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value < rhs.value
                }?.key
        }

        var pathsInLRUOrder: [String] {
            accessByPath.sorted { lhs, rhs in
                lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value < rhs.value
            }.map(\.key)
        }
    }

    struct ResidentEngineCache<Engine> {
        private var engines: [String: Engine] = [:]
        private var residency = ResidencyIndex()

        var count: Int { engines.count }
        var pathsInLRUOrder: [String] { residency.pathsInLRUOrder }

        mutating func value(for path: String) -> Engine? {
            guard let engine = engines[path] else { return nil }
            residency.touch(path)
            return engine
        }

        mutating func insert(_ engine: Engine, at path: String) {
            engines[path] = engine
            residency.touch(path)
        }

        mutating func evictIfNeeded(
            capacity requestedCapacity: Int,
            protecting paths: Set<String>
        ) -> [(path: String, residentCount: Int)] {
            let capacity = min(LocalLLMSettings.maximumResidentModels, max(1, requestedCapacity))
            var evictions: [(String, Int)] = []
            while engines.count > capacity,
                  let victim = residency.leastRecentlyUsed(excluding: paths) {
                engines.removeValue(forKey: victim)
                residency.remove(victim)
                evictions.append((victim, engines.count))
            }
            return evictions
        }
    }

    private var cache = ResidentEngineCache<VaultLocalLLMEngine>()
    private var loads: [String: Task<VaultLocalLLMEngine, Error>] = [:]
    /// Core holds this engine directly for the zero-actor-hop inherited path,
    /// so the registry pins and counts it when applying the residency cap.
    private var pinnedDefaultPath: String?

    public init() {}

    /// The public concrete API used by the app to preload the global/default
    /// engine before installing this registry in the coordinator.
    public func engine(
        forModel fileName: String?,
        configuration: LocalLLMSettings
    ) async throws -> VaultLocalLLMEngine {
        let path = try Self.resolvedModelPath(
            requestedFileName: fileName,
            configuration: configuration
        )
        if Self.cleanedFileName(fileName) == nil {
            pinnedDefaultPath = path
        }
        if let requested = Self.cleanedFileName(fileName),
           !Self.isAvailableModelFile(requested) {
            VaultDevLog.shared.log("llm", "model-fallback", [
                "requested": requested,
                "resolved": (path as NSString).lastPathComponent,
            ])
        }

        if let cached = cache.value(for: path) {
            evictIfNeeded(capacity: configuration.maxResidentModels, protecting: path)
            return cached
        }
        if let load = loads[path] {
            let loaded = try await load.value
            if let cached = cache.value(for: path) {
                return cached
            }
            return install(
                loaded,
                at: path,
                capacity: configuration.maxResidentModels
            )
        }

        let load = Task.detached(priority: .userInitiated) {
            try VaultLocalLLMEngine(modelPath: path, configuration: configuration)
        }
        loads[path] = load
        do {
            let loaded = try await load.value
            loads.removeValue(forKey: path)
            if let cached = cache.value(for: path) {
                return cached
            }
            return install(
                loaded,
                at: path,
                capacity: configuration.maxResidentModels
            )
        } catch {
            loads.removeValue(forKey: path)
            throw error
        }
    }

    public func resolveEngine(
        forModel fileName: String,
        configuration: LocalLLMSettings
    ) async throws -> any OnDeviceLLM {
        try await engine(forModel: fileName, configuration: configuration)
    }

    /// Diagnostic/test view only; classification never enumerates the cache.
    public func residentModelFilesInLRUOrder() -> [String] {
        cache.pathsInLRUOrder.map { ($0 as NSString).lastPathComponent }
    }

    private func install(
        _ engine: VaultLocalLLMEngine,
        at path: String,
        capacity: Int
    ) -> VaultLocalLLMEngine {
        cache.insert(engine, at: path)
        VaultDevLog.shared.log("llm", "registry-load", [
            "model": (path as NSString).lastPathComponent,
            "resident": "\(cache.count)",
        ])
        evictIfNeeded(capacity: capacity, protecting: path)
        return engine
    }

    private func evictIfNeeded(capacity requestedCapacity: Int, protecting path: String) {
        let protectedPaths = pinnedDefaultPath.map { Set([$0]) } ?? Set([path])
        for eviction in cache.evictIfNeeded(
            capacity: requestedCapacity,
            protecting: protectedPaths
        ) {
            VaultDevLog.shared.log("llm", "registry-evict", [
                "model": (eviction.path as NSString).lastPathComponent,
                "resident": "\(eviction.residentCount)",
            ])
        }
    }

    nonisolated static func resolvedModelPath(
        requestedFileName: String?,
        configuration: LocalLLMSettings,
        modelsDirectory: URL? = VaultLocalLLMEngine.modelsDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        availableModelFiles: [String] = VaultLocalLLMEngine.availableModelFiles()
    ) throws -> String {
        if let requested = cleanedFileName(requestedFileName),
           isSafeGGUFFileName(requested),
           let directory = modelsDirectory,
           FileManager.default.fileExists(atPath: directory.appendingPathComponent(requested).path) {
            return directory.appendingPathComponent(requested).path
        }
        if let global = cleanedFileName(configuration.modelFileName),
           isSafeGGUFFileName(global),
           let directory = modelsDirectory,
           FileManager.default.fileExists(atPath: directory.appendingPathComponent(global).path) {
            return directory.appendingPathComponent(global).path
        }
        if let explicit = environment["ADAMANCIA_VAULT_LLM_MODEL"], !explicit.isEmpty {
            guard FileManager.default.fileExists(atPath: explicit) else {
                throw OnDeviceLLMError.notReady("no-model-file")
            }
            return explicit
        }
        if let first = availableModelFiles.sorted().first,
           isSafeGGUFFileName(first),
           let directory = modelsDirectory {
            return directory.appendingPathComponent(first).path
        }
        throw OnDeviceLLMError.notReady("no-model-file")
    }

    private nonisolated static func cleanedFileName(_ fileName: String?) -> String? {
        let cleaned = fileName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return cleaned.isEmpty ? nil : cleaned
    }

    private nonisolated static func isAvailableModelFile(_ fileName: String) -> Bool {
        guard isSafeGGUFFileName(fileName),
              let directory = VaultLocalLLMEngine.modelsDirectory() else { return false }
        return FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(fileName).path
        )
    }

    private nonisolated static func isSafeGGUFFileName(_ fileName: String) -> Bool {
        !fileName.contains("/") && !fileName.contains("\\") &&
            fileName.lowercased().hasSuffix(".gguf")
    }
}
