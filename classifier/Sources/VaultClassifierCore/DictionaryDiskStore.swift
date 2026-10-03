import Foundation

public struct DictionaryManifest: Codable, Equatable, Sendable {
    public struct File: Codable, Equatable, Sendable { public var name: String; public var byteCount: Int; public var sha256: String }
    public var schemaVersion: Int
    public var kind: KnowledgeEntryKind
    public var version: String
    public var entryCount: Int
    public var totalByteCount: Int64
    public var files: [File]
    public func validate() throws {
        guard schemaVersion == 1, version.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$"#, options: .regularExpression) != nil,
              entryCount >= 0, entryCount <= 10_000_000, files.count <= 256,
              Set(files.map(\.name)).count == files.count, totalByteCount >= 0,
              files.allSatisfy({ $0.name.range(of: #"^[0-9a-f]{2}\.json$"#, options: .regularExpression) != nil &&
                  (1...8*1024*1024).contains($0.byteCount) && $0.sha256.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil }),
              totalByteCount == files.reduce(Int64(0), { $0 + Int64($1.byteCount) }) else { throw DictionaryError.invalidPack }
    }
}

/// Full packs remain on disk. At most four parsed shards and the bounded creator cache
/// are resident. This store never mutates the personal knowledge catalog.
public final class DictionaryDiskStore: @unchecked Sendable {
    public let root: URL
    private let lock = NSLock()
    private var config: DictionarySettings
    private var active: [KnowledgeEntryKind: DictionaryManifest] = [:]
    private var hot: [String: [String: [OfficialDictionaryEntry]]] = [:]
    private var hotOrder: [String] = []
    private struct CachedCreator: Codable { var entry: OfficialDictionaryEntry?; var version: String; var expires: Int64; var touched: Int64 }
    private var cache: [String: CachedCreator] = [:]
    public init(root: URL, settings: DictionarySettings) throws {
        self.root = root; self.config = settings; self.config.reconcile()
        try VaultPrivateFile.createDirectory(at: root)
        for kind in KnowledgeEntryKind.allCases {
            if let data = try? Data(contentsOf: pointer(kind)), let manifest = try? JSONDecoder().decode(DictionaryManifest.self, from: data),
               (try? manifest.validate()) != nil, manifest.kind == kind { active[kind] = manifest }
        }
        if let data = Self.boundedRead(root.appendingPathComponent("creator-cache.json"), max: 256*1024*1024),
           let decoded = try? JSONDecoder().decode([String: CachedCreator].self, from: data) {
            cache = decoded.filter { DictionaryKeys.isPublicCreatorID($0.key) && ($0.value.entry == nil || (try? $0.value.entry?.validate()) != nil) }
        }
        trim()
    }
    private static func boundedRead(_ url: URL, max: Int) -> Data? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              attrs[.type] as? FileAttributeType == .typeRegular,
              let size = attrs[.size] as? NSNumber, size.int64Value <= Int64(max) else { return nil }
        return try? Data(contentsOf: url)
    }
    private func pointer(_ kind: KnowledgeEntryKind) -> URL { root.appendingPathComponent("active-\(kind.rawValue).json") }
    private func directory(_ manifest: DictionaryManifest) -> URL { root.appendingPathComponent("packs/\(manifest.kind.rawValue)-\(manifest.version)", isDirectory: true) }
    public func settings() -> DictionarySettings { lock.withLock { config } }
    public func configure(_ settings: DictionarySettings) throws {
        try lock.withLock { config = settings; config.reconcile(); trim(); try saveCache() }
    }
    public func manifest(_ kind: KnowledgeEntryKind) -> DictionaryManifest? { lock.withLock { active[kind] } }
    public var cachedCreatorCount: Int { lock.withLock { cache.count } }
    public var creatorFullDownloadReady: Bool { lock.withLock {
        guard let m = active[.creator] else { return false }
        return FileManager.default.fileExists(atPath: directory(m).appendingPathComponent("manifest.json").path)
    } }
    private func trim() {
        let limit = config.creatorCacheSize
        if cache.count > limit {
            for key in cache.sorted(by: { $0.value.touched == $1.value.touched ? $0.key < $1.key : $0.value.touched < $1.value.touched }).prefix(cache.count-limit).map(\.key) { cache[key] = nil }
        }
    }
    private func saveCache() throws {
        let file = root.appendingPathComponent("creator-cache.json")
        try JSONEncoder().encode(cache).write(to: file, options: .atomic)
        try VaultPrivateFile.restrict(file)
    }
    public func activateCacheManifest(_ manifest: DictionaryManifest) throws {
        try manifest.validate(); guard manifest.kind == .creator else { throw DictionaryError.invalidPack }
        try lock.withLock {
            let data = try JSONEncoder().encode(manifest)
            try data.write(to: pointer(.creator), options: .atomic); try VaultPrivateFile.restrict(pointer(.creator))
            if active[.creator]?.version != manifest.version { cache.removeAll(); try saveCache() }
            active[.creator] = manifest; hot.removeAll(); hotOrder.removeAll()
        }
    }
    /// Stage and validate all files before atomically changing the active pointer.
    public func install(_ manifest: DictionaryManifest, stagedDirectory: URL) throws {
        try manifest.validate()
        for f in manifest.files {
            let file = stagedDirectory.appendingPathComponent(f.name)
            let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
            guard (attrs[.size] as? NSNumber)?.intValue == f.byteCount, attrs[.type] as? FileAttributeType == .typeRegular else { throw DictionaryError.invalidPack }
            let data = try Data(contentsOf: file)
            guard DictionaryKeys.digest(data) == f.sha256 else { throw DictionaryError.invalidPack }
            let postings = try JSONDecoder().decode([String: [OfficialDictionaryEntry]].self, from: data)
            for (key, entries) in postings {
                guard DictionaryKeys.bucket(key) + ".json" == f.name else { throw DictionaryError.invalidPack }
                for entry in entries {
                    try entry.validate()
                    guard entry.kind == manifest.kind,
                          ([entry.subject] + entry.aliases).contains(where: { manifest.kind == .creator ? $0 == key : DictionaryKeys.termKey($0) == key }) else { throw DictionaryError.invalidPack }
                }
            }
        }
        try lock.withLock {
            let manager = FileManager.default
            let target = directory(manifest)
            try VaultPrivateFile.createDirectory(at: target.deletingLastPathComponent())
            let manifestData = try JSONEncoder().encode(manifest)
            if manager.fileExists(atPath: target.path) {
                guard let existing = try? JSONDecoder().decode(DictionaryManifest.self, from: Data(contentsOf: target.appendingPathComponent("manifest.json"))), existing == manifest else { throw DictionaryError.invalidPack }
            } else {
                try manifestData.write(to: stagedDirectory.appendingPathComponent("manifest.json"), options: .atomic)
                try manager.moveItem(at: stagedDirectory, to: target)
            }
            try manifestData.write(to: pointer(manifest.kind), options: .atomic)
            try VaultPrivateFile.restrict(pointer(manifest.kind))
            if manifest.kind == .creator, active[.creator]?.version != manifest.version { cache.removeAll(); try saveCache() }
            active[manifest.kind] = manifest; hot.removeAll(); hotOrder.removeAll()
            // Only obsolete official pack files are reclaimed; personal data lives elsewhere.
            for old in (try? manager.contentsOfDirectory(at: target.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? []
                where old.lastPathComponent.hasPrefix(manifest.kind.rawValue + "-") && old.standardizedFileURL.path != target.standardizedFileURL.path { try? manager.removeItem(at: old) }
        }
    }
    private func postings(_ kind: KnowledgeEntryKind, key: String) -> [OfficialDictionaryEntry] {
        guard let m = active[kind] else { return [] }
        let name = DictionaryKeys.bucket(key) + ".json"
        let hotKey = "\(kind.rawValue)/\(m.version)/\(name)"
        if let found = hot[hotKey] { hotOrder.removeAll { $0 == hotKey }; hotOrder.append(hotKey); return found[key] ?? [] }
        guard let f = m.files.first(where: { $0.name == name }), let data = Self.boundedRead(directory(m).appendingPathComponent(name), max: f.byteCount),
              data.count == f.byteCount, DictionaryKeys.digest(data) == f.sha256,
              let values = try? JSONDecoder().decode([String: [OfficialDictionaryEntry]].self, from: data) else { return [] }
        hot[hotKey] = values; hotOrder.append(hotKey)
        while hotOrder.count > 4 { hot[hotOrder.removeFirst()] = nil }
        return values[key] ?? []
    }
    public func localEvidence(title: String, creatorID: String) -> DictionaryEvidence {
        lock.withLock {
            var found: [String: KnowledgeEntry] = [:]
            for key in DictionaryKeys.titleKeys(title) {
                for entry in postings(.term, key: key) where found[entry.id] == nil {
                    for alias in [entry.subject] + entry.aliases where entry.knowledge(subject: alias).matches(title: title) {
                        found[entry.id] = entry.knowledge(subject: alias); break
                    }
                }
            }
            let terms = found.values.sorted { $0.subject.count == $1.subject.count ? $0.id < $1.id : $0.subject.count > $1.subject.count }
            let creator: KnowledgeEntry?
            if config.creatorMode == .full {
                creator = postings(.creator, key: creatorID).first?.knowledge(subject: creatorID)
            } else if var hit = cache[creatorID], hit.version == active[.creator]?.version, hit.expires > WorkspaceCatalog.now() {
                hit.touched = WorkspaceCatalog.now(); cache[creatorID] = hit
                creator = hit.entry?.knowledge(subject: creatorID)
            } else { creator = nil }
            return .init(terms: Array(terms.prefix(ResearchSettings.maximumKnowledgePerVideo)), creator: creator)
        }
    }
    public func hasCachedCreator(_ id: String) -> Bool { lock.withLock {
        guard let c = cache[id] else { return false }
        return c.version == active[.creator]?.version && c.expires > WorkspaceCatalog.now()
    } }
    public func cacheCreator(_ id: String, entry: OfficialDictionaryEntry?, version: String) throws {
        if let entry { try entry.validate(); guard entry.kind == .creator && ([entry.subject] + entry.aliases).contains(id) else { throw DictionaryError.invalidPack } }
        try lock.withLock {
            guard version == active[.creator]?.version else { return }
            let now = WorkspaceCatalog.now()
            cache[id] = .init(entry: entry, version: version, expires: now + (entry == nil ? 86_400_000 : 7*86_400_000), touched: now)
            trim(); try saveCache()
        }
    }
}
