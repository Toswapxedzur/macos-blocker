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
    func testRealLoopbackHTTPDownload() async throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        let output = Pipe(); process.standardOutput = output; process.standardError = FileHandle.nullDevice
        process.arguments = ["-u","-c", """
        from http.server import BaseHTTPRequestHandler, HTTPServer
        class H(BaseHTTPRequestHandler):
            def do_GET(self):
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
        let cancelled = await http.flags().1; XCTAssertTrue(cancelled)
    }
}
