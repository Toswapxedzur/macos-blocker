import XCTest
@testable import VaultClassifierCore

final class OfficialDictionaryTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func entry(_ kind: KnowledgeEntryKind, _ subject: String, _ meaning: String = "Official description", aliases: [String] = []) -> OfficialDictionaryEntry {
        .init(id: KnowledgeEntry.key(kind: kind, subject: subject), kind: kind, subject: subject, meaning: meaning, aliases: aliases, updatedAtMilliseconds: WorkspaceCatalog.now())
    }
    private func pack(_ entries: [OfficialDictionaryEntry], kind: KnowledgeEntryKind, version: String, root: URL) throws -> (DictionaryManifest, URL) {
        let stage = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        var shards: [String: [String: [OfficialDictionaryEntry]]] = [:]
        for e in entries {
            for alias in [e.subject] + e.aliases {
                let key = kind == .creator ? alias : DictionaryKeys.termKey(alias)
                if !(shards[DictionaryKeys.bucket(key)]?[key]?.contains(e) ?? false) { shards[DictionaryKeys.bucket(key), default: [:]][key, default: []].append(e) }
            }
        }
        var files: [DictionaryManifest.File] = []
        for (shard, value) in shards {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(value), name = shard + ".json"
            try data.write(to: stage.appendingPathComponent(name))
            files.append(.init(name: name, byteCount: data.count, sha256: DictionaryKeys.digest(data)))
        }
        return (.init(schemaVersion: 1, kind: kind, version: version, entryCount: entries.count, totalByteCount: files.reduce(0) { $0 + Int64($1.byteCount) }, files: files), stage)
    }
    func testTermAliasesAndFullCreatorsSurviveRestartWithoutResidentCorpus() throws {
        let r = try root(), store = try DictionaryDiskStore(root: r, settings: .init())
        let term = entry(.term, "Fixture Mod", aliases: ["测试模组", "Fixture 测试模组"])
        let creator = entry(.creator, "youtube:channel:UCfixture", aliases: ["youtube:handle:@fixture"])
        let (t, ts) = try pack([term], kind: .term, version: "v1", root: r); try store.install(t, stagedDirectory: ts)
        let (c, cs) = try pack([creator], kind: .creator, version: "v1", root: r); try store.install(c, stagedDirectory: cs)
        var settings = DictionarySettings(); settings.creatorMode = .full; try store.configure(settings)
        XCTAssertEqual(store.localEvidence(title: "New 测试模组 episode", creatorID: "youtube:handle:@fixture").terms.first?.id, term.id)
        XCTAssertNotNil(store.localEvidence(title: "", creatorID: "youtube:handle:@fixture").creator)
        XCTAssertNotNil(store.localEvidence(title: "About Fixture 测试模组", creatorID: "").terms.first)
        XCTAssertTrue(store.localEvidence(title: "Fixture Modern unrelated", creatorID: "").terms.isEmpty)
        let reopened = try DictionaryDiskStore(root: r, settings: settings)
        XCTAssertTrue(reopened.creatorFullDownloadReady)
        XCTAssertNotNil(reopened.localEvidence(title: "Fixture Mod", creatorID: creator.subject).creator)
    }
    func testPersonalWrittenAndResearchDefinitionsOverrideOfficialAndFingerprintIsScoped() {
        let official = entry(.term, "Fixture Mod", "Official", aliases: ["测试模组", "Fixture 测试模组"]).knowledge(subject: "测试模组")
        for byUser in [false, true] {
            var catalog = WorkspaceCatalog()
            var personal = KnowledgeEntry(kind: .term, subject: "Fixture Mod", meaning: "Personal")
            personal.writtenByUser = byUser; catalog.knowledgeEntries = [personal]
            catalog.creatorKnowledge = [KnowledgeEntry(kind: .creator, subject: "youtube:channel:UCfixture", meaning: "Personal creator")]
            let evidence = DictionaryEvidence(terms: [official], creator: entry(.creator, "youtube:channel:UCfixture").knowledge())
            let overlay = evidence.overlay(on: catalog, title: "测试模组", creatorID: "youtube:channel:UCfixture")
            XCTAssertEqual(overlay.knowledgeEntries.first?.meaning, "Personal")
            var aliasCatalog = WorkspaceCatalog()
            aliasCatalog.knowledgeEntries = [.init(kind: .term, subject: "测试模组", meaning: "Personal alias")]
            let aliasTerms = evidence.overlay(on: aliasCatalog, title: "测试模组", creatorID: "")
            XCTAssertEqual(aliasTerms.knowledgeEntries.count, 1)
            XCTAssertEqual(aliasTerms.knowledgeEntries.first?.meaning, "Personal alias")
            XCTAssertEqual(overlay.creatorKnowledge.first?.meaning, "Personal creator")
            let aliasOverlay = evidence.overlay(on: catalog, title: "", creatorID: "youtube:handle:@fixture")
            XCTAssertEqual(aliasOverlay.creatorKnowledgeEntry(for: "youtube:handle:@fixture")?.meaning, "Personal creator")
            let before = DictionaryEvidence.fingerprint(title: "测试模组", creatorID: "", catalog: overlay, settings: .init())
            var changed = overlay; changed.knowledgeEntries.append(.init(kind: .term, subject: "Other Mod", meaning: "Unrelated"))
            XCTAssertEqual(before, DictionaryEvidence.fingerprint(title: "测试模组", creatorID: "", catalog: changed, settings: .init()))
            changed.knowledgeEntries[0].meaning = "Changed"
            XCTAssertNotEqual(before, DictionaryEvidence.fingerprint(title: "测试模组", creatorID: "", catalog: changed, settings: .init()))
        }
    }
    func testCorruptUpdateDoesNotReplaceActivePack() throws {
        let r = try root(), store = try DictionaryDiskStore(root: r, settings: .init())
        let (old, os) = try pack([entry(.term, "Fixture Mod", "Old")], kind: .term, version: "old", root: r); try store.install(old, stagedDirectory: os)
        let (new, ns) = try pack([entry(.term, "Fixture Mod", "New")], kind: .term, version: "new", root: r)
        try Data("{}".utf8).write(to: ns.appendingPathComponent(new.files[0].name))
        XCTAssertThrowsError(try store.install(new, stagedDirectory: ns))
        XCTAssertEqual(store.manifest(.term)?.version, "old")
        XCTAssertEqual(store.localEvidence(title: "Fixture Mod", creatorID: "").terms.first?.meaning, "Old")

    }
    func testSameVersionRedownloadRepairsCorruptedShard() throws {
        let r = try root(), store = try DictionaryDiskStore(root: r, settings: .init())
        let record = entry(.term, "Fixture Mod", "Original")
        let (m, stage) = try pack([record], kind: .term, version: "v1", root: r)
        let (repair, replacement) = try pack([record], kind: .term, version: "v1", root: r)
        XCTAssertEqual(m, repair)
        try store.install(m, stagedDirectory: stage)
        try Data("corrupt".utf8).write(to: r.appendingPathComponent("packs/term-v1/"+m.files[0].name))
        try store.install(repair, stagedDirectory: replacement)
        XCTAssertEqual(store.localEvidence(title: "Fixture Mod", creatorID: "").terms.first?.meaning, "Original")
    }
    func testBoundedCreatorCacheNegativeEntriesAndVersionChange() throws {
        let r = try root(); var settings = DictionarySettings(); settings.creatorCacheSize = 2
        let store = try DictionaryDiskStore(root: r, settings: settings)
        let manifest = DictionaryManifest(schemaVersion: 1, kind: .creator, version: "v1", entryCount: 0, totalByteCount: 0, files: [])
        try store.activateCacheManifest(manifest)
        for id in ["a", "b", "c"] { try store.cacheCreator("twitter:account:"+id, entry: nil, version: "v1") }
        XCTAssertEqual(store.cachedCreatorCount, 2)
        XCTAssertFalse(store.hasCachedCreator("twitter:account:a"))
        XCTAssertTrue(store.hasCachedCreator("twitter:account:c"))
        let reopened = try DictionaryDiskStore(root: r, settings: settings)
        XCTAssertEqual(reopened.cachedCreatorCount, 2)
        var next = manifest; next.version = "v2"; try reopened.activateCacheManifest(next)
        XCTAssertEqual(reopened.cachedCreatorCount, 0)
    }
    func testSafeSettingsPersonalPackAndUnknownCounts() throws {
        let settings = try JSONDecoder().decode(DictionarySettings.self, from: Data(#"{"creatorMode":"retired","creatorCacheSize":-1}"#.utf8))
        XCTAssertEqual(settings.creatorMode, .cache); XCTAssertEqual(settings.creatorCacheSize, 1)
        XCTAssertTrue(settings.contributionEnabled); XCTAssertFalse(settings.contributionChoiceMade)
        XCTAssertNil(DictionaryKeys.subscriberCount([:]))
        XCTAssertEqual(DictionaryKeys.subscriberCount(["subscriberCount": "1.2M subscribers"]), 1_200_000)
        XCTAssertEqual(DictionaryKeys.subscriberCount(["subscriberCount": "3.2万"]), 32_000)
        XCTAssertThrowsError(try PersonalDictionaryPack.decode(Data(#"{"schemaVersion":1,"entries":[{"kind":"creator","subject":"private name","meaning":"bad"}]}"#.utf8)))
        XCTAssertEqual(try PersonalDictionaryPack.decode(Data(#"{"schemaVersion":1,"entries":[{"kind":"term","subject":"Fixture Mod","meaning":"Mine"}]}"#.utf8)).entries.count, 1)
    }
}
