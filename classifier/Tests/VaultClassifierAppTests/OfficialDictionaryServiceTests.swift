import XCTest
import VaultClassifierCore
@testable import VaultClassifierApp

private actor DictionaryHTTPFixture: DictionaryHTTP {
    var calls: [(String, String, Data?)] = []
    let known: Bool
    init(known: Bool = false) { self.known = known }
    func request(path: String, method: String, body: Data?) async throws -> Data {
        calls.append((path, method, body))
        if path.contains("manifest") {
            return Data(#"{"schemaVersion":1,"kind":"creator","version":"fixture-v1","entryCount":0,"totalByteCount":0,"files":[]}"#.utf8)
        }
        if path.hasPrefix("dictionary-creator") {
            let entry: Any = known ? ["id":"creator:youtube:channel:UCfixture","kind":"creator","subject":"youtube:channel:UCfixture","meaning":"A fictional creator for tests","aliases":[],"updatedAtMilliseconds":WorkspaceCatalog.now()] : NSNull()
            return try JSONSerialization.data(withJSONObject: ["version":"fixture-v1","entry":entry])
        }
        return Data(#"{"accepted":1}"#.utf8)
    }
    func requests() -> [(String, String, Data?)] { calls }
}

final class OfficialDictionaryServiceTests: XCTestCase {
    private func submitted(_ store: DictionaryDiskStore, id: String, count: Int64?) async throws {
        for _ in 0..<200 {
            if let data = try? Data(contentsOf: store.root.appendingPathComponent("contribution-ledger.json")),
               let payload = try? StorageSchemaPolicy(format: "dictionary.contribution-ledger").payload(from: data),
               let row = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
               (row["sent"] as? [String])?.contains(id) == true,
               count == nil || (row["counts"] as? [String: Int64])?[id] == count { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Contribution did not complete for \(id)")
    }
    private func disk(_ settings: DictionarySettings = .init()) throws -> DictionaryDiskStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try DictionaryDiskStore(root: root, settings: settings)
    }
    func testCacheHitAndFullModeNeverDoRemoteLookup() async throws {
        let store = try disk(), http = DictionaryHTTPFixture(known: true), service = OfficialDictionaryService(disk: store, http: http)
        let first = await service.evidence(title: "Private title", creatorID: "youtube:channel:UCfixture", subscriberCount: 10)
        XCTAssertNotNil(first.creator)
        _ = await service.evidence(title: "Another private title", creatorID: "youtube:channel:UCfixture", subscriberCount: 10)
        let requests = await http.requests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertFalse(requests.contains { $0.0.contains("Private") || $0.2 != nil })
        var settings = store.settings(); settings.creatorMode = .full; try await service.configure(settings)
        _ = await service.evidence(title: "Local", creatorID: "twitter:account:unknown", subscriberCount: nil)
        let after = await http.requests(); XCTAssertEqual(after.count, 2)
    }
    func testContributionChoiceRevocationMinimumPayloadAndDailyDedupe() async throws {
        let store = try disk(), http = DictionaryHTTPFixture(), service = OfficialDictionaryService(disk: store, http: http)
        let day = String(Int(Date().timeIntervalSince1970) / 86400)
        let id = (0..<1000).map { "twitter:account:fixture\($0)" }.first { (Int(DictionaryKeys.digest(Data((day+$0).utf8)).prefix(2), radix:16) ?? 1) % 4 == 0 }!
        _ = await service.evidence(title: "Never upload me", creatorID: id, subscriberCount: 123)
        let initial = await http.requests(); XCTAssertFalse(initial.contains { $0.1 == "POST" })
        var settings = store.settings(); settings.contributionChoiceMade = true; try await service.configure(settings)
        _ = await service.evidence(title: "Never upload me", creatorID: id, subscriberCount: 123)
        _ = await service.evidence(title: "Repeat", creatorID: id, subscriberCount: 123)
        try await submitted(store, id: id, count: 123)
        let posts = await http.requests().filter { $0.1 == "POST" }
        XCTAssertEqual(posts.count, 1)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(posts.first?.2)) as? [String:Any])
        XCTAssertEqual(Set(payload.keys), ["creators"])
        let row = try XCTUnwrap((payload["creators"] as? [[String:Any]])?.first)
        XCTAssertEqual(Set(row.keys), ["creatorID","subscriberCount"])
        XCTAssertEqual(row["creatorID"] as? String, id); XCTAssertEqual(row["subscriberCount"] as? Int, 123)
        settings.contributionEnabled = false; try await service.configure(settings)
        for n in 1000..<1020 { _ = await service.evidence(title: "Private", creatorID: "twitter:account:fixture\(n)", subscriberCount: nil) }
        let all = await http.requests(); XCTAssertEqual(all.filter { $0.1 == "POST" }.count, 1)
        _ = await service.evidence(title: "A niche term", creatorID: "", subscriberCount: nil)
        let last = await http.requests(); XCTAssertEqual(last.count, all.count)
    }
    func testUnknownSubscriberCountCanBeEnrichedLaterThatDay() async throws {
        var settings = DictionarySettings(); settings.creatorMode = .full
        settings.contributionEnabled = true; settings.contributionChoiceMade = true
        let store = try disk(settings), http = DictionaryHTTPFixture()
        let service = OfficialDictionaryService(disk: store, http: http)
        let day = String(Int(Date().timeIntervalSince1970) / 86400)
        let id = try XCTUnwrap((0..<1000).map { "twitter:account:enrichment\($0)" }.first {
            (Int(DictionaryKeys.digest(Data((day + $0).utf8)).prefix(2), radix: 16) ?? 1) % 4 == 0
        })
        _ = await service.evidence(title: "Private feed", creatorID: id, subscriberCount: nil)
        _ = await service.evidence(title: "Private watch title", creatorID: id, subscriberCount: 123)
        _ = await service.evidence(title: "Same known count", creatorID: id, subscriberCount: 123)
        try await submitted(store, id: id, count: 123)
        let posts = await http.requests().filter { $0.1 == "POST" }
        XCTAssertEqual(posts.count, 2)
        let row = try XCTUnwrap((JSONSerialization.jsonObject(with: try XCTUnwrap(posts.last?.2)) as? [String: Any])?["creators"] as? [[String: Any]])
        XCTAssertEqual(row.first?["subscriberCount"] as? Int, 123)
        let reopened = OfficialDictionaryService(disk: store, http: http)
        _ = await reopened.evidence(title: "After restart", creatorID: id, subscriberCount: 123)
        let finalPosts = await http.requests().filter { $0.1 == "POST" }
        XCTAssertEqual(finalPosts.count, 2, "successful enrichment is retained across restart")
    }

    func testFailedContributionCanRetryWithoutMarkingTheIDSent() async throws {
        var settings = DictionarySettings(); settings.creatorMode = .full
        settings.contributionEnabled = true; settings.contributionChoiceMade = true
        let store = try disk(settings), http = RetryContributionFixture()
        let service = OfficialDictionaryService(disk: store, http: http)
        let day = String(Int(Date().timeIntervalSince1970) / 86400)
        let id = try XCTUnwrap((0..<1000).map { "twitter:account:retry\($0)" }.first {
            (Int(DictionaryKeys.digest(Data((day + $0).utf8)).prefix(2), radix: 16) ?? 1) % 4 == 0
        })
        _ = await service.evidence(title: "Private", creatorID: id, subscriberCount: 123)
        for _ in 0..<200 {
            _ = await service.evidence(title: "Retry", creatorID: id, subscriberCount: 123)
            if await http.attempts >= 2 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try await submitted(store, id: id, count: 123)
        _ = await service.evidence(title: "Already sent", creatorID: id, subscriberCount: 123)
        let attempts = await http.attempts
        XCTAssertEqual(attempts, 2)
    }

    func testRealLoopbackHTTPDownload() async throws {
        let process = Process()
        let environment = ProcessInfo.processInfo.environment
        if let explicit = environment["VAULT_TEST_PYTHON"], !explicit.isEmpty { process.executableURL = URL(fileURLWithPath: explicit) }
        else {
            #if os(Windows)
            let programs = URL(fileURLWithPath: environment["LOCALAPPDATA"] ?? "").appendingPathComponent("Programs/Python")
            let installs = try FileManager.default.contentsOfDirectory(at: programs, includingPropertiesForKeys: nil)
            process.executableURL = try XCTUnwrap(installs.sorted { $0.path < $1.path }.map { $0.appendingPathComponent("python.exe") }.first { FileManager.default.fileExists(atPath:$0.path) })
            #else
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            #endif
        }
        let output = Pipe(); process.standardOutput = output; process.standardError = FileHandle.nullDevice
        process.arguments = ["-u","-c", """
        import time
        from http.server import BaseHTTPRequestHandler, HTTPServer
        class H(BaseHTTPRequestHandler):
            def do_GET(self):
                if self.path == '/oversize':
                    self.send_response(200); self.send_header('Content-Length', '8388609'); self.end_headers(); self.wfile.write(b'x'*1024); self.wfile.flush(); time.sleep(1); return
                if self.path == '/redirect':
                    self.send_response(302); self.send_header('Location', 'http://localhost:9/private'); self.end_headers(); return
                self.send_response(200); self.end_headers(); self.wfile.write(b'{"fixture":true}')
            def log_message(self,*args): pass
        s=HTTPServer(('127.0.0.1',0),H); print(s.server_port,flush=True); s.serve_forever()
        """]
        try process.run(); defer { process.terminate(); process.waitUntilExit() }
        let raw = output.fileHandleForReading.availableData
        let port = try XCTUnwrap(Int(String(decoding: raw, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        let client = DictionaryHTTPClient(baseURL: URL(string: "http://127.0.0.1:\(port)/")!)
        let data = try await client.request(path: "fixture", method: "GET", body: nil)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"fixture":true}"#)
        for path in ["oversize", "redirect"] {
            do { _ = try await client.request(path: path, method: "GET", body: nil); XCTFail("Accepted prohibited transfer: \(path)") }
            catch { XCTAssertTrue(error is DictionaryError, "\(path): \(error)") }
        }
    }
}

private actor RetryContributionFixture: DictionaryHTTP {
    var attempts = 0
    func request(path: String, method: String, body: Data?) async throws -> Data {
        attempts += 1
        if attempts == 1 { throw DictionaryError.unavailable }
        return Data(#"{"accepted":1}"#.utf8)
    }
}

private actor CancellableContributionFixture: DictionaryHTTP {
    var started = false, cancelled = false
    func request(path: String, method: String, body: Data?) async throws -> Data {
        if method == "POST" {
            started = true
            do { try await Task.sleep(nanoseconds: 10_000_000_000) }
            catch { cancelled = true; throw error }
            return Data("{}".utf8)
        }
        if path.contains("manifest") { return Data(#"{"schemaVersion":1,"kind":"creator","version":"fixture-v1","entryCount":0,"totalByteCount":0,"files":[]}"#.utf8) }
        return Data(#"{"version":"fixture-v1","entry":null}"#.utf8)
    }
    func flags() -> (Bool, Bool) { (started, cancelled) }
}
extension OfficialDictionaryServiceTests {
    func testRevocationCancelsAnOwnedPendingContribution() async throws {
        var settings = DictionarySettings(); settings.contributionChoiceMade = true
        let store = try disk(settings), http = CancellableContributionFixture(), service = OfficialDictionaryService(disk: store, http: http)
        let day = String(Int(Date().timeIntervalSince1970)/86400)
        let id = (0..<1000).map { "twitter:account:pending\($0)" }.first { (Int(DictionaryKeys.digest(Data((day+$0).utf8)).prefix(2),radix:16) ?? 1)%4 == 0 }!
        let request = Task { await service.evidence(title: "Private", creatorID: id, subscriberCount: nil) }
        for _ in 0..<100 { if await http.flags().0 { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        let started = await http.flags().0; XCTAssertTrue(started)
        settings.contributionEnabled = false; try await service.configure(settings)
        _ = await request.value
        for _ in 0..<100 { if await http.flags().1 { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        let cancelled = await http.flags().1; XCTAssertTrue(cancelled)
    }
}

private actor UnavailableDictionaryFixture: DictionaryHTTP {
    var count = 0
    func request(path: String, method: String, body: Data?) async throws -> Data { count += 1; throw DictionaryError.unavailable }
    func total() -> Int { count }
}
extension OfficialDictionaryServiceTests {
    func testUnavailableServerDoesNotDelayEverySubsequentCreator() async throws {
        let http = UnavailableDictionaryFixture(), service = OfficialDictionaryService(disk: try disk(), http: http)
        for id in ["one","two","three"] { _ = await service.evidence(title: "Local classification remains possible", creatorID: "twitter:account:"+id, subscriberCount: nil) }
        let count = await http.total(); XCTAssertEqual(count, 1)
    }
}

extension OfficialDictionaryServiceTests {
    func testPublishedBackendPacksDownloadMatchAliasesAndRemainOffline() async throws {
        guard let base = ProcessInfo.processInfo.environment["VAULT_DICTIONARY_FIXTURE_URL"], let url = URL(string: base) else { throw XCTSkip("Requires the isolated mini1 backend publication fixture.") }
        var settings = DictionarySettings(); settings.creatorMode = .full; settings.contributionEnabled = false
        let store = try disk(settings), service = OfficialDictionaryService(disk: store, http: DictionaryHTTPClient(baseURL: url))
        _ = try await service.checkUpdates(); _ = try await service.update(.term); _ = try await service.update(.creator)
        let first = await service.evidence(title: "测试模组 episode", creatorID: "youtube:handle:@fixture", subscriberCount: nil)
        XCTAssertEqual(first.terms.first?.meaning, "A fictional mod for integration tests")
        XCTAssertEqual(first.creator?.meaning, "A fictional creator for integration tests")
        let overlay = first.overlay(on: WorkspaceCatalog(), title: "测试模组 episode", creatorID: "youtube:handle:@fixture")
        XCTAssertEqual(overlay.creatorKnowledgeEntry(for: "youtube:handle:@fixture")?.meaning, "A fictional creator for integration tests")
        settings.creatorMode = .cache; try await service.configure(settings)
        let cached = await service.evidence(title: "", creatorID: "youtube:handle:@fixture", subscriberCount: nil)
        XCTAssertNotNil(cached.creator)
        settings.creatorMode = .full
        let reopened = try DictionaryDiskStore(root: store.root, settings: settings), offline = UnavailableDictionaryFixture()
        let local = OfficialDictionaryService(disk: reopened, http: offline)
        let again = await local.evidence(title: "Fixture Mod episode", creatorID: "youtube:channel:UCfixture", subscriberCount: nil)
        XCTAssertEqual(again.terms.first?.id, "term:fixture mod"); XCTAssertNotNil(again.creator)
        let calls = await offline.total(); XCTAssertEqual(calls, 0)
    }
}

private actor HeldContributionFixture: DictionaryHTTP {
    var bodies: [Data] = []
    private var release: CheckedContinuation<Void, Never>?
    func request(path: String, method: String, body: Data?) async throws -> Data {
        if let body { bodies.append(body) }
        if bodies.count == 1 { await withCheckedContinuation { release = $0 } }
        return Data("{}".utf8)
    }
    func unblock() { release?.resume(); release = nil }
}

extension OfficialDictionaryServiceTests {
    func testHeldUploadDoesNotHoldEvidenceAndRetainsConcurrentKnownCount() async throws {
        var settings = DictionarySettings(); settings.creatorMode = .full
        settings.contributionEnabled = true; settings.contributionChoiceMade = true
        let store = try disk(settings), http = HeldContributionFixture()
        let service = OfficialDictionaryService(disk: store, http: http)
        let day = String(Int(Date().timeIntervalSince1970) / 86400)
        let id = try XCTUnwrap((0..<1000).map { "twitter:account:held\($0)" }.first {
            (Int(DictionaryKeys.digest(Data((day + $0).utf8)).prefix(2), radix: 16) ?? 1) % 4 == 0
        })
        let returned = expectation(description: "Evidence returns while upload is held")
        let request = Task {
            _ = await service.evidence(title: "Private feed", creatorID: id, subscriberCount: nil)
            returned.fulfill()
        }
        for _ in 0..<100 { if await http.bodies.count == 1 { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        let started = await http.bodies.count; XCTAssertEqual(started, 1)
        // Always release the held fixture, even if the regression fails.
        await fulfillment(of: [returned], timeout: 0.5)
        _ = await service.evidence(title: "Private watch", creatorID: id, subscriberCount: 123)
        _ = await service.evidence(title: "Repeat watch", creatorID: id, subscriberCount: 123)
        let before = await http.bodies.count; XCTAssertEqual(before, 1)
        await http.unblock(); _ = await request.value
        try await submitted(store, id: id, count: 123)
        let bodies = await http.bodies; XCTAssertEqual(bodies.count, 2)
        let row = try XCTUnwrap((JSONSerialization.jsonObject(with: bodies.last!) as? [String: Any])?["creators"] as? [[String: Any]])
        XCTAssertEqual(row.first?["subscriberCount"] as? Int, 123)
    }
}
